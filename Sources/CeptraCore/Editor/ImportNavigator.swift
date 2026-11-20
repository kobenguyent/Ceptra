import Foundation

public struct NavigationTarget: Equatable, Hashable, Sendable {
    public let fileURL: URL
    public let lineNumber: Int?
    public let displayLabel: String
    public let isSymlink: Bool

    public init(fileURL: URL, lineNumber: Int? = nil, displayLabel: String, isSymlink: Bool = false) {
        self.fileURL = fileURL
        self.lineNumber = lineNumber
        self.displayLabel = displayLabel
        self.isSymlink = isSymlink
    }
}

public struct NavigableSpan: Equatable, Sendable {
    public let range: NSRange // UTF-16 range inside the source text
    public let specifier: String
    public let target: NavigationTarget

    public init(range: NSRange, specifier: String, target: NavigationTarget) {
        self.range = range
        self.specifier = specifier
        self.target = target
    }
}

public enum ImportNavigator {
    private static let importPathPatterns: [NSRegularExpression] = [
        // import ... from './foo' | export ... from './foo'
        try! NSRegularExpression(pattern: #"\b(?:import|export)\b[^;\n]*?\bfrom\s*(['"`])([^'"`\n]+)\1"#),
        // side-effect import './foo'
        try! NSRegularExpression(pattern: #"^\s*import\s+(['"`])([^'"`\n]+)\1"#, options: [.anchorsMatchLines]),
        // require('./foo') or dynamic import('./foo')
        try! NSRegularExpression(pattern: #"\b(?:require|import)\s*\(\s*(['"`])([^'"`\n]+)\1\s*\)"#),
        // TS triple-slash reference: /// <reference path="./steps.d.ts" />
        try! NSRegularExpression(pattern: #"///\s*<reference\s+path\s*=\s*(['"])([^'"\n]+)\1"#),
        // CodeceptJS config paths: require: './helpers/x.ts', bootstrap: './boot.js', include entries, steps: ['./...']
        try! NSRegularExpression(pattern: #"(?:require|bootstrap|teardown|I|[A-Za-z_$][\w$]*)\s*:\s*(['"`])(\.\.?/[^'"`\n]+)\1"#),
        // Array of relative paths (e.g. gherkin steps: ['./step_definitions/steps.js'])
        try! NSRegularExpression(pattern: #"['"`](\.\.?/[^'"`\n]+\.(?:js|ts|mjs|cjs|mts|cts|json|feature))['"`]"#)
    ]

    private static let namedImportRegex = try! NSRegularExpression(
        pattern: #"\bimport\s+(?:type\s+)?(?:([A-Za-z_$][\w$]*)\s*(?:,\s*)?)?(?:\{\s*([^}]+)\s*\}|\*\s+as\s+([A-Za-z_$][\w$]*))?\s*from\s*(['"`])([^'"`\n]+)\4"#
    )
    private static let requireDestructureRegex = try! NSRegularExpression(
        pattern: #"\b(?:const|let|var)\s+(?:([A-Za-z_$][\w$]*)|\{\s*([^}]+)\s*\})\s*=\s*require\s*\(\s*(['"`])([^'"`\n]+)\3\s*\)"#
    )

    private static let candidateExtensions = [
        "ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts", "json", "d.ts"
    ]

    /// Finds all navigable import/require/config path spans inside `source`.
    public static func findNavigableImportSpans(
        in source: String,
        sourceFileURL: URL,
        workspaceRoot: URL,
        config: CodeceptConfigSummary? = nil
    ) -> [NavigableSpan] {
        let ns = source as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var spans: [NavigableSpan] = []
        var seenLocations = Set<Int>()

        for regex in importPathPatterns {
            for match in regex.matches(in: source, range: fullRange) {
                let specifierGroup = match.numberOfRanges >= 3 ? 2 : 1
                let specRange = match.range(at: specifierGroup)
                guard specRange.location != NSNotFound, specRange.length > 0 else { continue }
                guard seenLocations.insert(specRange.location).inserted else { continue }

                let specifier = ns.substring(with: specRange)
                if let resolved = resolveImportPath(
                    specifier: specifier,
                    fromFileURL: sourceFileURL,
                    workspaceRoot: workspaceRoot,
                    config: config
                ) {
                    spans.append(NavigableSpan(range: specRange, specifier: specifier, target: resolved))
                }
            }
        }

        return spans.sorted { $0.range.location < $1.range.location }
    }

    /// Resolves whatever is at `utf16Offset` in `source` (an import path, an imported symbol, a configured
    /// CodeceptJS `include` object/method, or a custom `I.<method>` declared in `include.I` / `steps.d.ts`).
    public static func resolveTarget(
        atUTF16Offset offset: Int,
        in source: String,
        sourceFileURL: URL,
        workspaceRoot: URL,
        config: CodeceptConfigSummary? = nil
    ) -> NavigableSpan? {
        let ns = source as NSString
        guard offset >= 0, offset <= ns.length else { return nil }

        // 1. Direct import / require / config path string under cursor
        let importSpans = findNavigableImportSpans(
            in: source,
            sourceFileURL: sourceFileURL,
            workspaceRoot: workspaceRoot,
            config: config
        )
        if let hit = importSpans.first(where: { offset >= $0.range.location && offset <= NSMaxRange($0.range) }) {
            return hit
        }

        // 2. Identifier under cursor -> imported symbol, include PageObject, or I.<customStep>
        guard let wordInfo = identifierAt(offset: offset, in: ns) else {
            return nil
        }

        // Check `receiver.member` (e.g. `I.getUserById` or `loginPage.submit`)
        let receiver = precedingReceiver(before: wordInfo.range.location, in: ns)

        // 2a. Check explicit ES / CJS imports in current file
        let importedBindings = parseImportedBindings(in: source)
        if let binding = importedBindings[wordInfo.word] {
            if let resolved = resolveImportPath(
                specifier: binding.specifier,
                fromFileURL: sourceFileURL,
                workspaceRoot: workspaceRoot,
                config: config
            ) {
                let line = findSymbolDeclarationLine(named: binding.exportedName, in: resolved.fileURL)
                let target = NavigationTarget(
                    fileURL: resolved.fileURL,
                    lineNumber: line ?? resolved.lineNumber,
                    displayLabel: resolved.displayLabel,
                    isSymlink: resolved.isSymlink
                )
                return NavigableSpan(range: wordInfo.range, specifier: wordInfo.word, target: target)
            }
        }

        // 2b. Check receiver.member where receiver is an imported namespace/default OR CodeceptJS `include` object
        if let receiver {
            // Imported object member (e.g., `homePage.open`)
            if let binding = importedBindings[receiver],
               let resolved = resolveImportPath(
                   specifier: binding.specifier,
                   fromFileURL: sourceFileURL,
                   workspaceRoot: workspaceRoot,
                   config: config
               ) {
                let line = findSymbolDeclarationLine(named: wordInfo.word, in: resolved.fileURL)
                let target = NavigationTarget(
                    fileURL: resolved.fileURL,
                    lineNumber: line ?? 1,
                    displayLabel: "\(resolved.displayLabel):\(line ?? 1)",
                    isSymlink: resolved.isSymlink
                )
                return NavigableSpan(range: wordInfo.range, specifier: "\(receiver).\(wordInfo.word)", target: target)
            }

            // CodeceptJS `include` entry member (e.g., `I.customStep` or `loginPage.login`)
            if let config {
                let testRoot = config.resolvedTestRootURL(workspaceRoot: workspaceRoot)
                if let inc = config.includes.first(where: { $0.alias == receiver }),
                   let resolved = resolveImportPath(
                       specifier: inc.relativePath,
                       fromFileURL: testRoot.appendingPathComponent("_anchor.js"),
                       workspaceRoot: workspaceRoot,
                       config: config
                   ) {
                    if let line = findSymbolDeclarationLine(named: wordInfo.word, in: resolved.fileURL) {
                        let target = NavigationTarget(
                            fileURL: resolved.fileURL,
                            lineNumber: line,
                            displayLabel: "\(resolved.displayLabel):\(line)",
                            isSymlink: resolved.isSymlink
                        )
                        return NavigableSpan(range: wordInfo.range, specifier: "\(receiver).\(wordInfo.word)", target: target)
                    }
                }

                // Fallback for `I.<action>` -> jump to `steps.d.ts` or custom helpers if declared there
                if receiver == "I" {
                    for candidate in customStepDefinitionFiles(workspaceRoot: workspaceRoot, config: config) {
                        if let line = findSymbolDeclarationLine(named: wordInfo.word, in: candidate) {
                            let label = relativeDisplay(candidate, to: workspaceRoot)
                            let target = NavigationTarget(
                                fileURL: candidate,
                                lineNumber: line,
                                displayLabel: "\(label):\(line)",
                                isSymlink: isSymlinkPath(candidate)
                            )
                            return NavigableSpan(range: wordInfo.range, specifier: "I.\(wordInfo.word)", target: target)
                        }
                    }
                }
            }
        }

        // 2c. Direct CodeceptJS `include` alias under cursor (e.g., Cmd+Click on `loginPage` in `async ({ I, loginPage })`)
        if let config {
            let testRoot = config.resolvedTestRootURL(workspaceRoot: workspaceRoot)
            if let inc = config.includes.first(where: { $0.alias == wordInfo.word }),
               let resolved = resolveImportPath(
                   specifier: inc.relativePath,
                   fromFileURL: testRoot.appendingPathComponent("_anchor.js"),
                   workspaceRoot: workspaceRoot,
                   config: config
               ) {
                return NavigableSpan(range: wordInfo.range, specifier: wordInfo.word, target: resolved)
            }
        }

        return nil
    }

    /// Resolves an import/require specifier (relative, tsconfig path alias, or `node_modules` package)
    /// into a real file URL on disk, transparently handling TypeScript `.js -> .ts` mapping, index files,
    /// and filesystem symlinks.
    public static func resolveImportPath(
        specifier: String,
        fromFileURL: URL,
        workspaceRoot: URL,
        config: CodeceptConfigSummary? = nil
    ) -> NavigationTarget? {
        let trimmed = specifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("http://"), !trimmed.hasPrefix("https://"), !trimmed.hasPrefix("node:") else {
            return nil
        }

        let baseDir = fromFileURL.deletingLastPathComponent()

        // 1. Relative or absolute path
        if trimmed.hasPrefix("./") || trimmed.hasPrefix("../") || trimmed.hasPrefix("/") {
            let baseCandidate = trimmed.hasPrefix("/")
                ? URL(fileURLWithPath: trimmed)
                : baseDir.appendingPathComponent(trimmed)
            if let hit = resolveFileCandidate(baseCandidate) {
                return makeTarget(hit, workspaceRoot: workspaceRoot)
            }
            // Fallback relative to testRoot if config lives in a nested dir
            if let config {
                let testRoot = config.resolvedTestRootURL(workspaceRoot: workspaceRoot)
                if let hit = resolveFileCandidate(testRoot.appendingPathComponent(trimmed)) {
                    return makeTarget(hit, workspaceRoot: workspaceRoot)
                }
            }
            return nil
        }

        // 2. tsconfig.json / jsconfig.json path aliases (e.g. @pages/* -> src/pages/*)
        if let aliased = resolveViaTSConfigPaths(specifier: trimmed, workspaceRoot: workspaceRoot) {
            return makeTarget(aliased, workspaceRoot: workspaceRoot)
        }

        // 3. node_modules resolution (package entry or subpath)
        if let pkgHit = resolveViaNodeModules(specifier: trimmed, startDir: baseDir, stopAt: workspaceRoot) {
            return makeTarget(pkgHit, workspaceRoot: workspaceRoot)
        }

        return nil
    }

    // MARK: - Candidate Resolution Helpers

    private static func resolveFileCandidate(_ rawURL: URL) -> URL? {
        let fm = FileManager.default
        let std = rawURL.standardizedFileURL

        // 1. Exact regular file (or symlink to regular file)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: std.path, isDirectory: &isDir), !isDir.boolValue {
            return std
        }

        // 2. TypeScript ESM convention: import './foo.js' when actual source is './foo.ts' / './foo.tsx'
        let ext = std.pathExtension.lowercased()
        let tsMappings: [String: [String]] = [
            "js": ["ts", "tsx", "d.ts"],
            "jsx": ["tsx", "ts"],
            "mjs": ["mts", "ts"],
            "cjs": ["cts", "ts"]
        ]
        if let alternates = tsMappings[ext] {
            let stem = std.deletingPathExtension()
            for alt in alternates {
                let candidate = stem.appendingPathExtension(alt)
                var altDir: ObjCBool = false
                if fm.fileExists(atPath: candidate.path, isDirectory: &altDir), !altDir.boolValue {
                    return candidate
                }
            }
        }

        // 3. Extensionless import -> try common JS/TS/JSON extensions
        if ext.isEmpty || !candidateExtensions.contains(ext) {
            for tryExt in candidateExtensions {
                let candidate = URL(fileURLWithPath: std.path + "." + tryExt)
                var cDir: ObjCBool = false
                if fm.fileExists(atPath: candidate.path, isDirectory: &cDir), !cDir.boolValue {
                    return candidate
                }
            }
        }

        // 4. Directory import -> index.{ts,tsx,js,jsx,mjs,cjs,d.ts}
        if fm.fileExists(atPath: std.path, isDirectory: &isDir), isDir.boolValue {
            for tryExt in ["ts", "tsx", "js", "jsx", "mjs", "cjs", "d.ts"] {
                let idxFile = std.appendingPathComponent("index.\(tryExt)")
                if fm.fileExists(atPath: idxFile.path) {
                    return idxFile
                }
            }
        }

        return nil
    }

    private static func resolveViaTSConfigPaths(specifier: String, workspaceRoot: URL) -> URL? {
        for name in ["tsconfig.json", "jsconfig.json"] {
            let cfgURL = workspaceRoot.appendingPathComponent(name)
            guard let raw = try? String(contentsOf: cfgURL, encoding: .utf8) else { continue }
            let stripped = ConfigParser.stripJSComments(from: raw)
            guard let data = stripped.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let opts = json["compilerOptions"] as? [String: Any] else { continue }

            let baseUrlStr = (opts["baseUrl"] as? String) ?? "."
            let baseURL = workspaceRoot.appendingPathComponent(baseUrlStr, isDirectory: true).standardizedFileURL

            if let paths = opts["paths"] as? [String: [String]] {
                for (pattern, replacements) in paths {
                    if pattern.hasSuffix("*"), let starIdx = pattern.firstIndex(of: "*") {
                        let prefix = String(pattern[..<starIdx])
                        if specifier.hasPrefix(prefix) {
                            let suffix = String(specifier.dropFirst(prefix.count))
                            for replacement in replacements {
                                let mapped = replacement.replacingOccurrences(of: "*", with: suffix)
                                if let hit = resolveFileCandidate(baseURL.appendingPathComponent(mapped)) {
                                    return hit
                                }
                            }
                        }
                    } else if pattern == specifier {
                        for replacement in replacements {
                            if let hit = resolveFileCandidate(baseURL.appendingPathComponent(replacement)) {
                                return hit
                            }
                        }
                    }
                }
            }

            if opts["baseUrl"] != nil,
               let hit = resolveFileCandidate(baseURL.appendingPathComponent(specifier)) {
                return hit
            }
        }
        return nil
    }

    private static func resolveViaNodeModules(specifier: String, startDir: URL, stopAt workspaceRoot: URL) -> URL? {
        var current = startDir.standardizedFileURL
        let stopPath = workspaceRoot.standardizedFileURL.path

        for _ in 0..<8 {
            let nmDir = current.appendingPathComponent("node_modules", isDirectory: true)
            let direct = nmDir.appendingPathComponent(specifier)
            if let hit = resolveFileCandidate(direct) {
                return hit
            }
            let pkgJSON = direct.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: pkgJSON),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for key in ["types", "typings", "module", "main"] {
                    if let entry = json[key] as? String,
                       let hit = resolveFileCandidate(direct.appendingPathComponent(entry)) {
                        return hit
                    }
                }
                return pkgJSON
            }
            if current.path == stopPath || current.path == "/" { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    private static func makeTarget(_ url: URL, workspaceRoot: URL) -> NavigationTarget {
        let symlink = isSymlinkPath(url)
        let resolved = symlink ? url.resolvingSymlinksInPath() : url.standardizedFileURL
        return NavigationTarget(
            fileURL: resolved,
            lineNumber: nil,
            displayLabel: relativeDisplay(resolved, to: workspaceRoot),
            isSymlink: symlink
        )
    }

    private static func isSymlinkPath(_ url: URL) -> Bool {
        let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return vals?.isSymbolicLink == true
    }

    private static func relativeDisplay(_ url: URL, to workspaceRoot: URL) -> String {
        let p = url.standardizedFileURL.path
        let root = workspaceRoot.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : url.lastPathComponent
    }

    // MARK: - Symbol & Binding Helpers

    private struct ImportedBinding {
        let localName: String
        let exportedName: String
        let specifier: String
    }

    private static func parseImportedBindings(in source: String) -> [String: ImportedBinding] {
        let ns = source as NSString
        let full = NSRange(location: 0, length: ns.length)
        var map: [String: ImportedBinding] = [:]

        for match in namedImportRegex.matches(in: source, range: full) {
            let specifier = ns.substring(with: match.range(at: 5))
            if match.range(at: 1).location != NSNotFound {
                let def = ns.substring(with: match.range(at: 1))
                map[def] = ImportedBinding(localName: def, exportedName: def, specifier: specifier)
            }
            if match.range(at: 2).location != NSNotFound {
                let list = ns.substring(with: match.range(at: 2))
                for item in list.split(separator: ",") {
                    let parts = item.trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: " as ")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    guard let first = parts.first, !first.isEmpty else { continue }
                    let local = parts.count > 1 ? parts[1] : first
                    map[local] = ImportedBinding(localName: local, exportedName: first, specifier: specifier)
                }
            }
            if match.range(at: 3).location != NSNotFound {
                let nsAlias = ns.substring(with: match.range(at: 3))
                map[nsAlias] = ImportedBinding(localName: nsAlias, exportedName: nsAlias, specifier: specifier)
            }
        }

        for match in requireDestructureRegex.matches(in: source, range: full) {
            let specifier = ns.substring(with: match.range(at: 4))
            if match.range(at: 1).location != NSNotFound {
                let def = ns.substring(with: match.range(at: 1))
                map[def] = ImportedBinding(localName: def, exportedName: def, specifier: specifier)
            }
            if match.range(at: 2).location != NSNotFound {
                let list = ns.substring(with: match.range(at: 2))
                for item in list.split(separator: ",") {
                    let parts = item.trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: ":")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    guard let first = parts.first, !first.isEmpty else { continue }
                    let local = parts.count > 1 ? parts[1] : first
                    map[local] = ImportedBinding(localName: local, exportedName: first, specifier: specifier)
                }
            }
        }

        return map
    }

    private static func identifierAt(offset: Int, in ns: NSString) -> (word: String, range: NSRange)? {
        guard ns.length > 0 else { return nil }
        let clamped = min(max(0, offset), ns.length - 1)

        func isIdent(_ unit: unichar) -> Bool {
            (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit == 36
        }

        var idx = clamped
        if !isIdent(ns.character(at: idx)) {
            if idx > 0 && isIdent(ns.character(at: idx - 1)) {
                idx -= 1
            } else {
                return nil
            }
        }

        var start = idx
        while start > 0 && isIdent(ns.character(at: start - 1)) {
            start -= 1
        }
        var end = idx + 1
        while end < ns.length && isIdent(ns.character(at: end)) {
            end += 1
        }

        let range = NSRange(location: start, length: end - start)
        let word = ns.substring(with: range)
        guard !word.isEmpty, !(word.first?.isNumber ?? false) else { return nil }
        return (word, range)
    }

    private static func precedingReceiver(before identStart: Int, in ns: NSString) -> String? {
        var i = identStart - 1
        while i >= 0 && (ns.character(at: i) == 32 || ns.character(at: i) == 9) { i -= 1 }
        guard i >= 0, ns.character(at: i) == 46 else { return nil } // '.'
        i -= 1
        while i >= 0 && (ns.character(at: i) == 32 || ns.character(at: i) == 9) { i -= 1 }
        guard i >= 0 else { return nil }

        // Support `I.retry(2).see` -> unwrap `.retry(...)`
        if ns.character(at: i) == 41 { // ')'
            var depth = 0
            while i >= 0 {
                let ch = ns.character(at: i)
                if ch == 41 { depth += 1 }
                else if ch == 40 { depth -= 1; if depth == 0 { i -= 1; break } }
                i -= 1
            }
            // skip `retry` and `.`
            while i >= 0 && ns.character(at: i) != 46 { i -= 1 }
            i -= 1
        }

        guard i >= 0, let info = identifierAt(offset: i, in: ns) else { return nil }
        return info.word
    }

    private static func customStepDefinitionFiles(workspaceRoot: URL, config: CodeceptConfigSummary) -> [URL] {
        var urls: [URL] = []
        let testRoot = config.resolvedTestRootURL(workspaceRoot: workspaceRoot)
        for helper in config.helpers {
            if let req = helper.requirePath,
               let resolved = resolveImportPath(specifier: req, fromFileURL: testRoot.appendingPathComponent("_a.js"), workspaceRoot: workspaceRoot, config: config) {
                urls.append(resolved.fileURL)
            }
        }
        for candidate in [testRoot.appendingPathComponent("steps.d.ts"), workspaceRoot.appendingPathComponent("steps.d.ts")] {
            if FileManager.default.fileExists(atPath: candidate.path), !urls.contains(candidate) {
                urls.append(candidate)
            }
        }
        return urls
    }

    public static func findSymbolDeclarationLine(named symbol: String, in fileURL: URL) -> Int? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: symbol)
        let patterns = [
            #"\b(?:export\s+)?(?:async\s+)?function\s+"# + escaped + #"\b"#,
            #"\b(?:export\s+)?(?:const|let|var|class|interface|type|enum)\s+"# + escaped + #"\b"#,
            #"^\s*(?:public\s+|private\s+|protected\s+)?(?:async\s+)?"# + escaped + #"\s*(?:<[^>]*>)?\s*\("#,
            #"^\s*["']?"# + escaped + #"["']?\s*:\s*(?:async\s*)?(?:\(|function|\{|\[)"#
        ]
        let compiled = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
        let lines = content.components(separatedBy: .newlines)
        for (idx, line) in lines.enumerated() {
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            for regex in compiled where regex.firstMatch(in: line, range: range) != nil {
                return idx + 1
            }
        }
        return nil
    }
}
