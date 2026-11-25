import Foundation

public struct APIRunOptions: Equatable, Sendable {
    public var timeoutSeconds: TimeInterval
    public var followRedirects: Bool
    public var delayBetweenRequestsMs: Int
    public var stopOnError: Bool

    public init(
        timeoutSeconds: TimeInterval = 30,
        followRedirects: Bool = true,
        delayBetweenRequestsMs: Int = 0,
        stopOnError: Bool = false
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.followRedirects = followRedirects
        self.delayBetweenRequestsMs = delayBetweenRequestsMs
        self.stopOnError = stopOnError
    }
}

/// Zero-dependency native Swift HTTP client & collection runner built on `URLSession`
/// with real DNS/TCP/TLS/TTFB/Download transaction timing metrics, assertion evaluation,
/// and variable chaining between requests.
public enum APIRequestRunner {
    private static let maxBodyDisplayBytes = 2 * 1024 * 1024

    public static func execute(
        request: APIRequestItem,
        effectiveAuth: APIAuthConfig,
        variables: [String: String],
        folderPath: String = "",
        options: APIRunOptions = APIRunOptions()
    ) async -> APIExecutionResult {
        let startedAt = Date()

        // 1. Resolve URL & enabled query params
        let resolvedBase = APIVariableResolver.resolve(request.url.trimmingCharacters(in: .whitespacesAndNewlines), variables: variables)
        var resolvedParams: [APIKeyValueItem] = request.queryParams
            .filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { item in
                APIKeyValueItem(
                    key: APIVariableResolver.resolve(item.key, variables: variables),
                    value: APIVariableResolver.resolve(item.value, variables: variables)
                )
            }

        // Apply API key in query if configured
        if effectiveAuth.kind == .apiKey && effectiveAuth.apiKeyIn == .query {
            let k = APIVariableResolver.resolve(effectiveAuth.apiKeyName, variables: variables).trimmingCharacters(in: .whitespaces)
            let v = APIVariableResolver.resolve(effectiveAuth.apiKeyValue, variables: variables)
            if !k.isEmpty {
                resolvedParams.append(APIKeyValueItem(key: k, value: v))
            }
        }

        let resolvedURLString = buildFinalURLString(base: resolvedBase, queryParams: resolvedParams)
        guard let url = URL(string: resolvedURLString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return APIExecutionResult(
                requestID: request.id,
                requestName: request.name,
                folderPath: folderPath,
                method: request.method,
                resolvedURL: resolvedURLString,
                errorMessage: "Invalid HTTP/HTTPS URL: \"\(resolvedURLString)\". Check your URL or active environment variables.",
                startedAt: startedAt,
                finishedAt: Date()
            )
        }

        // 2. Build headers + Auth
        var headers: [String: String] = [:]
        for h in request.headers where h.isEnabled {
            let k = APIVariableResolver.resolve(h.key, variables: variables).trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty else { continue }
            headers[k] = APIVariableResolver.resolve(h.value, variables: variables)
        }
        switch effectiveAuth.kind {
        case .bearer:
            let token = APIVariableResolver.resolve(effectiveAuth.bearerToken, variables: variables)
            if !token.isEmpty {
                headers["Authorization"] = "Bearer \(token)"
            }
        case .basic:
            let user = APIVariableResolver.resolve(effectiveAuth.basicUsername, variables: variables)
            let pass = APIVariableResolver.resolve(effectiveAuth.basicPassword, variables: variables)
            let encoded = Data("\(user):\(pass)".utf8).base64EncodedString()
            headers["Authorization"] = "Basic \(encoded)"
        case .apiKey where effectiveAuth.apiKeyIn == .header:
            let name = APIVariableResolver.resolve(effectiveAuth.apiKeyName, variables: variables).trimmingCharacters(in: .whitespaces)
            let val = APIVariableResolver.resolve(effectiveAuth.apiKeyValue, variables: variables)
            if !name.isEmpty {
                headers[name] = val
            }
        default:
            break
        }

        // 3. Build HTTP body
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: options.timeoutSeconds)
        urlRequest.httpMethod = request.method.rawValue

