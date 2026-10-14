import Foundation

/// One piece of a streamed completion.
public enum LLMStreamEvent: Equatable, Sendable {
    case text(String)
    /// The model stopped at the request's max-tokens limit: the text so far
    /// is all there will be, and it's incomplete.
    case cutOff
}

/// One prompt → one streamed text completion. Providers are intentionally
/// this small so adding a new backend is a single type.
public protocol LLMProvider: Sendable {
    /// Opens a streaming completion. Throws early for configuration or HTTP
    /// errors; the returned stream yields text deltas as they arrive.
    func streamText(_ request: LLMRequest) async throws -> AsyncThrowingStream<String, Error>

    /// The same completion as `streamText`, plus a `.cutOff` event when the
    /// model stopped at `maxTokens` — so an answer that was cut short isn't
    /// presented as a finished one. A provider that only implements
    /// `streamText` gets a default that never reports a cut-off.
    func streamEvents(_ request: LLMRequest) async throws -> AsyncThrowingStream<LLMStreamEvent, Error>

    /// One NON-streamed turn of a tool-calling conversation. `transcript`
    /// carries the whole exchange so far (user text, assistant turns, tool
    /// results); the provider translates it into its own wire format.
    /// Tool-enabled agents trade live streaming for correctness in v1.1 —
    /// each turn's text arrives whole.
    func completeTurn(
        _ request: LLMRequest,
        tools: [LLMTool],
        transcript: [LLMMessage]
    ) async throws -> LLMTurnResult
}

extension LLMProvider {
    /// Fallback for providers that only stream text: every chunk is text,
    /// and a cut-off can't be detected.
    public func streamEvents(_ request: LLMRequest) async throws -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let upstream = try await streamText(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in upstream { continuation.yield(.text(chunk)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Fallback for providers without tool support: run the plain streaming
    /// path on the LAST user text and never call tools.
    public func completeTurn(
        _ request: LLMRequest,
        tools: [LLMTool],
        transcript: [LLMMessage]
    ) async throws -> LLMTurnResult {
        var text = ""
        var cutOff = false
        for try await event in try await streamEvents(request) {
            switch event {
            case .text(let chunk): text += chunk
            case .cutOff: cutOff = true
            }
        }
        return LLMTurnResult(text: text, toolCalls: [], cutOff: cutOff)
    }
}

extension LLMStreamEvent {
    /// Just the text of an event stream: how a provider whose native stream
    /// is `streamEvents` serves `streamText`.
    static func textOnly(
        _ events: AsyncThrowingStream<LLMStreamEvent, Error>
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if case .text(let chunk) = event { continuation.yield(chunk) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct LLMRequest: Equatable, Sendable {
    public var model: String
    public var systemPrompt: String?
    public var userText: String
    public var temperature: Double?
    public var maxTokens: Int

    public init(
        model: String,
        systemPrompt: String? = nil,
        userText: String,
        temperature: Double? = nil,
        maxTokens: Int = 2048
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.userText = userText
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

public enum LLMProviderError: Error, Equatable, Sendable, CustomStringConvertible {
    case notRegistered(ProviderID)
    case missingAPIKey(ProviderID)
    case invalidResponse(String)
    case api(statusCode: Int, message: String)
    case stream(String)

    public var description: String {
        switch self {
        case .notRegistered(let id):
            return "No \(id.displayName) provider is configured. Add a \(id.displayName) API key and try again."
        case .missingAPIKey(let id):
            return "The \(id.displayName) API key is empty."
        case .invalidResponse(let detail):
            return "Unexpected response from the provider: \(detail)"
        case .api(let statusCode, let message):
            return "API error (HTTP \(statusCode)): \(message)"
        case .stream(let message):
            return "Stream error: \(message)"
        }
    }
}

public struct ProviderRegistry: Sendable {
    private var providers: [ProviderID: any LLMProvider] = [:]

    public init() {}

    public mutating func register(_ provider: any LLMProvider, for id: ProviderID) {
        providers[id] = provider
    }

    public func provider(for id: ProviderID) throws -> any LLMProvider {
        guard let provider = providers[id] else {
            throw LLMProviderError.notRegistered(id)
        }
        return provider
    }

    public var registered: [ProviderID] {
        ProviderID.allCases.filter { providers[$0] != nil }
    }
}
