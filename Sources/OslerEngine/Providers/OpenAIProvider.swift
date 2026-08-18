import Foundation

/// OpenAI Chat Completions API (streaming).
/// POST /v1/chat/completions with `stream: true`.
public struct OpenAIProvider: LLMProvider {
    public var apiKey: String
    public var baseURL: URL
    /// OpenAI-compatible servers (Ollama, LM Studio, llama.cpp) mostly still
    /// only understand `max_tokens`; OpenAI itself rejects it on o-series
    /// models and wants `max_completion_tokens`. Same field, two spellings.
    var usesLegacyMaxTokens = false

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.openai.com/v1/chat/completions")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    init(apiKey: String, baseURL: URL, usesLegacyMaxTokens: Bool) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.usesLegacyMaxTokens = usesLegacyMaxTokens
    }

    public func streamText(_ request: LLMRequest) async throws -> AsyncThrowingStream<String, Error> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw LLMProviderError.missingAPIKey(.openai)
        }

        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = "POST"
        // Idle timeout (resets on each received byte). Chat Completions can be
        // silent for the full reasoning phase of o-series models before the
        // first delta, so match the official SDKs' 600s rather than 120s.
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")

        var messages: [RequestBody.Message] = []
        if let systemPrompt = request.systemPrompt {
            messages.append(.init(role: "system", content: systemPrompt))
        }
        messages.append(.init(role: "user", content: request.userText))

        let body = RequestBody(
            model: request.model,
            stream: true,
            temperature: request.temperature,
            maxCompletionTokens: request.maxTokens,
            messages: messages,
            usesLegacyMaxTokens: usesLegacyMaxTokens
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)

        return try await SSE.openStream(urlRequest) { Self.parse(payload: $0) }
    }

    // MARK: Wire format

    private struct RequestBody: Encodable {
        var model: String
        var stream: Bool
        var temperature: Double?
        var maxCompletionTokens: Int
        var messages: [Message]
        var usesLegacyMaxTokens = false

        struct Message: Encodable {
            var role: String
            var content: String
        }

        enum CodingKeys: String, CodingKey {
            case model, stream, temperature, messages
            case maxCompletionTokens = "max_completion_tokens"
            case maxTokens = "max_tokens"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(stream, forKey: .stream)
            try container.encodeIfPresent(temperature, forKey: .temperature)
            try container.encode(messages, forKey: .messages)
            try container.encode(maxCompletionTokens,
                                 forKey: usesLegacyMaxTokens ? .maxTokens : .maxCompletionTokens)
        }
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }
            let delta: Delta?
        }
        struct APIError: Decodable {
            let message: String?
        }
        let choices: [Choice]?
        let error: APIError?
    }

    /// Parses one SSE `data:` payload. The stream ends with `data: [DONE]`.
    static func parse(payload: String) -> ProviderStreamAction {
        if payload == "[DONE]" {
            return .stop
        }
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else {
            return .ignore
        }
        if let error = chunk.error {
            return .error(error.message ?? "Unknown stream error")
        }
        if let text = chunk.choices?.first?.delta?.content, !text.isEmpty {
            return .text(text)
        }
        return .ignore
    }
}
