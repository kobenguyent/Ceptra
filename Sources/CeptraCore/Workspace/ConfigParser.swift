import Foundation

public enum ConfigParser {
    public static let configFileNames: [String] = [
        "codecept.config.ts",
        "codecept.conf.ts",
        "codecept.config.js",
        "codecept.conf.js",
        "codecept.config.cjs",
        "codecept.conf.cjs",
        "codecept.config.mjs",
        "codecept.conf.mjs",
        "codecept.js"
    ]

    public static func locateConfigFile(in rootURL: URL) -> URL? {
        let fm = FileManager.default
        for name in configFileNames {
            let candidate = rootURL.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public static func parseWorkspaceConfig(rootURL: URL) -> CodeceptConfigSummary {
        let packageInfo = parsePackageJSON(rootURL: rootURL)
        let configURL = locateConfigFile(in: rootURL)
        let fallbackName = packageInfo.name ?? rootURL.lastPathComponent

        guard let configURL,
              let rawContent = try? String(contentsOf: configURL, encoding: .utf8) else {
            return CodeceptConfigSummary(
                configFilePath: nil,
                projectName: fallbackName,
                packageCodeceptVersion: packageInfo.codeceptVersion,
                isESM: packageInfo.isESM,
                isTypeScript: FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("tsconfig.json").path)
            )
        }

        let cleaned = stripJSComments(from: rawContent)
        let configBody = extractNamedObjectBlock(named: "config", in: cleaned)
            ?? extractDefaultExportObject(in: cleaned)
            ?? cleaned

        let name = extractStringProperty(named: "name", in: configBody) ?? fallbackName
        let testsPattern = extractStringProperty(named: "tests", in: configBody) ?? "./*_test.js"
        let outputDir = extractStringProperty(named: "output", in: configBody) ?? "./output"

        let helpersBlock = extractNamedObjectBlock(named: "helpers", in: configBody) ?? ""
        let helpers = parseHelpers(from: helpersBlock)

        let pluginsBlock = extractNamedObjectBlock(named: "plugins", in: configBody) ?? ""
        let plugins = parsePlugins(from: pluginsBlock)

        let includeBlock = extractNamedObjectBlock(named: "include", in: configBody) ?? ""
        let includes = parseIncludes(from: includeBlock)

        let gherkinBlock = extractNamedObjectBlock(named: "gherkin", in: configBody) ?? ""
        let gherkinFeatures = extractStringProperty(named: "features", in: gherkinBlock)
        let gherkinSteps = extractStringArrayProperty(named: "steps", in: gherkinBlock)

        let ext = configURL.pathExtension.lowercased()
        let isTS = ext == "ts" || ext == "mts" || ext == "cts"
            || FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("tsconfig.json").path)
        let isESM = packageInfo.isESM || ext == "mjs" || rawContent.contains("export const config") || rawContent.contains("export default")

        return CodeceptConfigSummary(
            configFilePath: configURL.path,
            projectName: name,
            testsPattern: testsPattern,
            outputDirectory: outputDir,
            gherkinFeaturesPattern: gherkinFeatures,
            gherkinStepsPaths: gherkinSteps,
            helpers: helpers,
            plugins: plugins,
            includes: includes,
            packageCodeceptVersion: packageInfo.codeceptVersion,
            isESM: isESM,
            isTypeScript: isTS
        )
    }

    // MARK: - package.json

    private struct PackageInfo {
        let name: String?
        let codeceptVersion: String?
        let isESM: Bool
    }

