import SwiftUI
import OslerEngine

/// One line of a past run: which node said what.
struct RunResultLine: Identifiable {
    let id = UUID()
    let name: String
    let output: String
    let failed: Bool
}

/// A finished (or stopped) run, kept for the history panel.
struct RunRecord: Identifiable {
    let id = UUID()
    let date: Date
    let flowName: String
    let duration: TimeInterval
    let results: [RunResultLine]
    let hadFailure: Bool
}

/// Drives a `FlowEngine` run and republishes its event stream as observable,
/// per-node UI state the canvas can bind to directly.
@MainActor
final class RunController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var states: [UUID: NodeRunState] = [:]
    @Published private(set) var outputs: [UUID: String] = [:]
    @Published private(set) var decisions: [UUID: Bool] = [:]
    @Published private(set) var startupError: String?
    /// Nodes whose output is still streaming in, for a live cursor/caret.
    @Published private(set) var streaming: Set<UUID> = []
    /// The last runs of this session, newest first.
    @Published private(set) var history: [RunRecord] = []
    /// MCP servers that refused to start. These used to be collected and
    /// dropped, so an agent would answer from memory with no tools and no
    /// explanation anywhere in the UI.
    @Published private(set) var toolWarnings: [String] = []

    private var task: Task<Void, Never>?
    /// Identifies the run a completion belongs to. A cancelled run's tail used
    /// to arrive late and clear `isRunning` (or steal the history entry) for
    /// the run that had already replaced it.
    private var generation = 0
    private var currentGraph: FlowGraph?
    private var runStarted: Date?
    /// Tokens arrive far faster than a screen refreshes. Publishing each one
    /// invalidated every view observing this controller and re-laid-out the
    /// whole accumulated output on each card; these are batched instead.
    private var pendingDeltas: [UUID: String] = [:]
    private var flushTask: Task<Void, Never>?

    func state(for id: UUID) -> NodeRunState { states[id] ?? .idle }

    var hasRun: Bool { !states.isEmpty || startupError != nil }

    func reset() {
        flushTask?.cancel()
        flushTask = nil
        pendingDeltas = [:]
        states = [:]
        outputs = [:]
        decisions = [:]
        streaming = []
        startupError = nil
        toolWarnings = []
    }

    func run(_ graph: FlowGraph, registry: ProviderRegistry,
             mcpServers: [MCPServerConfig] = []) {
        cancel()
        reset()
        isRunning = true
        currentGraph = graph
        runStarted = Date()
        // Seed every node as idle so the canvas dims un-started branches.
        for node in graph.nodes { states[node.id] = .idle }

        // Launch only the servers this graph's agents actually reference.
        let usedServerIDs = Set(graph.nodes.flatMap { node -> [String] in
            if case .agent(let config) = node.config { return config.toolServerIDs }
            return []
        })
        let servers = mcpServers.filter { usedServerIDs.contains($0.id) && $0.enabled }
        let toolbox: MCPToolbox? = servers.isEmpty ? nil : MCPToolbox()

        generation += 1
        let generation = generation
        let engine = FlowEngine(providers: registry, toolbox: toolbox)
        task = Task { [weak self] in
            if let toolbox {
                await toolbox.start(servers: servers)
                let failures = await toolbox.failures
                if !failures.isEmpty, let self, self.generation == generation {
                    self.toolWarnings = failures.map { "\($0.serverName): \($0.message)" }
                }
            }
            do {
                for try await event in engine.run(graph) {
                    // A late event from a run the user already replaced must
                    // not paint over the new one's nodes.
                    guard let self, self.generation == generation else { return }
                    self.apply(event)
                }
            } catch is CancellationError {
                // User pressed Stop — leave the partial state on screen.
            } catch {
                if let self, self.generation == generation {
                    self.startupError = Self.describe(error)
                }
            }
            await toolbox?.shutdown()
            // A later run may already own the controller; this tail must not
            // touch its state.
            guard let self, self.generation == generation else { return }
            self.isRunning = false
            self.streaming = []
            self.finalizeHistory()
        }
    }

    /// Records the finished (or stopped) run for the history panel.
    private func finalizeHistory() {
        guard let graph = currentGraph, let started = runStarted else { return }
        currentGraph = nil
        runStarted = nil
        let lines: [RunResultLine] = graph.nodes.compactMap { node in
            guard let output = outputs[node.id], !output.isEmpty else { return nil }
            return RunResultLine(name: node.name,
                                 output: output,
                                 failed: states[node.id] == .failed)
        }
        guard !lines.isEmpty else { return }
        history.insert(RunRecord(
            date: started,
            flowName: graph.name,
            duration: Date().timeIntervalSince(started),
            results: lines,
            hadFailure: lines.contains(where: \.failed) || startupError != nil
        ), at: 0)
        if history.count > 20 { history.removeLast() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        flushDeltas()
        // Invalidate the run being cancelled so its tail can't write back.
        generation += 1
        isRunning = false
        streaming = []
    }

    private func apply(_ event: FlowEvent) {
        switch event {
        case .flowStarted:
            break
        case .nodeStarted(let id):
            states[id] = .running
            outputs[id] = ""
            // Drop anything still buffered for this node — a re-run of the
            // same node must not inherit the previous pass's tokens.
            pendingDeltas[id] = nil
            streaming.insert(id)
        case .nodeDelta(let id, let text):
            pendingDeltas[id, default: ""] += text
            scheduleFlush()
        case .conditionRouted(let id, let tookYes):
            decisions[id] = tookYes
        case .nodeFinished(let id, let output):
            flushDeltas()
            states[id] = .done
            outputs[id] = output
            streaming.remove(id)
        case .nodeSkipped(let id):
            flushDeltas()
            states[id] = .skipped
            streaming.remove(id)
        case .nodeFailed(let id, let message):
            flushDeltas()
            states[id] = .failed
            outputs[id] = message
            streaming.remove(id)
        case .flowFinished:
            flushDeltas()
            isRunning = false
            streaming = []
        }
    }

    /// Applies buffered tokens in one publish.
    private func flushDeltas() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingDeltas.isEmpty else { return }
        for (id, text) in pendingDeltas {
            outputs[id, default: ""] += text
        }
        pendingDeltas = [:]
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000) // ~25 fps
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flushDeltas()
        }
    }

    private static func describe(_ error: Error) -> String {
        if let engineError = error as? FlowEngineError { return engineError.description }
        return error.localizedDescription
    }
}
