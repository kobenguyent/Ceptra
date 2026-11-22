import XCTest
@testable import CeptraCore

final class AIStreamParserTests: XCTestCase {
    func testOpenAISSEParserHandlesDeltasUsageAndDone() throws {
        var parser = OpenAISSELineParser()
        XCTAssertEqual(try parser.consume(line: ": keep-alive"), [])
        XCTAssertEqual(try parser.consume(line: ""), [])

        let d1 = try parser.consume(line: #"data: {"choices":[{"delta":{"content":"Feature("}}]}"#)
        XCTAssertEqual(d1, [.text("Feature(")])

        let d2 = try parser.consume(line: #"data: {"choices":[{"delta":{"content":"'Login');"},"finish_reason":"stop"}],"usage":{"prompt_tokens":120,"completion_tokens":34}}"#)
        XCTAssertEqual(d2, [
            .text("'Login');"),
            .completed(stopReason: "stop"),
            .usage(AIUsageStats(inputTokens: 120, outputTokens: 34))
        ])

        let d3 = try parser.consume(line: "data: [DONE]")
        XCTAssertEqual(d3, [.completed(stopReason: "stop")])
    }

    func testAnthropicSSEParserHandlesContentBlockDeltaAndStop() throws {
        var parser = AnthropicSSELineParser()
        XCTAssertEqual(try parser.consume(line: "event: message_start"), [])
        let start = try parser.consume(line: #"data: {"type":"message_start","message":{"usage":{"input_tokens":88}}}"#)
        XCTAssertEqual(start, [.usage(AIUsageStats(inputTokens: 88, outputTokens: nil))])

        XCTAssertEqual(try parser.consume(line: "event: content_block_delta"), [])
        let chunk = try parser.consume(line: #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"I.click('Sign In');"}}"#)
        XCTAssertEqual(chunk, [.text("I.click('Sign In');")])

        XCTAssertEqual(try parser.consume(line: "event: message_delta"), [])
        let end = try parser.consume(line: #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":19}}"#)
        XCTAssertEqual(end, [
            .usage(AIUsageStats(inputTokens: nil, outputTokens: 19)),
            .completed(stopReason: "end_turn")
        ])
    }

    func testGeminiSSEParserHandlesCandidatesAndUsage() throws {
        var parser = GeminiSSELineParser()
        let chunk = try parser.consume(
            line: #"data: {"candidates":[{"content":{"parts":[{"text":"Scenario('checkout', ({ I }) => {});"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":50,"candidatesTokenCount":12}}"#
        )
        XCTAssertEqual(chunk, [
            .text("Scenario('checkout', ({ I }) => {});"),
            .completed(stopReason: "STOP"),
            .usage(AIUsageStats(inputTokens: 50, outputTokens: 12))
        ])
    }

    func testOllamaNDJSONParserHandlesStreamingChunksAndCompletion() throws {
        var parser = OllamaNDJSONLineParser()
        let c1 = try parser.consume(line: #"{"message":{"role":"assistant","content":"I.amOnPage('/login');"},"done":false}"#)
        XCTAssertEqual(c1, [.text("I.amOnPage('/login');")])

        let c2 = try parser.consume(line: #"{"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":42,"eval_count":15}"#)
        XCTAssertEqual(c2, [
            .usage(AIUsageStats(inputTokens: 42, outputTokens: 15)),
            .completed(stopReason: "stop")
        ])
    }

    func testClaudeCLIStreamJSONParserHandlesStreamEventsAndResultDeduplication() throws {
        var parser = ClaudeCLIStreamJSONLineParser()
        let c1 = try parser.consume(line: #"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Fixed locator"}}}"#)
        XCTAssertEqual(c1, [.text("Fixed locator")])

        // Result repeats full text; parser must NOT double-emit text since delta was already streamed
        let c2 = try parser.consume(line: #"{"type":"result","is_error":false,"result":"Fixed locator"}"#)
        XCTAssertEqual(c2, [.completed(stopReason: "stop")])
    }
}