    private static func parsePackageJSON(rootURL: URL) -> PackageInfo {
        let pkgURL = rootURL.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: pkgURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PackageInfo(name: nil, codeceptVersion: nil, isESM: false)
        }
        let name = json["name"] as? String
        let isESM = (json["type"] as? String)?.lowercased() == "module"
        let deps = json["dependencies"] as? [String: String] ?? [:]
        let devDeps = json["devDependencies"] as? [String: String] ?? [:]
        let version = devDeps["codeceptjs"] ?? deps["codeceptjs"]
            ?? ((name == "codeceptjs") ? (json["version"] as? String) : nil)
        return PackageInfo(name: name, codeceptVersion: version, isESM: isESM)
    }

    // MARK: - Block Extraction

    private static func parseHelpers(from block: String) -> [CodeceptHelperInfo] {
        let entries = topLevelObjectEntries(in: block)
        return entries.map { key, body in
            let requirePath = extractStringProperty(named: "require", in: body)
            let url = extractStringProperty(named: "url", in: body)
                ?? extractStringProperty(named: "endpoint", in: body)
            let browser = extractStringProperty(named: "browser", in: body)
            var summaryParts: [String] = []
            if let browser { summaryParts.append(browser) }
            if let url { summaryParts.append(url) }
            if let requirePath, summaryParts.isEmpty { summaryParts.append(requirePath) }
            let summary = summaryParts.isEmpty ? nil : summaryParts.joined(separator: " · ")
            return CodeceptHelperInfo(
                name: key,
                isBuiltIn: CodeceptHelperInfo.knownBuiltIns.contains(key),
                requirePath: requirePath,
                summary: summary
            )
        }
    }

    private static func parsePlugins(from block: String) -> [CodeceptPluginInfo] {
        let entries = topLevelObjectEntries(in: block)
        return entries.map { key, body in
            let enabled = extractBoolProperty(named: "enabled", in: body) ?? true
            let requirePath = extractStringProperty(named: "require", in: body)
            return CodeceptPluginInfo(name: key, enabled: enabled, requirePath: requirePath)
        }
    }

    private static func parseIncludes(from block: String) -> [CodeceptIncludeEntry] {
        guard !block.isEmpty else { return [] }
        let pattern = #"["']?([A-Za-z_$][\w$-]*)["']?\s*:\s*["'`]([^"'`]+)["'`]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = block as NSString
        let matches = regex.matches(in: block, range: NSRange(location: 0, length: ns.length))
        var results: [CodeceptIncludeEntry] = []
        var seen = Set<String>()
        for match in matches {
            let alias = ns.substring(with: match.range(at: 1))
            let relPath = ns.substring(with: match.range(at: 2))
            if seen.insert(alias).inserted {
                results.append(CodeceptIncludeEntry(alias: alias, relativePath: relPath))
            }
        }
        return results
    }

    private static func topLevelObjectEntries(in innerBlock: String) -> [(String, String)] {
        let chars = Array(innerBlock)
        var results: [(String, String)] = []
        var index = 0
        var depth = 0
        var inString: Character? = nil
        var escaped = false

        while index < chars.count {
            let c = chars[index]
            if let quote = inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == quote {
                    inString = nil
                }
                index += 1
                continue
            }
            if c == "'" || c == "\"" || c == "`" {
                if depth == 0 {
                    // Potential quoted key at depth 0
                    if let (key, afterKey) = readKeyAndBrace(chars: chars, start: index) {
                        if let closeIdx = matchingBraceIndex(chars: chars, openIndex: afterKey) {
                            let body = String(chars[(afterKey + 1)..<closeIdx])
                            results.append((key, body))
                            index = closeIdx + 1
                            continue
                        }
                    }
                }
                inString = c
                index += 1
                continue
            }

            if depth == 0 && (c.isLetter || c == "_" || c == "$") {
                if let (key, braceIdx) = readKeyAndBrace(chars: chars, start: index),
                   let closeIdx = matchingBraceIndex(chars: chars, openIndex: braceIdx) {
                    let body = String(chars[(braceIdx + 1)..<closeIdx])
                    results.append((key, body))
                    index = closeIdx + 1
                    continue
                }
            }

            if c == "{" { depth += 1 }
            else if c == "}" { depth = max(0, depth - 1) }
            index += 1
        }
        return results
    }

    private static func readKeyAndBrace(chars: [Character], start: Int) -> (String, Int)? {
        var i = start
        var key = ""
        if chars[i] == "'" || chars[i] == "\"" {
            let quote = chars[i]
            i += 1
            while i < chars.count && chars[i] != quote {
                key.append(chars[i])
                i += 1
            }
            guard i < chars.count else { return nil }
            i += 1
        } else {
            while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "$" || chars[i] == "-") {
                key.append(chars[i])
                i += 1
            }
        }
        guard !key.isEmpty else { return nil }
        while i < chars.count && chars[i].isWhitespace { i += 1 }
        guard i < chars.count && chars[i] == ":" else { return nil }
        i += 1
        while i < chars.count && chars[i].isWhitespace { i += 1 }
        guard i < chars.count && chars[i] == "{" else { return nil }
        return (key, i)
    }

    static func extractNamedObjectBlock(named property: String, in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let pattern = "(?:\\b\(escaped)\\b|[\"']\(escaped)[\"'])\\s*(?::[^=\\{]*=|=|:)\\s*\\{"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let openUTF16 = match.range.location + match.range.length - 1
        guard let range = Range(NSRange(location: openUTF16, length: 1), in: text) else { return nil }
        let prefixCount = text.distance(from: text.startIndex, to: range.lowerBound)
        let chars = Array(text)
        guard let closeIdx = matchingBraceIndex(chars: chars, openIndex: prefixCount) else { return nil }
        return String(chars[(prefixCount + 1)..<closeIdx])
    }

    private static func extractDefaultExportObject(in text: String) -> String? {
        let pattern = #"export\s+default\s*\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let openUTF16 = match.range.location + match.range.length - 1
        guard let range = Range(NSRange(location: openUTF16, length: 1), in: text) else { return nil }
        let prefixCount = text.distance(from: text.startIndex, to: range.lowerBound)
        let chars = Array(text)
        guard let closeIdx = matchingBraceIndex(chars: chars, openIndex: prefixCount) else { return nil }
        return String(chars[(prefixCount + 1)..<closeIdx])
    }

    private static func matchingBraceIndex(chars: [Character], openIndex: Int) -> Int? {
        guard openIndex < chars.count, chars[openIndex] == "{" else { return nil }
        var depth = 0
        var inString: Character? = nil
        var escaped = false
        for idx in openIndex..<chars.count {
            let c = chars[idx]
            if let quote = inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == quote { inString = nil }
                continue
            }
            if c == "'" || c == "\"" || c == "`" {
                inString = c
                continue
            }
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { return idx }
            }
        }
        return nil
    }

    private static func extractStringProperty(named property: String, in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let pattern = "(?:\\b\(escaped)\\b|[\"']\(escaped)[\"'])\\s*:\\s*[\"'`]([^\"'`\\n]+)[\"'`]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }

    private static func extractBoolProperty(named property: String, in text: String) -> Bool? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let pattern = "(?:\\b\(escaped)\\b|[\"']\(escaped)[\"'])\\s*:\\s*(true|false)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: match.range(at: 1)) == "true"
    }

    private static func extractStringArrayProperty(named property: String, in text: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let pattern = "(?:\\b\(escaped)\\b|[\"']\(escaped)[\"'])\\s*:\\s*\\[([^\\]]*)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return []
        }
        let arrayBody = ns.substring(with: match.range(at: 1))
        guard let strRegex = try? NSRegularExpression(pattern: #"["'`]([^"'`]+)["'`]"#) else { return [] }
        let bodyNS = arrayBody as NSString
        return strRegex.matches(in: arrayBody, range: NSRange(location: 0, length: bodyNS.length)).map {
            bodyNS.substring(with: $0.range(at: 1))
        }
    }

    static func stripJSComments(from source: String) -> String {
        let chars = Array(source)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        var inString: Character? = nil
        var escaped = false

        while i < chars.count {
            let c = chars[i]
            if let quote = inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == quote { inString = nil }
                i += 1
                continue
            }
            if c == "'" || c == "\"" || c == "`" {
                inString = c
                out.append(c)
                i += 1
                continue
            }
            if c == "/" && i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "/" {
                    i += 2
                    while i < chars.count && chars[i] != "\n" { i += 1 }
                    continue
                }
                if next == "*" {
                    i += 2
                    while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") {
                        if chars[i] == "\n" { out.append("\n") }
                        i += 1
                    }
                    i += 2
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }
}
