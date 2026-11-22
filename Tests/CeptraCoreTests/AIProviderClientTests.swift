import XCTest
@testable import CeptraCore

private final class MockAIHTTPTransport: AIHTTPTransport, @unchecked Sendable {
    var lastDataRequest: URLRequest?
    var lastStreamRequest: URLRequest?
    var nextDataResponse: AIHTTPResponse = AIHTTPResponse(statusCode: 200, body: Data())
    var nextStreamStatusCode: Int = 200
    var nextStreamHeaders: [String: String] = [:]
    var nextStreamLines: [String] = []

    func data(for request: URLRequest) async throws -> AIHTTPResponse {
        lastDataRequest = request
        return nextDataResponse
    }

    func streamLines(for request: URLRequest) async throws -> AIHTTPStreamResponse {
        lastStreamRequest = request
        let lines = nextStreamLines
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in lines {
                continuation.yield(line)
            }
            continuation.finish()
        }
        return AIHTTPStreamResponse(statusCode: nextStreamStatusCode, headers: nextStreamHeaders, lines: stream)
    }
}

final class AIProviderClientTests: XCTestCase {
    func testOllamaListModelsAndStreamingChatWithoutAPIKey() async throws {
        let transport = MockAIHTTPTransport()
        transport.nextDataResponse = AIHTTPResponse(
            statusCode: 200,
            body: Data(#"{"models":[{"name":"qwen2.5-coder:7b","details":{"parameter_size":"7B"}}]}"#.utf8)
        )
        transport.nextStreamLines = [
            #"{"message":{"content":"I.see("},"done":false}"#,
            #"{"message":{"content":"'Welcome');"},"done":false}"#,
            #"{"message":{"content":""},"done":true}"#
        ]

        let client = AIHTTPProviderClient(transport: transport)
        let profile = AIProviderProfile.defaultOllamaProfile()

        let models = try await client.listModels(profile: profile, apiKey: nil)
        XCTAssertEqual(models.map(\.id), ["qwen2.5-coder:7b"])
        XCTAssertEqual(models.first?.contextHint, "7B")
        XCTAssertEqual(transport.lastDataRequest?.url?.absoluteString, "http://127.0.0.1:11434/api/tags")

        let req = AIChatRequest(
            systemPrompt: "You are a CodeceptJS expert.",
            messages: [AIChatMessage(role: .user, content: "Write assertion")]
        )
        var collected = ""
        for try await delta in client.streamChat(request: req, profile: profile, apiKey: nil) {
            if case .text(let chunk) = delta {
                collected += chunk
            }
        }
        XCTAssertEqual(collected, "I.see('Welcome');")
        XCTAssertEqual(transport.lastStreamRequest?.url?.absoluteString, "http://127.0.0.1:11434/api/chat")
    }

    func testGeminiRequestUsesHeaderNeverQueryParamForAPIKey() throws {
        let client = AIHTTPProviderClient(transport: MockAIHTTPTransport())
        let profile = AIProviderProfile(name: "Gemini", kind: .gemini, modelID: "gemini-2.5-flash")
        let key = "AIzaSyTestHeaderOnlySecret1234567890"
        let req = AIChatRequest(
            systemPrompt: "Sys",
            messages: [AIChatMessage(role: .user, content: "Hi")]
        )

        let chatURLReq = try client.buildChatRequest(request: req, profile: profile, apiKey: key)
        XCTAssertEqual(chatURLReq.value(forHTTPHeaderField: "x-goog-api-key"), key)
        XCTAssertFalse(chatURLReq.url?.absoluteString.contains(key) ?? true)
        XCTAssertTrue(chatURLReq.url?.absoluteString.contains("alt=sse") ?? false)

        let listURLReq = try client.buildListModelsRequest(profile: profile, apiKey: key)
        XCTAssertEqual(listURLReq.value(forHTTPHeaderField: "x-goog-api-key"), key)
        XCTAssertFalse(listURLReq.url?.absoluteString.contains(key) ?? true)
    }

    func testAnthropicHeadersAndStreamingBody() async throws {
        let transport = MockAIHTTPTransport()
        transport.nextStreamLines = [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Use data-testid"}}"#,
            "event: message_stop",
            #"data: {"type":"message_stop"}"#
        ]
        let client = AIHTTPProviderClient(transport: transport)
        let profile = AIProviderProfile(name: "Claude", kind: .anthropic, modelID: "claude-sonnet-4-5")
        let key = "sk-ant-test-key-123456789012"

        let req = AIChatRequest(
            systemPrompt: "CodeceptJS system",
            messages: [AIChatMessage(role: .user, content: "Fix flaky selector")]
        )
        var out = ""
        for try await delta in client.streamChat(request: req, profile: profile, apiKey: key) {
            if case .text(let s) = delta { out += s }
        }
        XCTAssertEqual(out, "Use data-testid")
        XCTAssertEqual(transport.lastStreamRequest?.value(forHTTPHeaderField: "x-api-key"), key)
        XCTAssertEqual(transport.lastStreamRequest?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(transport.lastStreamRequest?.url?.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    func testCloudProviderFailsClosedWhenAPIKeyMissing() throws {
        let client = AIHTTPProviderClient(transport: MockAIHTTPTransport())
        let openAI = AIProviderProfile(name: "OpenAI", kind: .openAI, modelID: "gpt-4.1")
        let req = AIChatRequest(systemPrompt: "", messages: [AIChatMessage(role: .user, content: "Hello")])

        XCTAssertThrowsError(try client.buildChatRequest(request: req, profile: openAI, apiKey: nil)) { error in
            XCTAssertEqual(error as? AIProviderError, .missingAPIKey(providerName: "OpenAI"))
        }
    }

    func testRateLimitAndErrorRedactionFromUpstream() async {
        let transport = MockAIHTTPTransport()
        let secretKey = "sk-proj-VerySecretKeyShouldNotLeak12345"
        transport.nextStreamStatusCode = 429
        transport.nextStreamHeaders = ["Retry-After": "12"]
        transport.nextStreamLines = [
            #"{"error":{"message":"Quota exceeded for key sk-proj-VerySecretKeyShouldNotLeak12345"}}"#
        ]

        let client = AIHTTPProviderClient(transport: transport)
        let profile = AIProviderProfile(name: "OpenAI", kind: .openAI, modelID: "gpt-4.1")
        let req = AIChatRequest(systemPrompt: "", messages: [AIChatMessage(role: .user, content: "Test")])

        do {
            for try await _ in client.streamChat(request: req, profile: profile, apiKey: secretKey) {}
            XCTFail("Expected rateLimited error")
        } catch let err as AIProviderError {
            guard case .rateLimited(let retryAfter, let message) = err else {
                return XCTFail("Unexpected error: \(err)")
            }
            XCTAssertEqual(retryAfter, 12)
            XCTAssertFalse(message.contains(secretKey))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
