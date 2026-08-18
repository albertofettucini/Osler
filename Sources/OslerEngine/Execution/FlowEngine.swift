import Foundation

// MARK: - Run state & events

public enum NodeRunState: String, Codable, Hashable, Sendable {
    case idle
    case running
    case done
    case failed
    case skipped
}

/// Everything the UI (or CLI) needs to render a run live.
public enum FlowEvent: Equatable, Sendable {
    case flowStarted
    case nodeStarted(id: UUID)
    /// A streamed chunk of text from an agent node.
    case nodeDelta(id: UUID, text: String)
    /// A Condition node resolved: `tookYes` is the branch that carries the value.
    /// Lets a canvas highlight the taken edge.
    case conditionRouted(id: UUID, tookYes: Bool)
    case nodeFinished(id: UUID, output: String)
    /// The node sat on a branch the flow didn't take (or downstream of a failure).
    case nodeSkipped(id: UUID)
    case nodeFailed(id: UUID, message: String)
    case flowFinished(FlowRunSummary)
}

public struct FlowRunSummary: Equatable, Sendable {
    public var outputs: [UUID: String] = [:]
    public var failures: [UUID: String] = [:]
    public var skipped: Set<UUID> = []
    /// For each Condition node that ran: `true` = took the yes branch.
    public var decisions: [UUID: Bool] = [:]

    public init() {}
}

public enum FlowEngineError: Error, Sendable, CustomStringConvertible {
    case validation(GraphValidationError)
    case ambiguousConditionAnswer(String)
    case unsupportedNode(rawType: String)
    case toolLoopLimit(rounds: Int)

    public var description: String {
        switch self {
        case .validation(let error):
            return error.description
        case .ambiguousConditionAnswer(let answer):
            return "The condition model didn't answer YES or NO (it said: \"\(answer)\")."
        case .unsupportedNode(let rawType):
            return "This flow contains an unsupported node type (\(rawType)) saved by a newer app version."
        case .toolLoopLimit(let rounds):
            return "The agent kept calling tools for \(rounds) rounds without finishing — stopped to avoid an endless loop."
        }
    }
}

// MARK: - Engine

/// Headless flow executor. Validates the graph, then runs nodes as their
/// inputs become ready — independent branches run concurrently. Per-node
/// progress streams out as `FlowEvent`s.
///
/// Execution semantics:
/// - A node runs once every incoming edge is resolved (carries a value or is dead).
/// - Multiple live inputs are joined with a blank line, in edge order.
/// - A Condition node passes its input through the taken port; edges on the
///   other port go dead, and nodes whose inputs are all dead are skipped.
/// - A failed node marks all its outgoing edges dead; other branches continue.
public struct FlowEngine: Sendable {
    public var providers: ProviderRegistry
    /// Executes MCP tools for tool-enabled agents; nil = agents run tool-less.
    public var toolbox: (any ToolExecutor)?

    public init(providers: ProviderRegistry = ProviderRegistry(),
                toolbox: (any ToolExecutor)? = nil) {
        self.providers = providers
        self.toolbox = toolbox
    }

