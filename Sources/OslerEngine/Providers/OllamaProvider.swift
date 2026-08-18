import Foundation

/// Local models through an Ollama server. Ollama exposes an OpenAI-compatible
/// Chat Completions endpoint (`/v1/chat/completions`), so this is a thin
/// wrapper around `OpenAIProvider` pointed at localhost — no API key, and
/// nothing ever leaves the machine.
public struct OllamaProvider: LLMProvider {
    public static let defaultBaseURL = "http://localhost:11434"

    let innerProvider: OpenAIProvider

    /// `baseURL` is the server root (e.g. "http://localhost:11434"); the
    /// OpenAI-compatible path is appended here.
    public init(baseURL: String = OllamaProvider.defaultBaseURL) {
        let root = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = root.hasSuffix("/") ? String(root.dropLast()) : root
        let url = URL(string: normalized + "/v1/chat/completions")
            ?? URL(string: OllamaProvider.defaultBaseURL + "/v1/chat/completions")!
        // Ollama ignores the Authorization header; any non-empty token works.
        innerProvider = OpenAIProvider(apiKey: "ollama", baseURL: url, usesLegacyMaxTokens: true)
    }

    public func streamText(_ request: LLMRequest) async throws -> AsyncThrowingStream<String, Error> {
        let upstream: AsyncThrowingStream<String, Error>
        do {
            upstream = try await innerProvider.streamText(request)
        } catch {
            throw Self.friendly(error)
        }
        // Connection failures usually surface mid-stream, so the mapping has
        // to wrap the iteration too, not just the opening call.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in upstream { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.friendly(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// "Could not connect to the server" tells a first-time user nothing.
    /// Name the actual cause: Ollama isn't running (or isn't at this URL).
    static func friendly(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            return LLMProviderError.stream("""
            Couldn't reach Ollama. Start it (`ollama serve`), check the server \
            URL in Settings → API Keys, or add an API key to use a hosted model.
            """)
        default:
            return error
        }
    }
}
