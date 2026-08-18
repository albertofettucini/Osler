import XCTest
@testable import OslerEngine

final class SSEParsingTests: XCTestCase {

    // MARK: Line splitting

    func testDataPayloadExtraction() {
        XCTAssertEqual(SSE.dataPayload(of: #"data: {"a":1}"#), #"{"a":1}"#)
        XCTAssertEqual(SSE.dataPayload(of: "data:[DONE]"), "[DONE]")
        XCTAssertEqual(SSE.dataPayload(of: "data: [DONE]"), "[DONE]")
        XCTAssertNil(SSE.dataPayload(of: "event: content_block_delta"))
        XCTAssertNil(SSE.dataPayload(of: ""))
        XCTAssertNil(SSE.dataPayload(of: ": comment"))
    }

    // MARK: Anthropic

    func testAnthropicTextDelta() {
        let payload = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
        XCTAssertEqual(AnthropicProvider.parse(payload: payload), .text("Hello"))
    }

    func testAnthropicIgnoresNonTextDeltas() {
        let payload = #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{"}}"#
        XCTAssertEqual(AnthropicProvider.parse(payload: payload), .ignore)
    }

    func testAnthropicHousekeepingEventsAreIgnored() {
        for payload in [
            #"{"type":"message_start","message":{"id":"msg_1","type":"message"}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}"#,
            #"{"type":"ping"}"#,
        ] {
            XCTAssertEqual(AnthropicProvider.parse(payload: payload), .ignore, "for \(payload)")
        }
    }

    func testAnthropicMessageStopEndsStream() {
        XCTAssertEqual(AnthropicProvider.parse(payload: #"{"type":"message_stop"}"#), .stop)
    }

    func testAnthropicStreamErrorSurfacesMessage() {
        let payload = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertEqual(AnthropicProvider.parse(payload: payload), .error("Overloaded"))
    }

    func testAnthropicGarbageIsIgnored() {
        XCTAssertEqual(AnthropicProvider.parse(payload: "not json"), .ignore)
    }

    // MARK: OpenAI

    func testOpenAITextDelta() {
        let payload = #"{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#
        XCTAssertEqual(OpenAIProvider.parse(payload: payload), .text("Hi"))
    }

    func testOpenAIDoneEndsStream() {
        XCTAssertEqual(OpenAIProvider.parse(payload: "[DONE]"), .stop)
    }

    func testOpenAIFinishChunkIsIgnored() {
        let payload = #"{"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
        XCTAssertEqual(OpenAIProvider.parse(payload: payload), .ignore)
    }

    func testOpenAIRoleOnlyChunkIsIgnored() {
        let payload = #"{"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}"#
        XCTAssertEqual(OpenAIProvider.parse(payload: payload), .ignore)
    }

    func testOpenAIStreamErrorSurfacesMessage() {
        let payload = #"{"error":{"message":"Rate limited","type":"rate_limit_error"}}"#
        XCTAssertEqual(OpenAIProvider.parse(payload: payload), .error("Rate limited"))
    }

    func testOpenAIGarbageIsIgnored() {
        XCTAssertEqual(OpenAIProvider.parse(payload: "not json"), .ignore)
    }

    // MARK: Stream termination
    //
    // A dropped connection used to look exactly like a finished answer: the
    // byte sequence just ended and the node was marked done with whatever
    // text had arrived. These pin the difference.

    private func collect(_ text: String) async -> Result<[String], Error> {
        let bytes = SyntheticBytes(text)
        do {
            var chunks: [String] = []
            for try await chunk in SSE.decode(bytes: bytes, parse: { OpenAIProvider.parse(payload: $0) }) {
                chunks.append(chunk)
            }
            return .success(chunks)
        } catch {
            return .failure(error)
        }
    }

    func testStreamEndingWithDoneSucceeds() async throws {
        let body = [
            #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"lo"}}]}"#,
            "data: [DONE]",
            "",
        ].joined(separator: "\n")
        let result = await collect(body)
        XCTAssertEqual(try result.get(), ["Hel", "lo"])
    }

    func testStreamCutOffMidAnswerIsAnErrorNotAPartialSuccess() async throws {
        let body = #"data: {"choices":[{"delta":{"content":"Hel"}}]}"# + "\n"
        guard case .failure(let error) = await collect(body) else {
            return XCTFail("A truncated stream must not be reported as a complete answer.")
        }
        guard case LLMProviderError.stream(let message) = error else {
            return XCTFail("Expected a stream error, got \(error)")
        }
        XCTAssertTrue(message.contains("incomplete"), message)
    }

    func testA200ThatIsNotEventStreamIsAnError() async throws {
        // e.g. a proxy returning an HTML interstitial with a 200.
        guard case .failure = await collect("<html>upgrade required</html>") else {
            return XCTFail("A non-SSE 200 must not be reported as an empty success.")
        }
    }
}

/// Minimal `AsyncSequence` over a byte array, so the decoder can be tested
/// without standing up an HTTP server.
private struct SyntheticBytes: AsyncSequence, Sendable {
    typealias Element = UInt8
    let bytes: [UInt8]

    init(_ text: String) { bytes = Array(text.utf8) }

    struct Iterator: AsyncIteratorProtocol {
        var remaining: ArraySlice<UInt8>
        mutating func next() async -> UInt8? {
            guard let byte = remaining.first else { return nil }
            remaining = remaining.dropFirst()
            return byte
        }
    }

    func makeAsyncIterator() -> Iterator { Iterator(remaining: bytes[...]) }
}
