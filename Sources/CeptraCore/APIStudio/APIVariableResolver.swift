import Foundation

/// Resolves Postman/Insomnia-style `{{variable}}`, `{{ _.variable }}`, and dynamic `{{$guid}}`
/// template placeholders, plus evaluates lightweight JSONPath queries (`$.a.b[0].c`).
public enum APIVariableResolver {
    private static let placeholderRegex = try! NSRegularExpression(
        pattern: #"\{\{\s*(?:_\.)?([a-zA-Z0-9_.\-$]+)\s*\}\}"#
    )

    /// Merges collection variables, active environment variables, and runtime extracted variables
    /// in industry-standard precedence order (runtime > environment > collection).
    public static func mergedVariables(
        collection: APICollection?,
        environment: APIEnvironment?,
        runtimeOverrides: [String: String] = [:]
    ) -> [String: String] {
        var result: [String: String] = [:]
        if let collection {
            for item in collection.variables where item.isEnabled && !item.key.trimmingCharacters(in: .whitespaces).isEmpty {
                result[item.key] = item.value
            }
        }
        if let environment {
            for item in environment.variables where item.isEnabled && !item.key.trimmingCharacters(in: .whitespaces).isEmpty {
                result[item.key] = item.effectiveValue
            }
        }
        for (k, v) in runtimeOverrides where !k.trimmingCharacters(in: .whitespaces).isEmpty {
            result[k] = v
        }
        return result
    }

    /// Substitutes all `{{key}}` and `{{ _.key }}` occurrences in `template`.
    /// Supports nested variable references up to 3 passes and built-in dynamic `{{$...}}` helpers.
    public static func resolve(_ template: String, variables: [String: String]) -> String {
        guard template.contains("{{") else { return template }
        var current = template
        for _ in 0..<3 {
            let ns = current as NSString
            let matches = placeholderRegex.matches(in: current, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { break }

            var replacedAny = false
            var output = current
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2 else { continue }
                let fullRange = match.range(at: 0)
                let keyRange = match.range(at: 1)
                let key = ns.substring(with: keyRange)

                let replacement: String?
                if let val = variables[key] {
                    replacement = val
                } else if key.hasPrefix("$"), let dyn = resolveDynamicVariable(key) {
                    replacement = dyn
                } else {
                    replacement = nil
                }

                if let replacement, let swiftRange = Range(fullRange, in: output) {
                    output.replaceSubrange(swiftRange, with: replacement)
                    replacedAny = true
                }
            }
            current = output
            if !replacedAny { break }
        }
        return current
    }

    /// Returns any placeholder names inside `template` that are not satisfied by `variables` or built-in `$` generators.
    public static func unresolvedVariableNames(in template: String, variables: [String: String]) -> [String] {
        guard template.contains("{{") else { return [] }
        let ns = template as NSString
        let matches = placeholderRegex.matches(in: template, range: NSRange(location: 0, length: ns.length))
        var missing: [String] = []
        var seen: Set<String> = []
        for match in matches where match.numberOfRanges >= 2 {
            let key = ns.substring(with: match.range(at: 1))
            if variables[key] == nil && resolveDynamicVariable(key) == nil && seen.insert(key).inserted {
                missing.append(key)
            }
        }
        return missing
    }

    /// Normalizes Insomnia `{{ _.foo }}` syntax into universal `{{foo}}` syntax while preserving other templates.
    public static func normalizeInsomniaTemplates(_ text: String) -> String {
        guard text.contains("{{") else { return text }
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*_\.([a-zA-Z0-9_.\-$]+)\s*\}\}"#) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "{{$1}}")
    }

    private static func resolveDynamicVariable(_ name: String) -> String? {
        switch name.lowercased() {
        case "$guid", "$uuid", "$randomuuid":
            return UUID().uuidString.lowercased()
        case "$timestamp":
            return String(Int(Date().timeIntervalSince1970))
        case "$isotimestamp":
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fmt.string(from: Date())
        case "$randomint":
            return String(Int.random(in: 0...1000))
        case "$randomboolean":
            return Bool.random() ? "true" : "false"
        case "$randomemail":
            let token = UUID().uuidString.prefix(6).lowercased()
            return "qa.\(token)@example.com"
        default:
            return nil
        }
    }

    // MARK: - Lightweight JSONPath Evaluator

    /// Evaluates dot/bracket JSONPath expressions such as `$.id`, `$.data.users[0].email`,
    /// `$.items.length`, or `token` against raw JSON text.
    public static func evaluateJSONPath(_ expression: String, inJSONString jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return evaluateJSONPath(expression, inObject: root)
    }

    public static func evaluateJSONPath(_ expression: String, inObject root: Any) -> String? {
        let tokens = parseJSONPathTokens(expression)
        guard !tokens.isEmpty else {
            return stringifyJSONValue(root)
        }

        var current: Any = root
        for token in tokens {
            switch token {
            case .key(let key):
                if let dict = current as? [String: Any], let next = dict[key] {
                    current = next
                } else if key == "length", let arr = current as? [Any] {
                    current = arr.count
                } else if key == "length", let str = current as? String {
                    current = str.count
                } else {
                    return nil
                }
            case .index(let idx):
                guard let arr = current as? [Any] else { return nil }
                let resolvedIdx = idx < 0 ? (arr.count + idx) : idx
                guard arr.indices.contains(resolvedIdx) else { return nil }
                current = arr[resolvedIdx]
            }
        }
        return stringifyJSONValue(current)
    }

    private enum JSONPathToken {
        case key(String)
        case index(Int)
    }

    private static func parseJSONPathTokens(_ raw: String) -> [JSONPathToken] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("$.") {
            s.removeFirst(2)
        } else if s.hasPrefix("$") {
            s.removeFirst(1)
        }
        if s.isEmpty { return [] }

        var tokens: [JSONPathToken] = []
        var buf = ""
        let chars = Array(s)
        var i = 0

        func flushBuffer() {
            if !buf.isEmpty {
                tokens.append(.key(buf))
                buf = ""
            }
        }

        while i < chars.count {
            let c = chars[i]
            if c == "." {
                flushBuffer()
                i += 1
            } else if c == "[" {
                flushBuffer()
                i += 1
                var inner = ""
                var quote: Character? = nil
                while i < chars.count {
                    let ch = chars[i]
                    if let q = quote {
                        if ch == q {
                            quote = nil
                        } else {
                            inner.append(ch)
                        }
                    } else if ch == "'" || ch == "\"" {
                        quote = ch
                    } else if ch == "]" {
                        i += 1
                        break
                    } else {
                        inner.append(ch)
                    }
                    i += 1
                }
                let trimmed = inner.trimmingCharacters(in: .whitespaces)
                if let idx = Int(trimmed) {
                    tokens.append(.index(idx))
                } else if !trimmed.isEmpty {
                    tokens.append(.key(trimmed))
                }
            } else {
                buf.append(c)
                i += 1
            }
        }
        flushBuffer()
        return tokens
    }

    public static func stringifyJSONValue(_ value: Any) -> String {
        if value is NSNull {
            return "null"
        }
        if let str = value as? String {
            return str
        }
        if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return num.boolValue ? "true" : "false"
            }
            return num.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: value)
    }
}