    /// Runs the graph. Cancel the consuming task to cancel the run.
    public func run(_ graph: FlowGraph) -> AsyncThrowingStream<FlowEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try GraphValidator.validate(graph)
                    continuation.yield(.flowStarted)
                    let summary = try await execute(graph) { continuation.yield($0) }
                    continuation.yield(.flowFinished(summary))
                    continuation.finish()
                } catch let error as GraphValidationError {
                    continuation.finish(throwing: FlowEngineError.validation(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Scheduling

    private struct NodeOutcome: Sendable {
        var text: String
        /// Only set for condition nodes: which port carries the value onward.
        var decision: Bool?
    }

    private enum EdgeState {
        case pending
        case live(String)
        case dead
    }

    private func execute(
        _ graph: FlowGraph,
        emit: @escaping @Sendable (FlowEvent) -> Void
    ) async throws -> FlowRunSummary {
        let nodesByID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let incoming = Dictionary(grouping: graph.edges, by: \.to)
        let outgoing = Dictionary(grouping: graph.edges, by: \.from)

        return try await withThrowingTaskGroup(of: (UUID, Result<NodeOutcome, Error>).self) { group in
            var summary = FlowRunSummary()
            var edgeStates: [UUID: EdgeState] = [:]
            for edge in graph.edges {
                edgeStates[edge.id] = .pending
            }
            var nodeStates: [UUID: NodeRunState] = [:]
            for node in graph.nodes {
                nodeStates[node.id] = .idle
            }
            var runningCount = 0
            // Finished outputs by node name, for {{Name}} references. Captured
            // per start(): a node only starts once every ancestor has settled,
            // so whatever it can legally reference is already in here.
            var outputsByName: [String: String] = [:]

            func start(_ node: Node, input: String) {
                nodeStates[node.id] = .running
                emit(.nodeStarted(id: node.id))
                runningCount += 1
                let references = outputsByName
                group.addTask {
                    do {
                        let outcome = try await self.runNode(node, input: input,
                                                             references: references, emit: emit)
                        return (node.id, .success(outcome))
                    } catch {
                        return (node.id, .failure(error))
                    }
                }
            }

            // Resolves the outgoing edges of a finished/failed/skipped node,
            // then walks downstream: starts nodes that became ready, and
            // cascades skips through branches whose inputs all went dead.
            func settleDownstream(of node: Node, outcome: NodeOutcome?) {
                var frontier: [UUID] = []
                for edge in outgoing[node.id] ?? [] {
                    let isLive: Bool
                    if let outcome {
                        if node.kind == .condition, let decision = outcome.decision {
                            let takenPort: SourcePort = decision ? .yes : .no
                            isLive = edge.fromPort == takenPort
                        } else {
                            isLive = true
                        }
                    } else {
                        isLive = false
                    }
                    edgeStates[edge.id] = isLive ? .live(outcome?.text ?? "") : .dead
                    frontier.append(edge.to)
                }

                while let nodeID = frontier.popLast() {
                    guard nodeStates[nodeID] == .idle, let target = nodesByID[nodeID] else { continue }
                    let inputEdges = incoming[nodeID] ?? []
                    var liveValues: [String] = []
                    var allResolved = true
                    for edge in inputEdges {
                        switch edgeStates[edge.id] ?? .pending {
                        case .pending:
                            allResolved = false
                        case .live(let value):
                            liveValues.append(value)
                        case .dead:
                            break
                        }
                    }
                    guard allResolved else { continue }

                    if !inputEdges.isEmpty && liveValues.isEmpty {
                        // Every input is dead — this node is off the taken path.
                        nodeStates[nodeID] = .skipped
                        summary.skipped.insert(nodeID)
                        emit(.nodeSkipped(id: nodeID))
                        for edge in outgoing[nodeID] ?? [] {
                            edgeStates[edge.id] = .dead
                            frontier.append(edge.to)
                        }
                    } else {
                        start(target, input: liveValues.joined(separator: "\n\n"))
                    }
                }
            }

            // Kick off every source node (no incoming edges).
            for node in graph.nodes where (incoming[node.id] ?? []).isEmpty {
                start(node, input: "")
            }

            while runningCount > 0 {
                // Stop promptly if the consumer cancelled — don't grind through
                // the rest of the graph or report a cancelled node as failed.
                try Task.checkCancellation()
                guard let (nodeID, result) = try await group.next() else { break }
                runningCount -= 1
                guard let node = nodesByID[nodeID] else { continue }
                switch result {
                case .success(let outcome):
                    nodeStates[nodeID] = .done
                    summary.outputs[nodeID] = outcome.text
                    outputsByName[FlowReference.key(node.name)] = outcome.text
                    if let decision = outcome.decision {
                        summary.decisions[nodeID] = decision
                        emit(.conditionRouted(id: nodeID, tookYes: decision))
                    }
                    emit(.nodeFinished(id: nodeID, output: outcome.text))
                    settleDownstream(of: node, outcome: outcome)
                case .failure(let error):
                    // A cancelled node's error is cancellation, not a real
                    // failure — swallow it and let the next check unwind.
                    if error is CancellationError { continue }
                    nodeStates[nodeID] = .failed
                    let message = Self.describe(error)
                    summary.failures[nodeID] = message
                    emit(.nodeFailed(id: nodeID, message: message))
                    settleDownstream(of: node, outcome: nil)
                }
            }
            try Task.checkCancellation()

            // A validated DAG resolves every node; this is a safety net only.
            for node in graph.nodes where nodeStates[node.id] == .idle {
                nodeStates[node.id] = .skipped
                summary.skipped.insert(node.id)
                emit(.nodeSkipped(id: node.id))
            }

            return summary
        }
    }

    // MARK: Node execution

    private func runNode(
        _ node: Node,
        input: String,
        references: [String: String],
        emit: @escaping @Sendable (FlowEvent) -> Void
    ) async throws -> NodeOutcome {
        switch node.config {
        case .input(let text):
            return NodeOutcome(text: text, decision: nil)

        case .output:
            return NodeOutcome(text: input, decision: nil)

        case .agent(let config):
            let provider = try providers.provider(for: config.provider)
            // {{Name}} in the system prompt becomes that node's output.
            let systemPrompt = FlowReference.resolve(config.systemPrompt, with: references)
            let request = LLMRequest(
                model: config.model,
                systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                userText: input,
                temperature: config.temperature,
                maxTokens: config.maxTokens
            )

            // Tool-enabled agents run the (non-streamed) tool loop; everyone
            // else keeps the live streaming path.
            if let toolbox, !config.toolServerIDs.isEmpty {
                let tools = await toolbox.tools(for: config.toolServerIDs)
                if !tools.isEmpty {
                    return try await runToolLoop(node: node, provider: provider,
                                                 request: request, tools: tools,
                                                 toolbox: toolbox,
                                                 allowedServerIDs: config.toolServerIDs,
                                                 emit: emit)
                }
            }

            var fullText = ""
            for try await chunk in try await provider.streamText(request) {
                // Cancellation here drops the stream iterator, which tears down
                // the in-flight HTTP request instead of letting it run to end.
                try Task.checkCancellation()
                fullText += chunk
                emit(.nodeDelta(id: node.id, text: chunk))
            }
            return NodeOutcome(text: fullText, decision: nil)

        case .condition(let rule):
            let decision = try await evaluate(rule, input: input, references: references)
            // Condition passes its input through the taken port unchanged; the
            // yes/no routing itself is surfaced via `.conditionRouted`, not deltas.
            return NodeOutcome(text: input, decision: decision)

        case .unknown(let rawType, _):
            // Unreachable in practice — validate() rejects unknown nodes before
            // a run starts — but kept explicit rather than crashing.
            throw FlowEngineError.unsupportedNode(rawType: rawType)
        }
    }

    /// The agent's tool loop: model turn → run requested tools → feed results
    /// back → repeat, until the model answers with text only. Bounded so a
    /// confused model can't spin forever; tool results are size-capped so a
    /// runaway tool can't blow up the context.
    private func runToolLoop(
        node: Node,
        provider: any LLMProvider,
        request: LLMRequest,
        tools: [LLMTool],
        toolbox: any ToolExecutor,
        allowedServerIDs: [String],
        emit: @escaping @Sendable (FlowEvent) -> Void
    ) async throws -> NodeOutcome {
        let maxRounds = 8
        let resultCap = 20_000
        var transcript: [LLMMessage] = [.user(request.userText)]
        var finalText = ""

        for _ in 0..<maxRounds {
            try Task.checkCancellation()
            let turn = try await provider.completeTurn(request, tools: tools, transcript: transcript)

            if !turn.text.isEmpty {
                let chunk = finalText.isEmpty ? turn.text : "\n" + turn.text
                finalText += chunk
                emit(.nodeDelta(id: node.id, text: chunk))
            }
            transcript.append(.assistant(text: turn.text, toolCalls: turn.toolCalls))

            guard !turn.toolCalls.isEmpty else {
                return NodeOutcome(text: finalText, decision: nil)
            }

            for call in turn.toolCalls {
                try Task.checkCancellation()
                emit(.nodeDelta(id: node.id, text: "\n⚙︎ \(call.name)…\n"))
                let result = await toolbox.call(name: call.name,
                                                argumentsJSON: call.argumentsJSON,
                                                allowedServerIDs: allowedServerIDs)
                transcript.append(.toolResult(
                    callID: call.id,
                    content: Self.clamp(result.content, to: resultCap),
                    isError: result.isError
                ))
            }
        }
        throw FlowEngineError.toolLoopLimit(rounds: maxRounds)
    }

    /// Caps an oversized tool result without handing the model a lie.
    ///
    /// A raw `prefix(n)` can slice through the middle of a JSON payload, and
    /// the model has no way to tell a truncated object from a malformed one.
    /// So: cut on the last line break before the limit when there is one
    /// (line-oriented output stays whole-record), and always say out loud that
    /// something was dropped.
    static func clamp(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        // Only honour a line break that isn't hiding right at the start —
        // otherwise a single long line would collapse to almost nothing.
        let body: Substring
        if let lastBreak = head.lastIndex(of: "\n"),
           head.distance(from: head.startIndex, to: lastBreak) > limit / 2 {
            body = head[..<lastBreak]
        } else {
            body = head
        }
        let dropped = text.count - body.count
        return body + "\n\n[Truncated by Osler: \(dropped) more characters were omitted. " +
            "Treat this result as incomplete — narrow the request if you need the rest.]"
    }

    private func evaluate(_ rule: ConditionRule, input: String,
                          references: [String: String]) async throws -> Bool {
        switch rule {
        case .containsKeyword(let keyword):
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            return input.range(of: trimmed, options: [.caseInsensitive]) != nil

        case .llmYesNo(let question, let providerID, let model):
            let provider = try providers.provider(for: providerID)
            let request = LLMRequest(
                model: model,
                systemPrompt: """
                You are a routing switch inside a workflow engine. Read the question and \
                the text, then answer with exactly one word: YES or NO. \
                No punctuation, no explanation.
                """,
                userText: "Question: \(FlowReference.resolve(question, with: references))\n\nText:\n\(input)",
                temperature: nil,
                maxTokens: 16
            )
            var answer = ""
            for try await chunk in try await provider.streamText(request) {
                try Task.checkCancellation()
                answer += chunk
            }
            let normalized = answer.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if normalized.hasPrefix("YES") { return true }
            if normalized.hasPrefix("NO") { return false }
            throw FlowEngineError.ambiguousConditionAnswer(answer)
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let error as LLMProviderError: return error.description
        case let error as FlowEngineError: return error.description
        case let error as GraphValidationError: return error.description
        case let error as URLError:
            switch error.code {
            case .timedOut:
                return "The request timed out — the model took too long to respond."
            case .cancelled:
                return "The request was cancelled."
            case .notConnectedToInternet, .networkConnectionLost:
                return "No internet connection."
            default:
                return error.localizedDescription
            }
        default:
            return error.localizedDescription
        }
    }
}
