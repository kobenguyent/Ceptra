import Foundation

public struct AIHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func headerValue(forName name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

public struct AIHTTPStreamResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let lines: AsyncThrowingStream<String, Error>

    public init(statusCode: Int, headers: [String: String] = [:], lines: AsyncThrowingStream<String, Error>) {
        self.statusCode = statusCode
        self.headers = headers
        self.lines = lines
    }

    public func headerValue(forName name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

public protocol AIHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> AIHTTPResponse
    func streamLines(for request: URLRequest) async throws -> AIHTTPStreamResponse
}

/// Production `URLSession` transport enforcing same-origin redirects (T-05) and bounded timeouts (T-07).
public final class URLSessionAIHTTPTransport: AIHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let redirectDelegate: AISameOriginRedirectDelegate

    public init(connectTimeoutSeconds: TimeInterval = 30, idleTimeoutSeconds: TimeInterval = 90) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = connectTimeoutSeconds
        config.timeoutIntervalForResource = max(idleTimeoutSeconds, 300)
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let delegate = AISameOriginRedirectDelegate()
        self.redirectDelegate = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    public func data(for request: URLRequest) async throws -> AIHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.networkFailure("Invalid non-HTTP response from provider.")
        }
        return AIHTTPResponse(
            statusCode: http.statusCode,
            headers: Self.normalizeHeaders(http),
            body: data
        )
    }

    public func streamLines(for request: URLRequest) async throws -> AIHTTPStreamResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.networkFailure("Invalid non-HTTP streaming response from provider.")
        }

        let headers = Self.normalizeHeaders(http)
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        return AIHTTPStreamResponse(statusCode: http.statusCode, headers: headers, lines: stream)
    }

    private static func normalizeHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            result[String(describing: key)] = String(describing: value)
        }
        return result
    }
}

/// Unified HTTP streaming & model-discovery client for:
/// Ollama, Anthropic (Claude), OpenAI, Google Gemini, GitHub Models, and Custom OpenAI-Compatible.
public final class AIHTTPProviderClient: Sendable {
    public static let maxResponseBytes = 512 * 1024 // 512 KB safety cap (T-07)

    private let transport: AIHTTPTransport

    public init(transport: AIHTTPTransport = URLSessionAIHTTPTransport()) {
        self.transport = transport
    }

    // MARK: - Request Builders (Public/Testable)

    public func buildListModelsRequest(
        profile: AIProviderProfile,
        apiKey: String?
    ) throws -> URLRequest {
        let baseURL = try AIURLValidator.validateBaseURL(
            profile.baseURL,
            allowInsecureLocalHTTP: profile.allowInsecureLocalHTTP
        )
        let cleanKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if profile.kind.requiresAPIKey && cleanKey.isEmpty {
            throw AIProviderError.missingAPIKey(providerName: profile.name)
        }

        let endpoint: URL
        switch profile.kind {
        case .ollama:
            endpoint = baseURL.appendingPathComponent("api/tags")
        case .anthropic:
            endpoint = baseURL.appendingPathComponent("v1/models")
        case .openAI, .openAICompatible:
            endpoint = baseURL.appendingPathComponent("models")
        case .gemini:
            endpoint = baseURL.appendingPathComponent("models")
        case .githubModels:
            endpoint = baseURL.appendingPathComponent("catalog/models")
        case .claudeCLI, .copilotCLI, .codexCLI:
            throw AIProviderError.invalidBaseURL("CLI providers do not use HTTP requests.")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthHeaders(to: &request, kind: profile.kind, apiKey: cleanKey)
        return request
    }

    public func buildChatRequest(
        request chatRequest: AIChatRequest,
        profile: AIProviderProfile,
        apiKey: String?
    ) throws -> URLRequest {
        let baseURL = try AIURLValidator.validateBaseURL(
            profile.baseURL,
            allowInsecureLocalHTTP: profile.allowInsecureLocalHTTP
        )
        let modelID = profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            throw AIProviderError.missingModelID
        }
        let cleanKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if profile.kind.requiresAPIKey && cleanKey.isEmpty {
            throw AIProviderError.missingAPIKey(providerName: profile.name)
        }

        let endpoint: URL
        let payload: [String: Any]

        switch profile.kind {
        case .ollama:
            endpoint = baseURL.appendingPathComponent("api/chat")
            var messagesPayload: [[String: Any]] = []
            if !chatRequest.systemPrompt.isEmpty {
                messagesPayload.append(["role": "system", "content": chatRequest.systemPrompt])
            }
            for msg in chatRequest.messages where msg.role != .system {
                var item: [String: Any] = ["role": msg.role.rawValue, "content": msg.content]
                if !msg.images.isEmpty {
                    // Ollama native vision format: raw base64 strings (without data: URI prefix)
                    item["images"] = msg.images.map(\.base64Data)
                }
                messagesPayload.append(item)
            }
            payload = [
                "model": modelID,
                "messages": messagesPayload,
                "stream": true,
                "options": [
                    "temperature": chatRequest.temperature,
                    "num_predict": chatRequest.maxTokens
                ]
            ]

        case .anthropic:
            endpoint = baseURL.appendingPathComponent("v1/messages")
            let messagesPayload: [[String: Any]] = chatRequest.messages
                .filter { $0.role != .system }
                .map { msg in
                    if msg.images.isEmpty {
                        return ["role": msg.role.rawValue, "content": msg.content]
                    }
                    var blocks: [[String: Any]] = msg.images.map { img in
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": img.mimeType,
                                "data": img.base64Data
                            ]
                        ]
                    }
                    blocks.append(["type": "text", "text": msg.content])
                    return ["role": msg.role.rawValue, "content": blocks]
                }
            var body: [String: Any] = [
                "model": modelID,
                "max_tokens": chatRequest.maxTokens,
                "temperature": chatRequest.temperature,
                "stream": true,
                "messages": messagesPayload
            ]
            if !chatRequest.systemPrompt.isEmpty {
                body["system"] = chatRequest.systemPrompt
            }
            payload = body

