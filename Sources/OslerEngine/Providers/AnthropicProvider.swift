import Foundation

/// Anthropic Messages API (streaming).
/// Docs: https://platform.claude.com/docs — POST /v1/messages with `stream: true`.
public struct AnthropicProvider: LLMProvider {
    public var apiKey: String
    public var baseURL: URL

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com/v1/messages")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    public func streamText(_ request: LLMRequest) async throws -> AsyncThrowingStream<String, Error> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw LLMProviderError.missingAPIKey(.anthropic)
        }

        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = "POST"
        // Idle timeout (resets on each received byte). Long generations stream
        // periodic `ping` events, so this bounds a truly stalled connection.
        urlRequest.timeoutInterval = 600
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")

        let body = RequestBody(
            model: request.model,
            maxTokens: request.maxTokens,
            stream: true,
            system: request.systemPrompt,
            temperature: request.temperature,
            messages: [.init(role: "user", content: request.userText)]
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)

        return try await SSE.openStream(urlRequest) { Self.parse(payload: $0) }
    }

    // MARK: Wire format

    private struct RequestBody: Encodable {
        var model: String
        var maxTokens: Int
        var stream: Bool
        var system: String?
        var temperature: Double?
        var messages: [Message]

        struct Message: Encodable {
            var role: String
            var content: String
        }

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case stream, system, temperature, messages
        }
    }

    private struct StreamMessage: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
        }
        struct APIError: Decodable {
            let type: String?
            let message: String?
        }
        let type: String?
        let delta: Delta?
        let error: APIError?
    }

    /// Parses one SSE `data:` payload. We key off the JSON `type` field, so
    /// `event:` lines can be ignored entirely.
    static func parse(payload: String) -> ProviderStreamAction {
        guard let data = payload.data(using: .utf8),
              let message = try? JSONDecoder().decode(StreamMessage.self, from: data) else {
            return .ignore
        }
        switch message.type {
        case "content_block_delta":
            if message.delta?.type == "text_delta", let text = message.delta?.text {
                return .text(text)
            }
            return .ignore
        case "message_stop":
            return .stop
        case "error":
            return .error(message.error?.message ?? "Unknown stream error")
        default:
            // message_start, content_block_start/stop, message_delta, ping…
            return .ignore
        }
    }
}
