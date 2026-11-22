import XCTest
@testable import CeptraCore

private final class MockOllamaHTTPTransport: AIHTTPTransport, @unchecked Sendable {
    var lastDataRequest: URLRequest?
    var lastStreamRequest: URLRequest?
    var nextDataResponse: AIHTTPResponse = AIHTTPResponse(statusCode: 200, body: Data())
    var nextStreamStatusCode: Int = 200
    var nextStreamLines: [String] = []
    var shouldFailData: Bool = false

    func data(for request: URLRequest) async throws -> AIHTTPResponse {
        lastDataRequest = request
        if shouldFailData {
            throw AIProviderError.networkFailure("Connection refused")
        }
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
        return AIHTTPStreamResponse(statusCode: nextStreamStatusCode, lines: stream)
    }
}

final class OllamaManagerTests: XCTestCase {
    func testParseTagsResponseDecodesModelSizesAndDetails() throws {
        let json = """
        {
          "models": [
            {
              "name": "qwen2.5-coder:7b",
              "size": 4683087332,
              "modified_at": "2026-11-20T10:00:00Z",
              "details": {
                "family": "qwen2",
                "parameter_size": "7.6B",
                "quantization_level": "Q4_K_M"
              }
            },
            {
              "name": "llama3.2:3b",
              "size": 950000000
            }
          ]
        }
        """
        let models = try OllamaManager.parseTagsResponse(Data(json.utf8))
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].name, "qwen2.5-coder:7b")
        XCTAssertEqual(models[0].formattedSize, "4.7 GB")
        XCTAssertEqual(models[0].parameterSize, "7.6B")
        XCTAssertEqual(models[0].quantizationLevel, "Q4_K_M")
        XCTAssertEqual(models[0].compactDetails, "4.7 GB · 7.6B · Q4_K_M")

        XCTAssertEqual(models[1].name, "llama3.2:3b")
        XCTAssertEqual(models[1].formattedSize, "950 MB")
    }

    func testModelNameValidationAcceptsValidTagsAndRejectsUnsafeStrings() throws {
        XCTAssertEqual(try OllamaManager.validateModelName("qwen2.5-coder:7b"), "qwen2.5-coder:7b")
        XCTAssertEqual(try OllamaManager.validateModelName("hf.co/bartowski/Qwen2.5-Coder-7B-GGUF:Q4_K_M"), "hf.co/bartowski/Qwen2.5-Coder-7B-GGUF:Q4_K_M")

        XCTAssertThrowsError(try OllamaManager.validateModelName(""))
        XCTAssertThrowsError(try OllamaManager.validateModelName("   "))
        XCTAssertThrowsError(try OllamaManager.validateModelName("qwen; rm -rf /"))
        XCTAssertThrowsError(try OllamaManager.validateModelName("model\nnewline"))
        XCTAssertThrowsError(try OllamaManager.validateModelName("-flag-like"))
    }

    func testStreamingPullProgressAndMidStreamError() async throws {
        let transport = MockOllamaHTTPTransport()
        transport.nextStreamLines = [
            #"{"status":"pulling manifest"}"#,
            #"{"status":"downloading sha256:abc","completed":2350000000,"total":4700000000}"#,
            #"{"status":"verifying sha256 digest"}"#,
            #"{"status":"success"}"#
        ]
        let manager = OllamaManager(probeTransport: transport, streamTransport: transport)
        var events: [OllamaPullProgress] = []
        for try await event in manager.pullModel(name: "qwen2.5-coder:7b", baseURL: "http://127.0.0.1:11434") {
            events.append(event)
        }

        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[1].percentageText, "50%")
        XCTAssertEqual(events[1].byteProgressText, "2.35 GB / 4.70 GB")
        XCTAssertTrue(events[3].isComplete)
        XCTAssertEqual(transport.lastStreamRequest?.url?.absoluteString, "http://127.0.0.1:11434/api/pull")
        XCTAssertEqual(transport.lastStreamRequest?.httpMethod, "POST")

        // Mid-stream Ollama error object must fail loudly
        XCTAssertThrowsError(
            try OllamaManager.parsePullProgressLine(#"{"error":"pull model manifest: file does not exist"}"#, modelName: "bad:tag")
        )
    }

    func testDeleteModelRequestAndRemoteProbeFailure() async throws {
        let transport = MockOllamaHTTPTransport()
        transport.nextDataResponse = AIHTTPResponse(statusCode: 200, body: Data())
        let manager = OllamaManager(probeTransport: transport, streamTransport: transport)

        try await manager.deleteModel(name: "llama3.2:3b", baseURL: "http://127.0.0.1:11434")
        XCTAssertEqual(transport.lastDataRequest?.httpMethod, "DELETE")
        XCTAssertEqual(transport.lastDataRequest?.url?.absoluteString, "http://127.0.0.1:11434/api/delete")
        let bodyString = String(data: transport.lastDataRequest?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("llama3.2:3b"))

        // Remote unreachable Ollama must return .remoteUnreachable (never try local install)
        transport.shouldFailData = true
        let remoteStatus = await manager.probeStatus(baseURL: "https://ollama.example.com")
        if case .remoteUnreachable = remoteStatus {
            // expected
        } else {
            XCTFail("Expected .remoteUnreachable for remote host, got \(remoteStatus)")
        }
    }

    func testNewOllamaProfileStartsWithoutFakeHardcodedModels() {
        let fresh = AIProviderProfile(kind: .ollama)
        XCTAssertTrue(fresh.availableModels.isEmpty)
        XCTAssertEqual(fresh.modelID, "")

        // Presets and console URLs are valid HTTPS/loopback URLs
        XCTAssertNotNil(AIProviderKind.anthropic.apiKeyConsoleURL)
        XCTAssertNotNil(AIProviderKind.openAI.apiKeyConsoleURL)
        XCTAssertNotNil(AIProviderKind.gemini.apiKeyConsoleURL)
        XCTAssertNotNil(AIProviderKind.githubModels.apiKeyConsoleURL)
        XCTAssertEqual(OpenAICompatiblePreset.matchingPreset(for: "https://openrouter.ai/api/v1").id, "openrouter")
        XCTAssertEqual(OpenAICompatiblePreset.matchingPreset(for: "http://127.0.0.1:1234/v1").id, "lmstudio")
    }

    func testCopilotCLIDetectionIgnoresPlainGHWithoutExtension() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ceptra-cli-test-\(UUID().uuidString)")
        let binDir = tmp.appendingPathComponent("bin")
        let fakeHome = tmp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ghURL = binDir.appendingPathComponent("gh")
        try "#!/bin/sh\necho gh\n".write(to: ghURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ghURL.path)

        let envNoExt = ["PATH": binDir.path, "HOME": fakeHome.path, "XDG_DATA_HOME": fakeHome.appendingPathComponent(".local/share").path]
        XCTAssertFalse(AICLIProviderClient.hasGHCopilotExtension(environment: envNoExt))

        // Once gh-copilot extension directory exists, hasGHCopilotExtension returns true
        let extDir = fakeHome.appendingPathComponent(".local/share/gh/extensions/gh-copilot")
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        XCTAssertTrue(AICLIProviderClient.hasGHCopilotExtension(environment: envNoExt))
    }
}
