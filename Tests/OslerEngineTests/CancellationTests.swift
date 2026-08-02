import XCTest
@testable import OslerEngine

final class CancellationTests: XCTestCase {

    /// Cancelling the task that consumes the event stream must stop the run:
    /// the downstream node never completes and no `flowFinished` is delivered.
    func testCancellingTheConsumerStopsTheRun() async throws {
        let input = Node(name: "Input", config: .input(text: "go"))
        let agent = Node(name: "SlowAgent", config: .agent(AgentConfig()))
        let output = Node(name: "Output", config: .output)
        let graph = FlowGraph(nodes: [input, agent, output], edges: [
            Edge(from: input.id, to: agent.id),
            Edge(from: agent.id, to: output.id),
        ])

        let didStart = AsyncStreamSignal()
        var registry = ProviderRegistry()
        registry.register(SlowMockProvider(started: { didStart.fire() }), for: .anthropic)
        let engine = FlowEngine(providers: registry)

        let runTask = Task { () -> [FlowEvent] in
            var events: [FlowEvent] = []
            for try await event in engine.run(graph) {
                events.append(event)
                // Cancellation-aware consumer: bail as soon as we're cancelled.
                try Task.checkCancellation()
            }
            return events
        }

        // Wait until the agent is mid-stream, then cancel.
        await didStart.wait()
        runTask.cancel()

        do {
            let events = try await runTask.value
            // If it returned instead of throwing, it must not have finished the flow.
            XCTAssertFalse(events.contains { if case .flowFinished = $0 { return true }; return false },
                           "A cancelled run should not deliver flowFinished")
            XCTAssertFalse(events.contains { if case .nodeFinished(output.id, _) = $0 { return true }; return false },
                           "The downstream Output node should not complete after cancel")
        } catch is CancellationError {
            // Expected: the consumer loop unwound on cancellation.
        }
    }

    /// A cancelled agent node must not be reported as a spurious failure.
    func testCancellationIsNotReportedAsNodeFailure() async throws {
        let input = Node(config: .input(text: "go"))
        let agent = Node(name: "SlowAgent", config: .agent(AgentConfig()))
        let output = Node(config: .output)
        let graph = FlowGraph(nodes: [input, agent, output], edges: [
            Edge(from: input.id, to: agent.id),
            Edge(from: agent.id, to: output.id),
        ])

        let didStart = AsyncStreamSignal()
        var registry = ProviderRegistry()
        registry.register(SlowMockProvider(started: { didStart.fire() }), for: .anthropic)
        let engine = FlowEngine(providers: registry)

        let collected = ThreadSafeBox<[FlowEvent]>([])
        let runTask = Task {
            do {
                for try await event in engine.run(graph) {
                    collected.mutate { $0.append(event) }
                    try Task.checkCancellation()
                }
            } catch {}
        }

        await didStart.wait()
        runTask.cancel()
        _ = await runTask.value

        let events = collected.value
        XCTAssertFalse(events.contains { if case .nodeFailed = $0 { return true }; return false },
                       "Cancellation must not surface as a nodeFailed event")
    }
}

// MARK: - Small test concurrency helpers

/// One-shot signal an async test can await and a @Sendable closure can fire.
final class AsyncStreamSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock()
        fired = true
        let toResume = waiters
        waiters.removeAll()
        lock.unlock()
        toResume.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

final class ThreadSafeBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&storage)
    }
}
