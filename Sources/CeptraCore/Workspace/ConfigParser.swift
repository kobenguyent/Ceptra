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
        "codecept.js",
        "codecept.json"
    ]

    public static let supportedConfigExtensions: Set<String> = [
        "js", "ts", "cjs", "mjs", "mts", "cts", "json"
    ]

    private static let ignoredScanDirectories: Set<String> = [
        "node_modules", ".git", ".idea", ".vscode", "dist", "build",
        "output", "_output", "coverage", ".build", ".next", "allure-report", "allure-results"
    ]

    private static let excludedToolConfigPrefixes: [String] = [
        "eslint.", "prettier.", "vite.", "vitest.", "jest.", "playwright.",
        "webpack.", "babel.", "postcss.", "tailwind.", "next.", "nuxt.",
        "rollup.", "tsup.", "metro.", "commitlint.", "stylelint.", "tsconfig.",
        "jsconfig.", "package.", "package-lock."
    ]

    /// Resolves a user-supplied custom config path (either absolute or relative to `rootURL`).
    /// Also supports passing a directory containing a standard CodeceptJS config file.
    public static func resolveConfigURL(customPath: String, relativeTo rootURL: URL) -> URL? {
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let candidate: URL
        if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            candidate = rootURL.appendingPathComponent(expanded).standardizedFileURL
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: candidate.path, isDirectory: &isDir) else {
            return nil
        }

        if isDir.boolValue {
            return locateStandardConfigFile(in: candidate) ?? discoverConfigFiles(in: candidate).first
        }
        return candidate
    }

    public static func locateStandardConfigFile(in directoryURL: URL) -> URL? {
        let fm = FileManager.default
        for name in configFileNames {
            let candidate = directoryURL.appendingPathComponent(name).standardizedFileURL
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Discovers standard AND custom-named / nested CodeceptJS config files inside `rootURL`:
    /// 1. Standard root config names (`codecept.conf.ts`, `codecept.config.js`, etc.)
    /// 2. Explicit `-c` / `--config` paths declared in `package.json` scripts
    /// 3. Custom `codecept*.{ts,js,cjs,mjs,json}` or `*codecept*.conf*.{ts,js,cjs,mjs}` files at root or nested dirs (up to depth 4)
    /// 4. Custom-named `*.conf.*` / `*.config.*` files whose content declares a CodeceptJS config (`helpers:` + config export)
    public static func discoverConfigFiles(in rootURL: URL) -> [URL] {
        let standardizedRoot = rootURL.standardizedFileURL
        let fm = FileManager.default
        var scored: [String: (url: URL, priority: Int)] = [:]

        func register(_ url: URL, priority: Int) {
            let std = url.standardizedFileURL
            guard fm.fileExists(atPath: std.path) else { return }
            if let existing = scored[std.path] {
                if priority < existing.priority {
                    scored[std.path] = (std, priority)
                }
            } else {
                scored[std.path] = (std, priority)
            }
        }

        // 1. Standard root configs (highest auto-discovery priority)
        for (idx, name) in configFileNames.enumerated() {
            let candidate = standardizedRoot.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) {
                register(candidate, priority: 10 + idx)
            }
        }

        // 2. Explicit `-c` / `--config` targets referenced in package.json scripts
        for scriptConfigURL in extractConfigPathsFromPackageScripts(rootURL: standardizedRoot) {
            register(scriptConfigURL, priority: 25)
        }

        // 3. Walk workspace up to depth 4 for custom-named & nested CodeceptJS configs
        let rootPrefix = standardizedRoot.path.hasSuffix("/") ? standardizedRoot.path : standardizedRoot.path + "/"
        if let enumerator = fm.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else {
                    continue
                }
                let fileName = fileURL.lastPathComponent
                if values.isDirectory == true {
                    if ignoredScanDirectories.contains(fileName) {
                        enumerator.skipDescendants()
                        continue
                    }
                    let relDir = fileURL.standardizedFileURL.path.replacingOccurrences(of: rootPrefix, with: "")
                    if relDir.split(separator: "/").count >= 4 {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                guard values.isRegularFile == true else { continue }
                let ext = fileURL.pathExtension.lowercased()
                guard supportedConfigExtensions.contains(ext) else { continue }

                let lower = fileName.lowercased()
                if excludedToolConfigPrefixes.contains(where: { lower.hasPrefix($0) }) {
                    continue
                }
                // Skip test files
                if lower.contains("_test.") || lower.contains(".test.") || lower.contains("_spec.") || lower.contains(".spec.") {
                    continue
                }

                let relPath = fileURL.standardizedFileURL.path.replacingOccurrences(of: rootPrefix, with: "")
                let depth = relPath.split(separator: "/").count - 1
                guard depth <= 4 else { continue }

                if configFileNames.contains(fileName) {
                    register(fileURL, priority: 30 + depth * 5)
                    continue
                }

                if lower.contains("codecept") {
                    register(fileURL, priority: 40 + depth * 5)
                    continue
                }

                // Custom name without "codecept" (e.g. configs/e2e.conf.ts, staging.config.js):
                // inspect file contents safely (skip huge files > 128 KB)
                let size = values.fileSize ?? 0
                if size > 0 && size <= 131_072,
                   (lower.contains(".conf.") || lower.contains(".config.") || relPath.lowercased().contains("config")),
                   let content = try? String(contentsOf: fileURL, encoding: .utf8),
                   looksLikeCodeceptConfig(content: content, ext: ext) {
                    register(fileURL, priority: 60 + depth * 5)
                }
            }
        }

        return scored.values
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority < rhs.priority
                }
                return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
            }
            .map(\.url)
    }

    public static func locateConfigFile(in rootURL: URL) -> URL? {
        discoverConfigFiles(in: rootURL).first
    }

    public static func parseWorkspaceConfig(
        rootURL: URL,
        explicitConfigPath: String? = nil
    ) -> CodeceptConfigSummary {
        let standardizedRoot = rootURL.standardizedFileURL
        let packageInfo = parsePackageJSON(rootURL: standardizedRoot)

        let resolvedExplicit: URL?
        if let explicitConfigPath, !explicitConfigPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedExplicit = resolveConfigURL(customPath: explicitConfigPath, relativeTo: standardizedRoot)
        } else {
            resolvedExplicit = nil
        }

        let isCustomOverride = resolvedExplicit != nil
        let configURL = resolvedExplicit ?? locateConfigFile(in: standardizedRoot)
        return parseConfigSummary(
            configURL: configURL,
            standardizedRoot: standardizedRoot,
            packageInfo: packageInfo,
            isCustomOverride: isCustomOverride
        )
    }

    /// Parses multiple discovered CodeceptJS configs in one pass (reading `package.json` once).
    public static func parseConfigFiles(
        _ configURLs: [URL],
        rootURL: URL,
        activeConfigPath: String? = nil,
        isCustomOverride: Bool = false
    ) -> [CodeceptConfigSummary] {
        let standardizedRoot = rootURL.standardizedFileURL
        let packageInfo = parsePackageJSON(rootURL: standardizedRoot)
        return configURLs.map { url in
            let stdURL = url.standardizedFileURL
            let overrideFlag = isCustomOverride && (stdURL.path == activeConfigPath)
            return parseConfigSummary(
                configURL: stdURL,
                standardizedRoot: standardizedRoot,
                packageInfo: packageInfo,
                isCustomOverride: overrideFlag
            )
        }
    }

    private static func parseConfigSummary(
        configURL: URL?,
        standardizedRoot: URL,
        packageInfo: PackageInfo,
        isCustomOverride: Bool
    ) -> CodeceptConfigSummary {
        let fallbackName = packageInfo.name ?? standardizedRoot.lastPathComponent

        guard let configURL,
              let rawContent = try? String(contentsOf: configURL, encoding: .utf8) else {
            return CodeceptConfigSummary(
                configFilePath: nil,
                isCustomConfigOverride: false,
                projectName: fallbackName,
                packageCodeceptVersion: packageInfo.codeceptVersion,
                isESM: packageInfo.isESM,
                isTypeScript: FileManager.default.fileExists(atPath: standardizedRoot.appendingPathComponent("tsconfig.json").path)
            )
        }

        let ext = configURL.pathExtension.lowercased()
        if ext == "json" {
            return parseJSONConfig(
                rawContent: rawContent,
                configURL: configURL,
                isCustomOverride: isCustomOverride,
                fallbackName: fallbackName,
                packageInfo: packageInfo
            )
        }

        let cleaned = stripJSComments(from: rawContent)
        let configBody = extractNamedObjectBlock(named: "config", in: cleaned)
            ?? extractDefaultExportObject(in: cleaned)
            ?? cleaned

        let name = extractStringProperty(named: "name", in: configBody) ?? fallbackName
        let parsedTestsPattern = extractStringProperty(named: "tests", in: configBody)
        let testsPattern = parsedTestsPattern ?? "./*_test.js"
        let outputDir = extractStringProperty(named: "output", in: configBody) ?? "./output"

        let helpersBlock = extractNamedObjectBlock(named: "helpers", in: configBody) ?? ""
        let helpers = parseHelpers(from: helpersBlock)

        let pluginsBlock = extractNamedObjectBlock(named: "plugins", in: configBody) ?? ""
        let plugins = parsePlugins(from: pluginsBlock)

        let includeBlock = extractNamedObjectBlock(named: "include", in: configBody) ?? ""
        let includes = parseIncludes(from: includeBlock)

        let multipleBlock = extractNamedObjectBlock(named: "multiple", in: configBody) ?? ""
        let multipleSuites = parseMultipleSuites(from: multipleBlock)

        let gherkinBlock = extractNamedObjectBlock(named: "gherkin", in: configBody) ?? ""
        let gherkinFeatures = extractStringProperty(named: "features", in: gherkinBlock)
        let gherkinSteps = extractStringArrayProperty(named: "steps", in: gherkinBlock)

        let isTS = ext == "ts" || ext == "mts" || ext == "cts"
            || FileManager.default.fileExists(atPath: standardizedRoot.appendingPathComponent("tsconfig.json").path)
        let isESM = packageInfo.isESM || ext == "mjs" || rawContent.contains("export const config") || rawContent.contains("export default")

        return CodeceptConfigSummary(
            configFilePath: configURL.standardizedFileURL.path,
            isCustomConfigOverride: isCustomOverride,
            projectName: name,
            testsPattern: testsPattern,
            hasExplicitTestsPattern: parsedTestsPattern != nil,
            outputDirectory: outputDir,
            gherkinFeaturesPattern: gherkinFeatures,
            gherkinStepsPaths: gherkinSteps,
            helpers: helpers,
            plugins: plugins,
            includes: includes,
            multipleSuites: multipleSuites,
            packageCodeceptVersion: packageInfo.codeceptVersion,
            isESM: isESM,
            isTypeScript: isTS
        )
    }

    // MARK: - JSON Config Parsing

    private static func parseJSONConfig(
        rawContent: String,
        configURL: URL,
        isCustomOverride: Bool,
        fallbackName: String,
        packageInfo: PackageInfo
    ) -> CodeceptConfigSummary {
        guard let data = rawContent.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CodeceptConfigSummary(
                configFilePath: configURL.standardizedFileURL.path,
                isCustomConfigOverride: isCustomOverride,
                projectName: fallbackName,
                packageCodeceptVersion: packageInfo.codeceptVersion,
                isESM: packageInfo.isESM,
                isTypeScript: false
            )
        }

        let name = (json["name"] as? String) ?? fallbackName
        let parsedTestsPattern = json["tests"] as? String
        let testsPattern = parsedTestsPattern ?? "./*_test.js"
        let outputDir = (json["output"] as? String) ?? "./output"

        var helpers: [CodeceptHelperInfo] = []
        if let helperDict = json["helpers"] as? [String: Any] {
            for (key, value) in helperDict.sorted(by: { $0.key < $1.key }) {
                let obj = value as? [String: Any] ?? [:]
                let req = obj["require"] as? String
                let url = (obj["url"] as? String) ?? (obj["endpoint"] as? String)
                let browser = obj["browser"] as? String
                var parts: [String] = []
                if let browser { parts.append(browser) }
                if let url { parts.append(url) }
                if let req, parts.isEmpty { parts.append(req) }
                helpers.append(CodeceptHelperInfo(
                    name: key,
                    isBuiltIn: CodeceptHelperInfo.knownBuiltIns.contains(key),
                    requirePath: req,
                    summary: parts.isEmpty ? nil : parts.joined(separator: " · ")
                ))
            }
        }

        var plugins: [CodeceptPluginInfo] = []
        if let pluginDict = json["plugins"] as? [String: Any] {
            for (key, value) in pluginDict.sorted(by: { $0.key < $1.key }) {
                let obj = value as? [String: Any] ?? [:]
                let enabled = (obj["enabled"] as? Bool) ?? true
                let req = obj["require"] as? String
                plugins.append(CodeceptPluginInfo(name: key, enabled: enabled, requirePath: req))
            }
        }

        var includes: [CodeceptIncludeEntry] = []
        if let includeDict = json["include"] as? [String: String] {
            for (alias, relPath) in includeDict.sorted(by: { $0.key < $1.key }) {
                includes.append(CodeceptIncludeEntry(alias: alias, relativePath: relPath))
            }
        }

        var multipleSuites: [CodeceptMultipleSuiteInfo] = []
        if let multipleDict = json["multiple"] as? [String: Any] {
            for (suiteName, rawVal) in multipleDict.sorted(by: { $0.key < $1.key }) {
                guard let obj = rawVal as? [String: Any] else { continue }
                let grep = obj["grep"] as? String
                let chunks = obj["chunks"] as? Int
                var browsers: [String] = []
                if let rawBrowsers = obj["browsers"] as? [Any] {
                    for entry in rawBrowsers {
                        if let b = entry as? String, !b.isEmpty, !browsers.contains(b) {
                            browsers.append(b)
                        } else if let dict = entry as? [String: Any],
                                  let b = dict["browser"] as? String,
                                  !b.isEmpty,
                                  !browsers.contains(b) {
                            browsers.append(b)
                        }
                    }
                }
                multipleSuites.append(CodeceptMultipleSuiteInfo(
                    name: suiteName,
                    browsers: browsers,
                    chunks: chunks,
                    grep: grep
                ))
            }
        }

        let gherkin = json["gherkin"] as? [String: Any]
        let gherkinFeatures = gherkin?["features"] as? String
        let gherkinSteps = gherkin?["steps"] as? [String] ?? []

        return CodeceptConfigSummary(
            configFilePath: configURL.standardizedFileURL.path,
            isCustomConfigOverride: isCustomOverride,
            projectName: name,
            testsPattern: testsPattern,
            hasExplicitTestsPattern: parsedTestsPattern != nil,
            outputDirectory: outputDir,
            gherkinFeaturesPattern: gherkinFeatures,
            gherkinStepsPaths: gherkinSteps,
            helpers: helpers,
            plugins: plugins,
            includes: includes,
            multipleSuites: multipleSuites,
            packageCodeceptVersion: packageInfo.codeceptVersion,
            isESM: packageInfo.isESM,
            isTypeScript: false
        )
    }

    // MARK: - Heuristic & Script Discovery

    private static func looksLikeCodeceptConfig(content: String, ext: String) -> Bool {
        if ext == "json" {
            return content.contains("\"helpers\"") && (content.contains("\"tests\"") || content.contains("\"output\"") || content.contains("\"gherkin\"") || content.contains("\"multiple\""))
        }
        let hasCodeceptSignal = content.contains("CodeceptJS")
            || content.contains("@codeceptjs/")
            || content.contains("setHeadlessWhen")
            || content.contains("exports.config")
            || content.contains("export const config")
            || content.contains("export default")
        let hasHelpersKey = content.range(of: #"(?:^|[\s,{])["']?helpers["']?\s*:"#, options: .regularExpression) != nil
        let hasSecondaryKey = content.range(of: #"(?:^|[\s,{])["']?(?:tests|gherkin|include|output|plugins|multiple)["']?\s*:"#, options: .regularExpression) != nil
        return hasCodeceptSignal && hasHelpersKey && hasSecondaryKey
    }

    private static func extractConfigPathsFromPackageScripts(rootURL: URL) -> [URL] {
        let pkgURL = rootURL.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: pkgURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: String] else {
            return []
        }

        let flagRegex = try? NSRegularExpression(
            pattern: #"(?:^|\s)(?:-c|--config)(?:=|\s+)(?:"([^"]+)"|'([^']+)'|([^\s"'&|;]+))"#
        )
        guard let flagRegex else { return [] }

        var results: [URL] = []
        for (_, scriptValue) in scripts.sorted(by: { $0.key < $1.key }) {
            guard scriptValue.lowercased().contains("codecept") else { continue }
            let ns = scriptValue as NSString
            let matches = flagRegex.matches(in: scriptValue, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let rawPath: String?
                if match.range(at: 1).location != NSNotFound {
                    rawPath = ns.substring(with: match.range(at: 1))
                } else if match.range(at: 2).location != NSNotFound {
                    rawPath = ns.substring(with: match.range(at: 2))
                } else if match.range(at: 3).location != NSNotFound {
                    rawPath = ns.substring(with: match.range(at: 3))
                } else {
                    rawPath = nil
                }
                guard let rawPath, !rawPath.contains("$") else { continue }
                if let resolved = resolveConfigURL(customPath: rawPath, relativeTo: rootURL) {
                    results.append(resolved)
                }
            }
        }
        return results
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

    private static func parseMultipleSuites(from block: String) -> [CodeceptMultipleSuiteInfo] {
        guard !block.isEmpty else { return [] }
        let entries = topLevelObjectEntries(in: block)
        return entries.map { suiteName, body in
            let grep = extractStringProperty(named: "grep", in: body)
            let chunks = extractIntProperty(named: "chunks", in: body)
            let browsers = parseMultipleBrowsers(from: body)
            return CodeceptMultipleSuiteInfo(
                name: suiteName,
                browsers: browsers,
                chunks: chunks,
                grep: grep
            )
        }
    }

    private static func parseMultipleBrowsers(from suiteBody: String) -> [String] {
        guard let arrayBody = extractBracketArrayBody(named: "browsers", in: suiteBody) else {
            return []
        }
        let chars = Array(arrayBody)
        var results: [String] = []
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace || c == "," {
                i += 1
                continue
            }
            if c == "'" || c == "\"" || c == "`" {
                let quote = c
                i += 1
                var value = ""
                var escaped = false
                while i < chars.count {
                    let ch = chars[i]
                    if escaped {
                        value.append(ch)
                        escaped = false
                    } else if ch == "\\" {
                        escaped = true
                    } else if ch == quote {
                        i += 1
                        break
                    } else {
                        value.append(ch)
                    }
                    i += 1
                }
                if !value.isEmpty && !results.contains(value) {
                    results.append(value)
                }
                continue
            }
            if c == "{" {
                if let closeIdx = matchingBraceIndex(chars: chars, openIndex: i) {
                    let objBody = String(chars[(i + 1)..<closeIdx])
                    if let browserName = extractStringProperty(named: "browser", in: objBody),
                       !browserName.isEmpty,
                       !results.contains(browserName) {
                        results.append(browserName)
                    }
                    i = closeIdx + 1
                    continue
                }
            }
            i += 1
        }
        return results
    }

    private static func extractBracketArrayBody(named property: String, in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let pattern = "(?:\\b\(escaped)\\b|[\"']\(escaped)[\"'])\\s*:\\s*\\["
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let openUTF16 = match.range.location + match.range.length - 1
        guard let range = Range(NSRange(location: openUTF16, length: 1), in: text) else { return nil }
        let startIdx = text.distance(from: text.startIndex, to: range.lowerBound)
        let chars = Array(text)
        var depth = 0
        var inString: Character? = nil
        var escapedChar = false
        for idx in startIdx..<chars.count {
            let c = chars[idx]
            if let quote = inString {
                if escapedChar { escapedChar = false }
                else if c == "\\" { escapedChar = true }
                else if c == quote { inString = nil }
                continue
            }
            if c == "'" || c == "\"" || c == "`" {
                inString = c
                continue
            }
            if c == "[" { depth += 1 }
            else if c == "]" {
                depth -= 1
                if depth == 0 {
                    return String(chars[(startIdx + 1)..<idx])
                }
            }
        }
        return nil
    }

    private static func extractIntProperty(named property: String, in text: String) -> Int? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let pattern = "(?:\\b\(escaped)\\b|[\"']\(escaped)[\"'])\\s*:\\s*(\\d+)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return Int(ns.substring(with: match.range(at: 1)))
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

    // MARK: - Glob Matching for Multi-Config Test Ownership

    /// Matches a file path against a CodeceptJS `tests` or `gherkin.features` glob pattern
    /// resolved relative to `baseDirectory` (typically `dirname(configFile)`).
    public static func globMatches(pattern: String, path: String, baseDirectory: URL) -> Bool {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else { return false }
        let normalizedPattern = normalizeGlobPattern(trimmedPattern, baseDirectory: baseDirectory)
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let regexPattern = "^" + globSegmentToRegex(normalizedPattern) + "$"
        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: []) else {
            return false
        }
        let nsPath = normalizedPath as NSString
        return regex.firstMatch(in: normalizedPath, range: NSRange(location: 0, length: nsPath.length)) != nil
    }

    private static func normalizeGlobPattern(_ rawPattern: String, baseDirectory: URL) -> String {
        let replaced = rawPattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        let combined: String
        if replaced.hasPrefix("/") {
            combined = replaced
        } else {
            let basePath = baseDirectory.standardizedFileURL.path
            let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
            combined = trimmedBase + "/" + replaced
        }
        var stack: [String] = []
        for part in combined.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." {
                continue
            } else if part == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(String(part))
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    private static func globSegmentToRegex(_ pattern: String) -> String {
        let chars = Array(pattern)
        var regex = ""
        regex.reserveCapacity(chars.count * 2)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    if i + 2 < chars.count && chars[i + 2] == "/" {
                        regex += "(?:[^/]+/)*"
                        i += 3
                    } else {
                        regex += ".*"
                        i += 2
                    }
                } else {
                    regex += "[^/]*"
                    i += 1
                }
            } else if c == "?" {
                regex += "[^/]"
                i += 1
            } else if c == "{" {
                if let (alternatives, endIdx) = parseBraceGroup(chars: chars, start: i) {
                    let converted = alternatives.map { globSegmentToRegex($0) }.joined(separator: "|")
                    regex += "(?:" + converted + ")"
                    i = endIdx + 1
                } else {
                    regex += "\\{"
                    i += 1
                }
            } else if c == "[" {
                if let closeIdx = findClosingBracket(chars: chars, start: i) {
                    var inner = String(chars[(i + 1)..<closeIdx])
                    if inner.hasPrefix("!") {
                        inner = "^" + inner.dropFirst()
                    }
                    regex += "[" + inner + "]"
                    i = closeIdx + 1
                } else {
                    regex += "\\["
                    i += 1
                }
            } else if ".+()^$|\\}".contains(c) {
                regex.append("\\")
                regex.append(c)
                i += 1
            } else {
                regex.append(c)
                i += 1
            }
        }
        return regex
    }

    private static func parseBraceGroup(chars: [Character], start: Int) -> ([String], Int)? {
        guard start < chars.count, chars[start] == "{" else { return nil }
        var depth = 0
        var current = ""
        var alternatives: [String] = []
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == "{" {
                if depth > 0 { current.append(c) }
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    alternatives.append(current)
                    return (alternatives, i)
                }
                current.append(c)
            } else if c == "," && depth == 1 {
                alternatives.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        return nil
    }

    private static func findClosingBracket(chars: [Character], start: Int) -> Int? {
        var i = start + 1
        if i < chars.count && (chars[i] == "!" || chars[i] == "^") {
            i += 1
        }
        if i < chars.count && chars[i] == "]" {
            i += 1
        }
        while i < chars.count {
            if chars[i] == "]" { return i }
            i += 1
        }
        return nil
    }
}
