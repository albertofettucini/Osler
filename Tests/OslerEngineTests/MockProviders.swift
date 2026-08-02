import Foundation
@testable import OslerEngine

/// Streams scripted chunks; the handler can inspect the request and throw to
/// simulate a provider failing before the stream opens.
struct MockProvider: LLMProvider {
    var chunks: @Sendable (LLMRequest) throws -> [String]

    func streamText(_ request: LLMRequest) async throws -> AsyncThrowingStream<String, Error> {
        let chunks = try self.chunks(request)
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

/// Yields a partial chunk, then fails mid-stream.
struct MidStreamFailureProvider: LLMProvider {
    var partial: String
    var message: String

    func streamText(_ request: LLMRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(partial)
            continuation.finish(throwing: LLMProviderError.stream(message))
        }
    }
}

/// Yields a first chunk, signals it has started, then sleeps effectively
/// forever so a run can be cancelled mid-stream in tests.
struct SlowMockProvider: LLMProvider {
    var started: @Sendable () -> Void

    func streamText(_ request: LLMRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield("partial…")
                started()
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000) // 60s; cancelled long before
                    continuation.yield("never")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error) // CancellationError
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

func makeRegistry(anthropic: @escaping @Sendable (LLMRequest) throws -> [String]) -> ProviderRegistry {
    var registry = ProviderRegistry()
    registry.register(MockProvider(chunks: anthropic), for: .anthropic)
    return registry
}

// MARK: - Event helpers

func collectEvents(_ engine: FlowEngine, _ graph: FlowGraph) async throws -> [FlowEvent] {
    var events: [FlowEvent] = []
    for try await event in engine.run(graph) {
        events.append(event)
    }
    return events
}

func finalSummary(of events: [FlowEvent]) -> FlowRunSummary? {
    for case .flowFinished(let summary) in events {
        return summary
    }
    return nil
}

func deltas(of events: [FlowEvent], nodeID: UUID) -> String {
    events.compactMap { event -> String? in
        if case .nodeDelta(let id, let text) = event, id == nodeID {
            return text
        }
        return nil
    }.joined()
}
