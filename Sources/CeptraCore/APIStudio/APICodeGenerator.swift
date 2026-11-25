import Foundation

public enum APICodeSnippetLanguage: String, CaseIterable, Identifiable, Sendable {
    case curl = "cURL"
    case codeceptJS = "CodeceptJS"
    case playwrightTS = "Playwright (TS)"
    case playwrightPython = "Playwright (Python)"

    public var id: String { rawValue }
}

/// Generates runnable cURL, CodeceptJS REST, Playwright TypeScript, and Playwright Python
/// snippets and full automated test files directly from API Studio requests & collections.
public enum APICodeGenerator {

    public static func snippet(
        for request: APIRequestItem,
        effectiveAuth: APIAuthConfig,
        variables: [String: String],
        language: APICodeSnippetLanguage
    ) -> String {
        switch language {
        case .curl:
            return generateCurl(request: request, effectiveAuth: effectiveAuth, variables: variables)
        case .codeceptJS:
            return generateCodeceptSnippet(request: request, effectiveAuth: effectiveAuth, variables: variables)
        case .playwrightTS:
            return generatePlaywrightTSSnippet(request: request, effectiveAuth: effectiveAuth, variables: variables)
        case .playwrightPython:
            return generatePlaywrightPythonSnippet(request: request, effectiveAuth: effectiveAuth, variables: variables)
        }
    }

    /// Generates a full runnable test file for an entire collection matching the active workspace framework.
    public static func generateTestFile(
        for collection: APICollection,
        environment: APIEnvironment?,
        framework: TestFrameworkKind
    ) -> (suggestedFileName: String, content: String) {
        let vars = APIVariableResolver.mergedVariables(collection: collection, environment: environment)
        let slug = slugify(collection.name)
        let entries = collection.flattenedRequests()

        switch framework {
        case .codeceptJS:
            var out: [String] = [
                "Feature('\(escapeSQ(collection.name)) @api');",
                ""
            ]
            for entry in entries {
                let title = entry.folderPath.isEmpty ? entry.request.name : "\(entry.folderPath) — \(entry.request.name)"
                out.append("Scenario('\(escapeSQ(title))', async ({ I }) => {")
                for line in generateCodeceptBodyLines(request: entry.request, effectiveAuth: entry.effectiveAuth, variables: vars) {
                    out.append("  \(line)")
                }
                out.append("});")
                out.append("")
            }
            return ("\(slug)_api_test.ts", out.joined(separator: "\n"))

        case .playwright:
            var out: [String] = [
                "import { test, expect } from '@playwright/test';",
                "",
                "test.describe('\(escapeSQ(collection.name)) @api', () => {"
            ]
            for entry in entries {
                let title = entry.folderPath.isEmpty ? entry.request.name : "\(entry.folderPath) — \(entry.request.name)"
                out.append("  test('\(escapeSQ(title))', async ({ request }) => {")
                for line in generatePlaywrightTSBodyLines(request: entry.request, effectiveAuth: entry.effectiveAuth, variables: vars) {
                    out.append("    \(line)")
                }
                out.append("  });")
                out.append("")
            }
            out.append("});")
            return ("\(slug).api.spec.ts", out.joined(separator: "\n") + "\n")

        case .playwrightPython:
            var out: [String] = [
                "import pytest",
                "from playwright.sync_api import APIRequestContext, expect",
                ""
            ]
            var usedNames: Set<String> = []
            for entry in entries {
                var fnName = "test_" + slugify(entry.request.name)
                if usedNames.contains(fnName) {
                    fnName += "_\(usedNames.count + 1)"
                }
                usedNames.insert(fnName)
                out.append("@pytest.mark.api")
                out.append("def \(fnName)(api_request_context: APIRequestContext):")
                for line in generatePlaywrightPythonBodyLines(request: entry.request, effectiveAuth: entry.effectiveAuth, variables: vars) {
                    out.append("    \(line)")
                }
                out.append("")
            }
            return ("test_\(slug)_api.py", out.joined(separator: "\n"))
        }
    }

    // MARK: - Per-Language Generators

