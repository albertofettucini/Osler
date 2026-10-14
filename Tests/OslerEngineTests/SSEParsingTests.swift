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

    func testAnthropicMaxTokensStopIsACutOff() {
        let payload = #"{"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null},"usage":{"output_tokens":20}}"#
        XCTAssertEqual(AnthropicProvider.parse(payload: payload), .cutOff(text: ""))
    }

    func testAnthropicToolTurnStoppedAtMaxTokensIsACutOff() {
        let response: JSONValue = .object([
            "stop_reason": .string("max_tokens"),
            "content": .array([
                .object(["type": .string("text"), "text": .string("Let me check")]),
                .object(["type": .string("tool_use"), "id": .string("t1"), "name": .string("search"),
                         "input": .object([:])]),
            ]),
        ])
        let turn = AnthropicProvider.turnResult(from: response)
        XCTAssertTrue(turn.cutOff)
        XCTAssertEqual(turn.text, "Let me check")
        XCTAssertEqual(turn.toolCalls.map(\.name), ["search"])

        let finished: JSONValue = .object([
            "stop_reason": .string("end_turn"),
            "content": .array([.object(["type": .string("text"), "text": .string("Done.")])]),
        ])
        XCTAssertFalse(AnthropicProvider.turnResult(from: finished).cutOff)
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

    func testOpenAILengthFinishIsACutOff() {
        let payload = #"{"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#
        XCTAssertEqual(OpenAIProvider.parse(payload: payload), .cutOff(text: ""))
    }

    func testLengthFinishCarryingTheLastChunkKeepsTheText() {
        // OpenAI-compatible servers (Ollama among them) may put the final
        // text and the finish reason in one chunk.
        let payload = #"{"choices":[{"index":0,"delta":{"role":"assistant","content":" end"},"finish_reason":"length"}]}"#
        XCTAssertEqual(OpenAIProvider.parse(payload: payload), .cutOff(text: " end"))
    }

    func testOpenAIToolTurnStoppedAtLengthIsACutOff() {
        let response: JSONValue = .object([
            "choices": .array([.object([
                "finish_reason": .string("length"),
                "message": .object([
                    "content": .null,
                    "tool_calls": .array([.object([
                        "id": .string("c1"),
                        "function": .object(["name": .string("search"), "arguments": .string(#"{"q":"#)]),
                    ])]),
                ]),
            ])]),
        ])
        let turn = OpenAIProvider.turnResult(from: response)
        XCTAssertTrue(turn.cutOff)
        XCTAssertEqual(turn.toolCalls.map(\.argumentsJSON), [#"{"q":"#])

        let finished: JSONValue = .object([
            "choices": .array([.object([
                "finish_reason": .string("stop"),
                "message": .object(["content": .string("Done.")]),
            ])]),
        ])
        XCTAssertFalse(OpenAIProvider.turnResult(from: finished).cutOff)
    }

    // MARK: Stream termination
    //
    // A dropped connection used to look exactly like a finished answer: the
    // byte sequence just ended and the node was marked done with whatever
    // text had arrived. These pin the difference.

    private func collect(
        _ text: String,
        parse: @escaping @Sendable (String) -> ProviderStreamAction = { OpenAIProvider.parse(payload: $0) }
    ) async -> Result<[LLMStreamEvent], Error> {
        let bytes = SyntheticBytes(text)
        do {
            var events: [LLMStreamEvent] = []
            for try await event in SSE.decode(bytes: bytes, parse: parse) {
                events.append(event)
            }
            return .success(events)
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
        XCTAssertEqual(try result.get(), [.text("Hel"), .text("lo")])
    }

    func testOpenAIStreamCutOffAtLengthFinishesWithACutOffEvent() async throws {
        let body = [
            #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#,
            "data: [DONE]",
            "",
        ].joined(separator: "\n")
        let result = await collect(body)
        XCTAssertEqual(try result.get(), [.text("Hel"), .cutOff])
    }

    func testAnthropicStreamCutOffAtMaxTokensFinishesWithACutOffEvent() async throws {
        let body = [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
            "event: message_delta",
            #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":1}}"#,
            "event: message_stop",
            #"data: {"type":"message_stop"}"#,
            "",
        ].joined(separator: "\n")
        let result = await collect(body, parse: { AnthropicProvider.parse(payload: $0) })
        XCTAssertEqual(try result.get(), [.text("Hel"), .cutOff])
    }

    func testATextOnlyProviderGetsAStreamWithoutCutOffs() async throws {
        // Third-party providers that only implement streamText still work.
        var events: [LLMStreamEvent] = []
        for try await event in try await MockProvider(chunks: { _ in ["a", "b"] })
            .streamEvents(LLMRequest(model: "m", userText: "x")) {
            events.append(event)
        }
        XCTAssertEqual(events, [.text("a"), .text("b")])
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