        case .gemini:
            // Security invariant T-01: NEVER embed API key in query parameters; use x-goog-api-key header.
            let escapedModel = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID
            let modelPath = escapedModel.hasPrefix("models/") ? escapedModel : "models/\(escapedModel)"
            var comps = URLComponents(url: baseURL.appendingPathComponent("\(modelPath):streamGenerateContent"), resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            guard let geminiURL = comps?.url else {
                throw AIProviderError.invalidBaseURL("Failed to construct Gemini endpoint URL.")
            }
            endpoint = geminiURL

            let contents: [[String: Any]] = chatRequest.messages
                .filter { $0.role != .system }
                .map { msg in
                    var parts: [[String: Any]] = msg.images.map { img in
                        [
                            "inline_data": [
                                "mime_type": img.mimeType,
                                "data": img.base64Data
                            ]
                        ]
                    }
                    parts.append(["text": msg.content])
                    return [
                        "role": msg.role == .assistant ? "model" : "user",
                        "parts": parts
                    ]
                }
            var body: [String: Any] = [
                "contents": contents,
                "generationConfig": [
                    "temperature": chatRequest.temperature,
                    "maxOutputTokens": chatRequest.maxTokens
                ]
            ]
            if !chatRequest.systemPrompt.isEmpty {
                body["systemInstruction"] = [
                    "parts": [["text": chatRequest.systemPrompt]]
                ]
            }
            payload = body

        case .openAI, .githubModels, .openAICompatible:
            endpoint = baseURL.appendingPathComponent("chat/completions")
            var messagesPayload: [[String: Any]] = []
            if !chatRequest.systemPrompt.isEmpty {
                messagesPayload.append(["role": "system", "content": chatRequest.systemPrompt])
            }
            for msg in chatRequest.messages where msg.role != .system {
                if msg.images.isEmpty {
                    messagesPayload.append(["role": msg.role.rawValue, "content": msg.content])
                } else {
                    var parts: [[String: Any]] = [["type": "text", "text": msg.content]]
                    for img in msg.images {
                        parts.append([
                            "type": "image_url",
                            "image_url": [
                                "url": "data:\(img.mimeType);base64,\(img.base64Data)"
                            ]
                        ])
                    }
                    messagesPayload.append(["role": msg.role.rawValue, "content": parts])
                }
            }
            payload = [
                "model": modelID,
                "messages": messagesPayload,
                "temperature": chatRequest.temperature,
                "max_tokens": chatRequest.maxTokens,
                "stream": true
            ]

        case .claudeCLI, .copilotCLI, .codexCLI:
            throw AIProviderError.invalidBaseURL("CLI providers do not use HTTP requests.")
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        applyAuthHeaders(to: &urlRequest, kind: profile.kind, apiKey: cleanKey)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        return urlRequest
    }

    // MARK: - Model Discovery & Connection Test

