import Foundation

/// One prompt → one streamed text completion. Providers are intentionally
/// this small so adding a new backend is a single type.
public protocol LLMProvider: Sendable {
    /// Opens a streaming completion. Throws early for configuration or HTTP
    /// errors; the returned stream yields text deltas as they arrive.
    func streamText(_ request: LLMRequest) async throws -> AsyncThrowingStream<String, Error>

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
    /// Fallback for providers without tool support: run the plain streaming
    /// path on the LAST user text and never call tools.
    public func completeTurn(
        _ request: LLMRequest,
        tools: [LLMTool],
        transcript: [LLMMessage]
    ) async throws -> LLMTurnResult {
        var text = ""
        for try await chunk in try await streamText(request) {
            text += chunk
        }
        return LLMTurnResult(text: text, toolCalls: [])
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