        var sentBodyPreview: String? = nil
        if request.method != .get && request.method != .head {
            switch request.body.mode {
            case .none:
                break
            case .json:
                let resolved = APIVariableResolver.resolve(request.body.rawText, variables: variables)
                urlRequest.httpBody = Data(resolved.utf8)
                sentBodyPreview = resolved
                if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
                    headers["Content-Type"] = "application/json"
                }
            case .raw:
                let resolved = APIVariableResolver.resolve(request.body.rawText, variables: variables)
                urlRequest.httpBody = Data(resolved.utf8)
                sentBodyPreview = resolved
                if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
                    headers["Content-Type"] = request.body.rawContentType
                }
            case .formURLEncoded:
                let pairs = request.body.formItems
                    .filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { item -> String in
                        let k = formEncode(APIVariableResolver.resolve(item.key, variables: variables))
                        let v = formEncode(APIVariableResolver.resolve(item.value, variables: variables))
                        return "\(k)=\(v)"
                    }
                let encoded = pairs.joined(separator: "&")
                urlRequest.httpBody = Data(encoded.utf8)
                sentBodyPreview = encoded
                if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
                    headers["Content-Type"] = "application/x-www-form-urlencoded"
                }
            case .multipartFormData:
                let boundary = "CeptraBoundary-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"
                var data = Data()
                var previewParts: [String] = []
                for item in request.body.formItems where item.isEnabled && !item.key.trimmingCharacters(in: .whitespaces).isEmpty {
                    let k = APIVariableResolver.resolve(item.key, variables: variables)
                    data.append(Data("--\(boundary)\r\n".utf8))
                    if let filePath = item.filePath, !filePath.isEmpty {
                        let resolvedPath = APIVariableResolver.resolve(filePath, variables: variables)
                        let fileURL = URL(fileURLWithPath: resolvedPath)
                        let fileName = fileURL.lastPathComponent
                        let fileBytes = (try? Data(contentsOf: fileURL)) ?? Data()
                        data.append(Data("Content-Disposition: form-data; name=\"\(k)\"; filename=\"\(fileName)\"\r\n".utf8))
                        data.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
                        data.append(fileBytes)
                        data.append(Data("\r\n".utf8))
                        previewParts.append("\(k)=@\(fileName) (\(fileBytes.count) bytes)")
                    } else {
                        let v = APIVariableResolver.resolve(item.value, variables: variables)
                        data.append(Data("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n".utf8))
                        data.append(Data("\(v)\r\n".utf8))
                        previewParts.append("\(k)=\(v)")
                    }
                }
                data.append(Data("--\(boundary)--\r\n".utf8))
                urlRequest.httpBody = data
                sentBodyPreview = previewParts.joined(separator: "\n")
                headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
            case .graphql:
                let query = APIVariableResolver.resolve(request.body.graphqlQuery, variables: variables)
                let varsRaw = APIVariableResolver.resolve(request.body.graphqlVariables, variables: variables).trimmingCharacters(in: .whitespacesAndNewlines)
                var gqlObj: [String: Any] = ["query": query]
                if !varsRaw.isEmpty, let vd = varsRaw.data(using: .utf8),
                   let parsedVars = try? JSONSerialization.jsonObject(with: vd) {
                    gqlObj["variables"] = parsedVars
                }
                if let bodyData = try? JSONSerialization.data(withJSONObject: gqlObj, options: [.sortedKeys]) {
                    urlRequest.httpBody = bodyData
                    sentBodyPreview = String(data: bodyData, encoding: .utf8)
                }
                if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
                    headers["Content-Type"] = "application/json"
                }
            }
        }

        for (k, v) in headers {
            urlRequest.setValue(v, forHTTPHeaderField: k)
        }

        // 4. Execute via ephemeral URLSession capturing transaction timing metrics
        let collector = TimingSessionDelegate(followRedirects: options.followRedirects)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = options.timeoutSeconds
        config.timeoutIntervalForResource = max(options.timeoutSeconds * 2, 60)
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: collector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let monoStart = DispatchTime.now().uptimeNanoseconds
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let finishedAt = Date()
            let elapsedMs = max(0, Int((DispatchTime.now().uptimeNanoseconds - monoStart) / 1_000_000))

            guard let http = response as? HTTPURLResponse else {
                return APIExecutionResult(
                    requestID: request.id,
                    requestName: request.name,
                    folderPath: folderPath,
                    method: request.method,
                    resolvedURL: resolvedURLString,
                    requestHeaders: headers,
                    requestBody: sentBodyPreview,
                    durationMs: elapsedMs,
                    errorMessage: "Received non-HTTP response.",
                    startedAt: startedAt,
                    finishedAt: finishedAt
                )
            }

            let responseHeaders: [APIKeyValueItem] = http.allHeaderFields
                .compactMap { k, v -> APIKeyValueItem? in
                    guard let ks = k as? String else { return nil }
                    return APIKeyValueItem(key: ks, value: String(describing: v))
                }
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }

            let cookies = parseCookies(from: http, url: url)
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let isBinary = isLikelyBinary(contentType: contentType, data: data)

            let bodyText: String
            let prettyText: String
            if isBinary {
                bodyText = "[Binary payload: \(data.count) bytes, Content-Type: \(contentType.isEmpty ? "application/octet-stream" : contentType)]"
                prettyText = bodyText
            } else {
                let slice = data.count > maxBodyDisplayBytes ? data.prefix(maxBodyDisplayBytes) : data
                let decoded = String(data: slice, encoding: .utf8) ?? String(decoding: slice, as: UTF8.self)
                let suffix = data.count > maxBodyDisplayBytes ? "\n\n/* Truncated at 2 MB (\(data.count) bytes total) */" : ""
                bodyText = decoded + suffix
                prettyText = prettyPrintIfJSON(decoded) + suffix
            }

            let timings = collector.buildTimings(fallbackTotalMs: elapsedMs)
            let assertionResults = evaluateAssertions(
                rules: request.assertions,
                statusCode: http.statusCode,
                durationMs: elapsedMs,
                headers: responseHeaders,
                body: bodyText,
                variables: variables
            )
            let extracted = extractVariables(
                extractors: request.extractors,
                headers: responseHeaders,
                body: bodyText
            )

            return APIExecutionResult(
                requestID: request.id,
                requestName: request.name,
                folderPath: folderPath,
                method: request.method,
                resolvedURL: http.url?.absoluteString ?? resolvedURLString,
                requestHeaders: headers,
                requestBody: sentBodyPreview,
                statusCode: http.statusCode,
                statusText: HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized,
                responseHeaders: responseHeaders,
                cookies: cookies,
                responseBody: bodyText,
                prettyResponseBody: prettyText,
                responseBodyByteCount: data.count,
                isBinaryResponse: isBinary,
                durationMs: elapsedMs,
                timings: timings,
                assertionResults: assertionResults,
                extractedVariables: extracted,
                startedAt: startedAt,
                finishedAt: finishedAt
            )
        } catch {
            let finishedAt = Date()
            let elapsedMs = max(0, Int((DispatchTime.now().uptimeNanoseconds - monoStart) / 1_000_000))
            return APIExecutionResult(
                requestID: request.id,
                requestName: request.name,
                folderPath: folderPath,
                method: request.method,
                resolvedURL: resolvedURLString,
                requestHeaders: headers,
                requestBody: sentBodyPreview,
                durationMs: elapsedMs,
                errorMessage: error.localizedDescription,
                startedAt: startedAt,
                finishedAt: finishedAt
            )
        }
    }

    /// Runs every request in a collection (or a specific folder) sequentially, propagating extracted
    /// variables from each response into subsequent requests.
    public static func runCollection(
        _ collection: APICollection,
        folderID: UUID? = nil,
        environment: APIEnvironment?,
        options: APIRunOptions = APIRunOptions(),
        onProgress: (@Sendable (Int, Int, APIExecutionResult) -> Void)? = nil
    ) async -> (summary: APICollectionRunSummary, environmentUpdates: [String: String], collectionUpdates: [String: String]) {
        let startedAt = Date()
        let entries: [(request: APIRequestItem, effectiveAuth: APIAuthConfig, folderPath: String)]
        if let folderID, let folder = collection.folder(withID: folderID) {
            let baseAuth = collection.auth.kind == .inherit ? APIAuthConfig.none : collection.auth
            entries = folder.flattenedRequests(inheritedAuth: baseAuth)
        } else {
            entries = collection.flattenedRequests()
        }

        var runtimeVars = APIVariableResolver.mergedVariables(collection: collection, environment: environment)
        var envUpdates: [String: String] = [:]
        var colUpdates: [String: String] = [:]
        var results: [APIExecutionResult] = []
        let total = entries.count

        for (idx, entry) in entries.enumerated() {
            if Task.isCancelled { break }
            let result = await execute(
                request: entry.request,
                effectiveAuth: entry.effectiveAuth,
                variables: runtimeVars,
                folderPath: entry.folderPath,
                options: options
            )
            results.append(result)

            // Propagate extracted variables for subsequent requests
            for extractor in entry.request.extractors where extractor.isEnabled && !extractor.targetVariableName.isEmpty {
                if let val = result.extractedVariables[extractor.targetVariableName] {
                    runtimeVars[extractor.targetVariableName] = val
                    switch extractor.scope {
                    case .environment: envUpdates[extractor.targetVariableName] = val
                    case .collection: colUpdates[extractor.targetVariableName] = val
                    }
                }
            }

            onProgress?(idx + 1, total, result)

            if options.stopOnError && !result.isSuccess {
                break
            }
            if options.delayBetweenRequestsMs > 0 && idx + 1 < total {
                try? await Task.sleep(nanoseconds: UInt64(options.delayBetweenRequestsMs) * 1_000_000)
            }
        }

        let summary = APICollectionRunSummary(
            collectionID: collection.id,
            collectionName: folderID.flatMap { collection.folder(withID: $0)?.name }.map { "\(collection.name) / \($0)" } ?? collection.name,
            environmentName: environment?.name,
            startedAt: startedAt,
            finishedAt: Date(),
            results: results
        )
        return (summary, envUpdates, colUpdates)
    }

    // MARK: - Assertions & Extractors

    public static func evaluateAssertions(
        rules: [APIAssertionRule],
        statusCode: Int,
        durationMs: Int,
        headers: [APIKeyValueItem],
        body: String,
        variables: [String: String]
    ) -> [APIAssertionResult] {
        rules.filter(\.isEnabled).map { rule in
            let expected = APIVariableResolver.resolve(rule.expectedValue, variables: variables)
            let property = APIVariableResolver.resolve(rule.property, variables: variables)
            switch rule.target {
            case .statusCode:
                let actual = String(statusCode)
                let passed = compare(actual: actual, expected: expected, op: rule.op, numericActual: Double(statusCode))
                return APIAssertionResult(
                    title: rule.displayTitle,
                    passed: passed,
                    expected: expected,
                    actual: actual,
                    message: passed ? nil : "Expected status \(rule.op.displayName) \(expected), got \(actual)"
                )

            case .responseTimeMs:
                let actual = "\(durationMs)ms"
                let passed = compare(actual: String(durationMs), expected: expected, op: rule.op, numericActual: Double(durationMs))
                return APIAssertionResult(
                    title: rule.displayTitle,
                    passed: passed,
                    expected: "\(expected)ms",
                    actual: actual,
                    message: passed ? nil : "Expected response time \(rule.op.displayName) \(expected)ms, got \(durationMs)ms"
                )

            case .bodyContains:
                let passed = compare(actual: body, expected: expected, op: rule.op, numericActual: nil)
                return APIAssertionResult(
                    title: rule.displayTitle,
                    passed: passed,
                    expected: expected,
                    actual: body.count > 140 ? String(body.prefix(140)) + "…" : body,
                    message: passed ? nil : "Body did not match condition \(rule.op.displayName) \"\(expected)\""
                )

            case .header:
                let matched = headers.first(where: { $0.key.caseInsensitiveCompare(property) == .orderedSame })?.value
                if rule.op == .exists {
                    let passed = matched != nil
                    return APIAssertionResult(
                        title: rule.displayTitle,
                        passed: passed,
                        expected: "Header \"\(property)\" present",
                        actual: matched ?? "(missing)",
                        message: passed ? nil : "Header \"\(property)\" not found"
                    )
                }
                let actual = matched ?? ""
                let passed = matched != nil && compare(actual: actual, expected: expected, op: rule.op, numericActual: Double(actual))
                return APIAssertionResult(
                    title: rule.displayTitle,
                    passed: passed,
                    expected: expected,
                    actual: matched ?? "(missing)",
                    message: passed ? nil : "Header \"\(property)\" was \"\(matched ?? "missing")\", expected \(rule.op.displayName) \"\(expected)\""
                )

            case .jsonPath:
                let evaluated = APIVariableResolver.evaluateJSONPath(property, inJSONString: body)
                if rule.op == .exists {
                    let passed = evaluated != nil
                    return APIAssertionResult(
                        title: rule.displayTitle,
                        passed: passed,
                        expected: "\(property) exists",
                        actual: evaluated ?? "(not found)",
                        message: passed ? nil : "JSONPath \"\(property)\" did not resolve in response body"
                    )
                }
                guard let evaluated else {
                    return APIAssertionResult(
                        title: rule.displayTitle,
                        passed: false,
                        expected: expected,
                        actual: "(not found)",
                        message: "JSONPath \"\(property)\" did not resolve in response body"
                    )
                }
                let passed = compare(actual: evaluated, expected: expected, op: rule.op, numericActual: Double(evaluated))
                return APIAssertionResult(
                    title: rule.displayTitle,
                    passed: passed,
                    expected: expected,
                    actual: evaluated,
                    message: passed ? nil : "JSONPath \(property) was \"\(evaluated)\", expected \(rule.op.displayName) \"\(expected)\""
                )
            }
        }
    }

    public static func extractVariables(
        extractors: [APIVariableExtractor],
        headers: [APIKeyValueItem],
        body: String
    ) -> [String: String] {
        var extracted: [String: String] = [:]
        for ext in extractors where ext.isEnabled {
            let varName = ext.targetVariableName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !varName.isEmpty else { continue }
            switch ext.source {
            case .jsonPath:
                if let val = APIVariableResolver.evaluateJSONPath(ext.expression, inJSONString: body) {
                    extracted[varName] = val
                }
            case .header:
                if let val = headers.first(where: { $0.key.caseInsensitiveCompare(ext.expression) == .orderedSame })?.value {
                    extracted[varName] = val
                }
            case .regex:
                if let regex = try? NSRegularExpression(pattern: ext.expression) {
                    let ns = body as NSString
                    if let m = regex.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) {
                        let range = m.numberOfRanges >= 2 ? m.range(at: 1) : m.range(at: 0)
                        if range.location != NSNotFound {
                            extracted[varName] = ns.substring(with: range)
                        }
                    }
                }
            }
        }
        return extracted
    }

    private static func compare(actual: String, expected: String, op: APIAssertionRule.OperatorKind, numericActual: Double?) -> Bool {
        switch op {
        case .equals:
            return actual == expected
        case .notEquals:
            return actual != expected
        case .contains:
            return actual.localizedCaseInsensitiveContains(expected)
        case .lessThan:
            if let a = numericActual ?? Double(actual), let e = Double(expected) { return a < e }
            return false
        case .greaterThan:
            if let a = numericActual ?? Double(actual), let e = Double(expected) { return a > e }
            return false
        case .exists:
            return !actual.isEmpty
        case .matchesRegex:
            return (try? NSRegularExpression(pattern: expected))?.firstMatch(
                in: actual,
                range: NSRange(location: 0, length: (actual as NSString).length)
            ) != nil
        }
    }

    // MARK: - Formatting & URL Helpers

    private static func buildFinalURLString(base: String, queryParams: [APIKeyValueItem]) -> String {
        guard !queryParams.isEmpty else { return base }
        if var comps = URLComponents(string: base) {
            var existing = comps.queryItems ?? []
            for p in queryParams {
                existing.append(URLQueryItem(name: p.key, value: p.value))
            }
            comps.queryItems = existing
            if let composed = comps.string {
                return composed
            }
        }
        return APIFormatCodec.composeRawURL(baseURL: base, queryParams: queryParams)
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func parseCookies(from response: HTTPURLResponse, url: URL) -> [APICookieItem] {
        guard let fields = response.allHeaderFields as? [String: String] else { return [] }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        return cookies.map { c in
            var flags: [String] = []
            if c.isSecure { flags.append("Secure") }
            if c.isHTTPOnly { flags.append("HttpOnly") }
            if let sameSite = c.sameSitePolicy?.rawValue { flags.append("SameSite=\(sameSite)") }
            return APICookieItem(
                name: c.name,
                value: c.value,
                domain: c.domain,
                path: c.path,
                attributes: flags.joined(separator: "; ")
            )
        }
    }

    private static func isLikelyBinary(contentType: String, data: Data) -> Bool {
        if contentType.hasPrefix("image/") || contentType.hasPrefix("audio/") || contentType.hasPrefix("video/")
            || contentType.contains("pdf") || contentType.contains("zip") || contentType.contains("octet-stream") {
            return true
        }
        let sample = data.prefix(512)
        return sample.contains(0)
    }

    public static func prettyPrintIfJSON(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let str = String(data: pretty, encoding: .utf8) else {
            return raw
        }
        return str
    }

    private final class TimingSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let followRedirects: Bool
        private let lock = NSLock()
        private var lastMetrics: URLSessionTaskTransactionMetrics?

        init(followRedirects: Bool) {
            self.followRedirects = followRedirects
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(followRedirects ? request : nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            lock.lock()
            lastMetrics = metrics.transactionMetrics.last
            lock.unlock()
        }

        func buildTimings(fallbackTotalMs: Int) -> TimeTravelNetworkTimings {
            lock.lock()
            let m = lastMetrics
            lock.unlock()
            guard let m else {
                return TimeTravelNetworkTimings(totalMs: fallbackTotalMs)
            }
            func msBetween(_ start: Date?, _ end: Date?) -> Int? {
                guard let start, let end else { return nil }
                let diff = Int((end.timeIntervalSince(start) * 1000.0).rounded())
                return diff >= 0 ? diff : nil
            }
            let dns = msBetween(m.domainLookupStartDate, m.domainLookupEndDate)
            let connect = msBetween(m.connectStartDate, m.secureConnectionStartDate ?? m.connectEndDate)
            let tls = msBetween(m.secureConnectionStartDate, m.secureConnectionEndDate)
            let ttfb = msBetween(m.requestEndDate ?? m.requestStartDate, m.responseStartDate)
            let download = msBetween(m.responseStartDate, m.responseEndDate)
            let total = msBetween(m.fetchStartDate, m.responseEndDate) ?? fallbackTotalMs
            return TimeTravelNetworkTimings(
                dnsMs: dns,
                connectMs: connect,
                tlsMs: tls,
                ttfbMs: ttfb,
                downloadMs: download,
                totalMs: total
            )
        }
    }
}