    public func listModels(
        profile: AIProviderProfile,
        apiKey: String?
    ) async throws -> [AIModelDescriptor] {
        let req = try buildListModelsRequest(profile: profile, apiKey: apiKey)
        let response: AIHTTPResponse
        do {
            response = try await transport.data(for: req)
        } catch {
            throw mapNetworkError(error, profile: profile, apiKey: apiKey)
        }

        if response.statusCode == 401 || response.statusCode == 403 {
            throw mapHTTPError(statusCode: response.statusCode, headers: response.headers, body: response.body, apiKey: apiKey)
        }
        guard (200...299).contains(response.statusCode) else {
            // Some custom OpenAI-compatible gateways or GitHub Models accounts don't expose /models;
            // allow curated fallback on 404/405 for non-Ollama providers while surfacing auth/5xx errors.
            if (response.statusCode == 404 || response.statusCode == 405), profile.kind != .ollama {
                return profile.kind.curatedModels.map { AIModelDescriptor(id: $0) }
            }
            throw mapHTTPError(statusCode: response.statusCode, headers: response.headers, body: response.body, apiKey: apiKey)
        }

        let parsed = parseModelsList(data: response.body, kind: profile.kind)
        if !parsed.isEmpty {
            return parsed
        }
        return profile.kind.curatedModels.map { AIModelDescriptor(id: $0) }
    }

    public func testConnection(
        profile: AIProviderProfile,
        apiKey: String?
    ) async throws -> AIConnectionTestResult {
        let start = Date()
        let models = try await listModels(profile: profile, apiKey: apiKey)
        let latencyMs = max(1, Int(Date().timeIntervalSince(start) * 1000))
        let summary: String
        if profile.kind == .ollama {
            summary = models.isEmpty
                ? "Connected to Ollama (\(latencyMs) ms), but no models pulled yet. Run `ollama pull qwen2.5-coder:7b`."
                : "Connected to Ollama · \(models.count) local model\(models.count == 1 ? "" : "s") ready (\(latencyMs) ms)"
        } else {
            summary = "Connected to \(profile.kind.displayName) · \(models.count) model\(models.count == 1 ? "" : "s") available (\(latencyMs) ms)"
        }
        return AIConnectionTestResult(ok: true, latencyMs: latencyMs, summary: summary, discoveredModels: models)
    }

    // MARK: - Streaming Chat

    public func streamChat(
        request chatRequest: AIChatRequest,
        profile: AIProviderProfile,
        apiKey: String?
    ) -> AsyncThrowingStream<AIStreamDelta, Error> {
        let transport = self.transport
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try self.buildChatRequest(request: chatRequest, profile: profile, apiKey: apiKey)
                    let streamResponse: AIHTTPStreamResponse
                    do {
                        streamResponse = try await transport.streamLines(for: urlRequest)
                    } catch {
                        throw self.mapNetworkError(error, profile: profile, apiKey: apiKey)
                    }

                    guard (200...299).contains(streamResponse.statusCode) else {
                        var errorLines: [String] = []
                        var capturedBytes = 0
                        for try await line in streamResponse.lines {
                            errorLines.append(line)
                            capturedBytes += line.utf8.count
                            if capturedBytes > 16_384 { break }
                        }
                        let bodyData = Data(errorLines.joined(separator: "\n").utf8)
                        throw self.mapHTTPError(
                            statusCode: streamResponse.statusCode,
                            headers: streamResponse.headers,
                            body: bodyData,
                            apiKey: apiKey
                        )
                    }

                    var parser = Self.makeParser(for: profile.kind)
                    var emittedBytes = 0

                    for try await line in streamResponse.lines {
                        if Task.isCancelled {
                            continuation.finish(throwing: AIProviderError.cancelled)
                            return
                        }
                        let deltas = try parser.consume(line: line)
                        for delta in deltas {
                            if case .text(let chunk) = delta {
                                emittedBytes += chunk.utf8.count
                                if emittedBytes > Self.maxResponseBytes {
                                    continuation.finish(throwing: AIProviderError.responseTooLarge(limitBytes: Self.maxResponseBytes))
                                    return
                                }
                            }
                            continuation.yield(delta)
                        }
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AIProviderError.cancelled)
                } catch let err as AIProviderError {
                    continuation.finish(throwing: err)
                } catch {
                    continuation.finish(throwing: self.mapNetworkError(error, profile: profile, apiKey: apiKey))
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Helpers

    private func applyAuthHeaders(to request: inout URLRequest, kind: AIProviderKind, apiKey: String) {
        switch kind {
        case .anthropic:
            if !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            if !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            }
        case .openAI, .githubModels, .openAICompatible, .ollama:
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        case .claudeCLI, .copilotCLI, .codexCLI:
            break
        }
    }

    private static func makeParser(for kind: AIProviderKind) -> any AIStreamLineParser {
        switch kind {
        case .ollama:
            return OllamaNDJSONLineParser()
        case .anthropic:
            return AnthropicSSELineParser()
        case .gemini:
            return GeminiSSELineParser()
        case .openAI, .githubModels, .openAICompatible:
            return OpenAISSELineParser()
        case .claudeCLI, .copilotCLI, .codexCLI:
            return ClaudeCLIStreamJSONLineParser()
        }
    }

