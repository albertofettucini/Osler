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
}