    private static func resolvedContext(
        request: APIRequestItem,
        effectiveAuth: APIAuthConfig,
        variables: [String: String]
    ) -> (url: String, headers: [(String, String)], body: String?) {
        let base = APIVariableResolver.resolve(request.url, variables: variables)
        var params = request.queryParams.filter { $0.isEnabled && !$0.key.isEmpty }.map {
            APIKeyValueItem(key: APIVariableResolver.resolve($0.key, variables: variables), value: APIVariableResolver.resolve($0.value, variables: variables))
        }
        var headers: [(String, String)] = request.headers.filter { $0.isEnabled && !$0.key.isEmpty }.map {
            (APIVariableResolver.resolve($0.key, variables: variables), APIVariableResolver.resolve($0.value, variables: variables))
        }
        switch effectiveAuth.kind {
        case .bearer where !effectiveAuth.bearerToken.isEmpty:
            headers.append(("Authorization", "Bearer \(APIVariableResolver.resolve(effectiveAuth.bearerToken, variables: variables))"))
        case .basic:
            let u = APIVariableResolver.resolve(effectiveAuth.basicUsername, variables: variables)
            let p = APIVariableResolver.resolve(effectiveAuth.basicPassword, variables: variables)
            let b64 = Data("\(u):\(p)".utf8).base64EncodedString()
            headers.append(("Authorization", "Basic \(b64)"))
        case .apiKey where !effectiveAuth.apiKeyName.isEmpty:
            let k = APIVariableResolver.resolve(effectiveAuth.apiKeyName, variables: variables)
            let v = APIVariableResolver.resolve(effectiveAuth.apiKeyValue, variables: variables)
            if effectiveAuth.apiKeyIn == .query {
                params.append(APIKeyValueItem(key: k, value: v))
            } else {
                headers.append((k, v))
            }
        default:
            break
        }

        let url = APIFormatCodec.composeRawURL(baseURL: base, queryParams: params)
        var body: String? = nil
        switch request.body.mode {
        case .none:
            break
        case .json, .raw:
            let txt = APIVariableResolver.resolve(request.body.rawText, variables: variables)
            if !txt.isEmpty { body = txt }
        case .formURLEncoded:
            let pairs = request.body.formItems.filter { $0.isEnabled && !$0.key.isEmpty }
                .map { "\(APIVariableResolver.resolve($0.key, variables: variables))=\(APIVariableResolver.resolve($0.value, variables: variables))" }
            if !pairs.isEmpty { body = pairs.joined(separator: "&") }
        case .graphql:
            let q = APIVariableResolver.resolve(request.body.graphqlQuery, variables: variables)
            if let d = try? JSONSerialization.data(withJSONObject: ["query": q]), let s = String(data: d, encoding: .utf8) {
                body = s
            }
        case .multipartFormData:
            break
        }
        return (url, headers, body)
    }

    private static func generateCurl(request: APIRequestItem, effectiveAuth: APIAuthConfig, variables: [String: String]) -> String {
        let ctx = resolvedContext(request: request, effectiveAuth: effectiveAuth, variables: variables)
        var parts: [String] = ["curl -X \(request.method.rawValue) '\(escapeShellSQ(ctx.url))'"]
        for (k, v) in ctx.headers {
            parts.append("  -H '\(escapeShellSQ(k)): \(escapeShellSQ(v))'")
        }
        if request.body.mode == .multipartFormData {
            for item in request.body.formItems where item.isEnabled && !item.key.isEmpty {
                let k = APIVariableResolver.resolve(item.key, variables: variables)
                if let fp = item.filePath, !fp.isEmpty {
                    parts.append("  -F '\(escapeShellSQ(k))=@\(escapeShellSQ(fp))'")
                } else {
                    let v = APIVariableResolver.resolve(item.value, variables: variables)
                    parts.append("  -F '\(escapeShellSQ(k))=\(escapeShellSQ(v))'")
                }
            }
        } else if let body = ctx.body {
            parts.append("  --data-raw '\(escapeShellSQ(body))'")
        }
        return parts.joined(separator: " \\\n")
    }

    private static func generateCodeceptSnippet(request: APIRequestItem, effectiveAuth: APIAuthConfig, variables: [String: String]) -> String {
        let lines = generateCodeceptBodyLines(request: request, effectiveAuth: effectiveAuth, variables: variables)
        return "Scenario('\(escapeSQ(request.name))', async ({ I }) => {\n" + lines.map { "  \($0)" }.joined(separator: "\n") + "\n});"
    }