    private func parseModelsList(data: Data, kind: AIProviderKind) -> [AIModelDescriptor] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }

        switch kind {
        case .ollama:
            guard let dict = root as? [String: Any],
                  let models = dict["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { item -> AIModelDescriptor? in
                guard let name = item["name"] as? String, !name.isEmpty else { return nil }
                var hint: String? = nil
                if let details = item["details"] as? [String: Any],
                   let paramSize = details["parameter_size"] as? String {
                    hint = paramSize
                }
                return AIModelDescriptor(id: name, displayName: name, contextHint: hint)
            }

        case .gemini:
            guard let dict = root as? [String: Any],
                  let models = dict["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { item -> AIModelDescriptor? in
                guard let rawName = item["name"] as? String else { return nil }
                if let methods = item["supportedGenerationMethods"] as? [String],
                   !methods.contains("generateContent") {
                    return nil
                }
                let id = rawName.hasPrefix("models/") ? String(rawName.dropFirst(7)) : rawName
                let display = (item["displayName"] as? String) ?? id
                return AIModelDescriptor(id: id, displayName: display)
            }

        case .githubModels:
            if let array = root as? [[String: Any]] {
                return array.compactMap { item -> AIModelDescriptor? in
                    guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                    let name = (item["name"] as? String) ?? id
                    return AIModelDescriptor(id: id, displayName: name)
                }
            }
            if let dict = root as? [String: Any], let dataArr = dict["data"] as? [[String: Any]] {
                return dataArr.compactMap { item in
                    guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                    return AIModelDescriptor(id: id)
                }
            }
            return []

        case .anthropic, .openAI, .openAICompatible:
            guard let dict = root as? [String: Any],
                  let items = dict["data"] as? [[String: Any]] else { return [] }
            let descriptors = items.compactMap { item -> AIModelDescriptor? in
                guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                let display = (item["display_name"] as? String) ?? id
                return AIModelDescriptor(id: id, displayName: display)
            }
            if kind == .openAI {
                let preferred = descriptors.filter {
                    let l = $0.id.lowercased()
                    return l.hasPrefix("gpt-") || l.hasPrefix("o1") || l.hasPrefix("o3") || l.hasPrefix("o4") || l.hasPrefix("chatgpt")
                }
                return preferred.isEmpty ? descriptors : preferred.sorted { $0.id > $1.id }
            }
            return descriptors

        case .claudeCLI, .copilotCLI, .codexCLI:
            return []
        }
    }

    private func mapHTTPError(
        statusCode: Int,
        headers: [String: String],
        body: Data,
        apiKey: String?
    ) -> AIProviderError {
        let rawBody = String(data: body, encoding: .utf8) ?? ""
        var extracted = rawBody
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
                extracted = msg
            } else if let errStr = json["error"] as? String {
                extracted = errStr
            } else if let msg = json["message"] as? String {
                extracted = msg
            }
        }
        let trimmed = String(extracted.trimmingCharacters(in: .whitespacesAndNewlines).prefix(320))
        let redacted = AISecretRedactor.redact(
            trimmed,
            explicitSecrets: apiKey.map { [$0] } ?? []
        ).text

        if statusCode == 429 {
            let retryAfter = headers.first(where: { $0.key.lowercased() == "retry-after" })
                .flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) }
            return .rateLimited(retryAfterSeconds: retryAfter, message: redacted)
        }
        return .httpError(statusCode: statusCode, message: redacted)
    }

    private func mapNetworkError(_ error: Error, profile: AIProviderProfile, apiKey: String?) -> AIProviderError {
        if let aiErr = error as? AIProviderError { return aiErr }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain {
            if nsErr.code == NSURLErrorCancelled {
                return .cancelled
            }
            if nsErr.code == NSURLErrorCannotConnectToHost || nsErr.code == NSURLErrorNetworkConnectionLost {
                if profile.kind == .ollama {
                    return .networkFailure("Could not connect to Ollama at \(profile.baseURL). Make sure Ollama is running (`ollama serve`).")
                }
                return .networkFailure("Could not reach \(profile.baseURL). Check your network connection and Base URL.")
            }
            if nsErr.code == NSURLErrorTimedOut {
                return .networkFailure("Request to \(profile.name) timed out. Try again or check if the model is still loading.")
            }
        }
        let redacted = AISecretRedactor.redact(
            error.localizedDescription,
            explicitSecrets: apiKey.map { [$0] } ?? []
        ).text
        return .networkFailure(redacted)
    }
}
