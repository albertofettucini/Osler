import Foundation

/// What a provider wants done with one parsed SSE `data:` payload.
enum ProviderStreamAction: Equatable, Sendable {
    case text(String)
    case stop
    case ignore
    case error(String)
}

enum SSE {
    /// Extracts the payload of an SSE `data:` line; nil for any other line
    /// (`event:`, comments, blanks).
    static func dataPayload(of line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
    }

    /// Reads a (bounded) error body and pulls out `{"error":{"message":…}}`
    /// — the shape both Anthropic and OpenAI use — falling back to raw text.
    static func errorMessage(from bytes: URLSession.AsyncBytes) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > 100_000 { break }
            }
        } catch {
            // Whatever arrived before the connection dropped is still useful.
        }
        struct Envelope: Decodable {
            struct Payload: Decodable { let message: String? }
            let error: Payload?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           let message = envelope.error?.message {
            return message
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.isEmpty ? "No error details returned." : raw
    }

    /// Shared transport: performs the request, surfaces non-200s as
    /// `LLMProviderError.api`, then turns `data:` lines into text deltas via
    /// the provider's parser. Cancelling the consumer cancels the request.
    static func openStream(
        _ request: URLRequest,
        session: URLSession = .shared,
        parse: @escaping @Sendable (String) -> ProviderStreamAction
    ) async throws -> AsyncThrowingStream<String, Error> {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse("Response was not HTTP.")
        }
        guard http.statusCode == 200 else {
            let message = await errorMessage(from: bytes)
            throw LLMProviderError.api(statusCode: http.statusCode, message: message)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Split strictly on LF (stripping a trailing CR). Do NOT use
                    // `bytes.lines`: AsyncLineSequence also breaks on U+2028,
                    // U+2029, and NEL, which are legal *unescaped* inside a JSON
                    // string, so an LLM emitting one would split a `data:` line
                    // mid-JSON and the whole delta would be silently dropped.
                    var lineBytes: [UInt8] = []
                    for try await byte in bytes {
                        guard byte != 0x0A else {
                            if !(try handle(&lineBytes, continuation, parse)) { return }
                            continue
                        }
                        lineBytes.append(byte)
                    }
                    // Flush a final line with no trailing newline.
                    if !lineBytes.isEmpty {
                        _ = try handle(&lineBytes, continuation, parse)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Decodes one accumulated line and applies the parser. Returns false when
    /// the stream should stop (an SSE stop marker). Throws on a stream error.
    /// Resets `lineBytes` for the next line.
    private static func handle(
        _ lineBytes: inout [UInt8],
        _ continuation: AsyncThrowingStream<String, Error>.Continuation,
        _ parse: (String) -> ProviderStreamAction
    ) throws -> Bool {
        if lineBytes.last == 0x0D { lineBytes.removeLast() } // strip CR of a CRLF
        let line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)
        guard let payload = dataPayload(of: line) else { return true }
        switch parse(payload) {
        case .text(let text):
            continuation.yield(text)
            return true
        case .stop:
            continuation.finish()
            return false
        case .ignore:
            return true
        case .error(let message):
            throw LLMProviderError.stream(message)
        }
    }
}