    private static func generateCodeceptBodyLines(request: APIRequestItem, effectiveAuth: APIAuthConfig, variables: [String: String]) -> [String] {
        let ctx = resolvedContext(request: request, effectiveAuth: effectiveAuth, variables: variables)
        let headerLiteral = jsObjectLiteral(ctx.headers)
        let methodCall: String
        switch request.method {
        case .get: methodCall = "sendGetRequest"
        case .post: methodCall = "sendPostRequest"
        case .put: methodCall = "sendPutRequest"
        case .patch: methodCall = "sendPatchRequest"
        case .delete: methodCall = "sendDeleteRequest"
        case .head: methodCall = "sendHeadRequest"
        case .options: methodCall = "sendGetRequest"
        }

        var lines: [String] = []
        if let body = ctx.body, request.method == .post || request.method == .put || request.method == .patch {
            let payloadExpr = (request.body.mode == .json || request.body.mode == .graphql) ? body : "'\(escapeSQ(body))'"
            if ctx.headers.isEmpty {
                lines.append("const response = await I.\(methodCall)('\(escapeSQ(ctx.url))', \(payloadExpr));")
            } else {
                lines.append("const response = await I.\(methodCall)('\(escapeSQ(ctx.url))', \(payloadExpr), \(headerLiteral));")
            }
        } else {
            if ctx.headers.isEmpty {
                lines.append("const response = await I.\(methodCall)('\(escapeSQ(ctx.url))');")
            } else {
                lines.append("const response = await I.\(methodCall)('\(escapeSQ(ctx.url))', \(headerLiteral));")
            }
        }

        let statusRule = request.assertions.first(where: { $0.isEnabled && $0.target == .statusCode && $0.op == .equals })
        lines.append("I.seeResponseCodeIs(\(statusRule?.expectedValue ?? "200"));")
        return lines
    }

    private static func generatePlaywrightTSSnippet(request: APIRequestItem, effectiveAuth: APIAuthConfig, variables: [String: String]) -> String {
        let lines = generatePlaywrightTSBodyLines(request: request, effectiveAuth: effectiveAuth, variables: variables)
        return "test('\(escapeSQ(request.name))', async ({ request }) => {\n" + lines.map { "  \($0)" }.joined(separator: "\n") + "\n});"
    }

    private static func generatePlaywrightTSBodyLines(request: APIRequestItem, effectiveAuth: APIAuthConfig, variables: [String: String]) -> [String] {
        let ctx = resolvedContext(request: request, effectiveAuth: effectiveAuth, variables: variables)
        let pwMethod = request.method.rawValue.lowercased()
        var opts: [String] = []
        if !ctx.headers.isEmpty {
            opts.append("headers: \(jsObjectLiteral(ctx.headers))")
        }
        if let body = ctx.body {
            if request.body.mode == .json || request.body.mode == .graphql {
                opts.append("data: \(body)")
            } else {
                opts.append("data: '\(escapeSQ(body))'")
            }
        }
        var lines: [String] = []
        if opts.isEmpty {
            lines.append("const response = await request.\(pwMethod)('\(escapeSQ(ctx.url))');")
        } else {
            lines.append("const response = await request.\(pwMethod)('\(escapeSQ(ctx.url))', { \(opts.joined(separator: ", ")) });")
        }
        if let statusRule = request.assertions.first(where: { $0.isEnabled && $0.target == .statusCode && $0.op == .equals }) {
            lines.append("expect(response.status()).toBe(\(statusRule.expectedValue));")
        } else {
            lines.append("await expect(response).toBeOK();")
        }
        return lines
    }

    private static func generatePlaywrightPythonSnippet(request: APIRequestItem, effectiveAuth: APIAuthConfig, variables: [String: String]) -> String {
        let lines = generatePlaywrightPythonBodyLines(request: request, effectiveAuth: effectiveAuth, variables: variables)
        return "def test_\(slugify(request.name))(api_request_context: APIRequestContext):\n" + lines.map { "    \($0)" }.joined(separator: "\n")
    }

    private static func generatePlaywrightPythonBodyLines(request: APIRequestItem, effectiveAuth: APIAuthConfig, variables: [String: String]) -> [String] {
        let ctx = resolvedContext(request: request, effectiveAuth: effectiveAuth, variables: variables)
        let pwMethod = request.method.rawValue.lowercased()
        var args: [String] = ["\"\(escapeDQ(ctx.url))\""]
        if !ctx.headers.isEmpty {
            let pyDict = "{" + ctx.headers.map { "\"\(escapeDQ($0.0))\": \"\(escapeDQ($0.1))\"" }.joined(separator: ", ") + "}"
            args.append("headers=\(pyDict)")
        }
        if let body = ctx.body {
            args.append("data=\"\"\"\(body)\"\"\"")
        }
        var lines: [String] = ["response = api_request_context.\(pwMethod)(\(args.joined(separator: ", ")))"]
        if let statusRule = request.assertions.first(where: { $0.isEnabled && $0.target == .statusCode && $0.op == .equals }) {
            lines.append("assert response.status == \(statusRule.expectedValue)")
        } else {
            lines.append("expect(response).to_be_ok()")
        }
        return lines
    }

    private static func jsObjectLiteral(_ pairs: [(String, String)]) -> String {
        let inner = pairs.map { "'\(escapeSQ($0.0))': '\(escapeSQ($0.1))'" }.joined(separator: ", ")
        return "{ \(inner) }"
    }

    private static func escapeSQ(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func escapeDQ(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func escapeShellSQ(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func slugify(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let cleaned = lowered.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return cleaned.isEmpty ? "collection" : cleaned
    }
}
