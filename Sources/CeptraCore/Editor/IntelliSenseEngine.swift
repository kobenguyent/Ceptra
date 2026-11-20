import Foundation

public enum CompletionKind: String, Equatable, Hashable, Sendable {
    case action      // I.* CodeceptJS action
    case method      // PageObject / custom method
    case dsl         // Feature, Scenario, Before, retryTo...
    case keyword     // async, await, import, Given, When, Then...
    case tag         // @smoke, @api...
    case path        // ./pages/HomePage.js
    case symbol      // local or imported identifier

    public var badgeLetter: String {
        switch self {
        case .action: return "I"
        case .method: return "M"
        case .dsl: return "D"
        case .keyword: return "K"
        case .tag: return "@"
        case .path: return "P"
        case .symbol: return "V"
        }
    }
}

public struct CompletionItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let insertText: String
    public let signature: String
    public let detail: String
    public let kind: CompletionKind
    public let cursorBackOffset: Int

    public init(
        label: String,
        insertText: String? = nil,
        signature: String = "",
        detail: String = "",
        kind: CompletionKind,
        cursorBackOffset: Int = 0
    ) {
        self.id = "\(kind.rawValue):\(label):\(detail)"
        self.label = label
        self.insertText = insertText ?? label
        self.signature = signature
        self.detail = detail
        self.kind = kind
        self.cursorBackOffset = cursorBackOffset
    }
}

public struct CompletionResult: Equatable, Sendable {
    public let replacementRange: NSRange // UTF-16 range of prefix being replaced
    public let items: [CompletionItem]

    public init(replacementRange: NSRange, items: [CompletionItem]) {
        self.replacementRange = replacementRange
        self.items = items
    }
}

public struct WorkspaceCompletionIndex: Equatable, Sendable {
    public let customActorMethods: [CompletionItem]
    public let memberMethodsByAlias: [String: [CompletionItem]]
    public let workspaceTags: [String]
    public let relativeFilePaths: [String]
    public let gherkinSteps: [String]

    public init(
        customActorMethods: [CompletionItem] = [],
        memberMethodsByAlias: [String: [CompletionItem]] = [:],
        workspaceTags: [String] = [],
        relativeFilePaths: [String] = [],
        gherkinSteps: [String] = []
    ) {
        self.customActorMethods = customActorMethods
        self.memberMethodsByAlias = memberMethodsByAlias
        self.workspaceTags = workspaceTags
        self.relativeFilePaths = relativeFilePaths
        self.gherkinSteps = gherkinSteps
    }
}

public enum IntelliSenseEngine {
    // MARK: - Build Workspace Index (steps.d.ts, include objects, helpers, tags, files)

    public static func buildWorkspaceIndex(workspace: CodeceptWorkspace) -> WorkspaceCompletionIndex {
        let testRoot = workspace.config.resolvedTestRootURL(workspaceRoot: workspace.rootURL)
        var customActorItems: [CompletionItem] = []
        var seenActorNames = Set<String>()
        var memberMap: [String: [CompletionItem]] = [:]

        // 1. Parse steps.d.ts for generated CodeceptJS I.* methods
        for dtsURL in [testRoot.appendingPathComponent("steps.d.ts"), workspace.rootURL.appendingPathComponent("steps.d.ts")] {
            if let content = try? String(contentsOf: dtsURL, encoding: .utf8) {
                for method in extractMethodSignatures(from: content, sourceLabel: "steps.d.ts", kind: .action) {
                    if seenActorNames.insert(method.label).inserted {
                        customActorItems.append(method)
                    }
                }
            }
        }

        // 2. Parse `include` actor (`I`) & PageObjects / StepObjects
        for inc in workspace.config.includes {
            if let resolved = ImportNavigator.resolveImportPath(
                specifier: inc.relativePath,
                fromFileURL: testRoot.appendingPathComponent("_anchor.js"),
                workspaceRoot: workspace.rootURL,
                config: workspace.config
            ), let content = try? String(contentsOf: resolved.fileURL, encoding: .utf8) {
                let methods = extractMethodSignatures(from: content, sourceLabel: resolved.fileURL.lastPathComponent, kind: inc.alias == "I" ? .action : .method)
                if inc.alias == "I" {
                    for m in methods where seenActorNames.insert(m.label).inserted {
                        customActorItems.append(m)
                    }
                } else {
                    memberMap[inc.alias] = methods
                }
            }
        }

        // 3. Parse custom helper files (`helpers.*.require`)
        for helper in workspace.config.helpers {
            guard let req = helper.requirePath else { continue }
            if let resolved = ImportNavigator.resolveImportPath(
                specifier: req,
                fromFileURL: testRoot.appendingPathComponent("_anchor.js"),
                workspaceRoot: workspace.rootURL,
                config: workspace.config
            ), let content = try? String(contentsOf: resolved.fileURL, encoding: .utf8) {
                for m in extractMethodSignatures(from: content, sourceLabel: helper.name, kind: .action) {
                    if !m.label.hasPrefix("_") && seenActorNames.insert(m.label).inserted {
                        customActorItems.append(m)
                    }
                }
            }
        }

        // 4. Parse Gherkin step definitions (`Given('...', ...)`)
        var gherkinSteps: [String] = []
        let bddRegex = try? NSRegularExpression(pattern: #"\b(?:Given|When|Then)\s*\(\s*(['"`])([^'"`\n]+)\1"#)
        for file in workspace.files where file.category == .stepDefinition {
            if let content = try? String(contentsOf: file.url, encoding: .utf8), let regex = bddRegex {
                let ns = content as NSString
                for m in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
                    gherkinSteps.append(ns.substring(with: m.range(at: 2)))
                }
            }
        }

        return WorkspaceCompletionIndex(
            customActorMethods: customActorItems.sorted { $0.label < $1.label },
            memberMethodsByAlias: memberMap,
            workspaceTags: workspace.allTags,
            relativeFilePaths: workspace.files.map(\.relativePath),
            gherkinSteps: Array(Set(gherkinSteps)).sorted()
        )
    }

    // MARK: - Contextual Completion Query

    public static func completions(
        in source: String,
        cursorUTF16Offset: Int,
        language: String,
        sourceFileURL: URL?,
        workspace: CodeceptWorkspace?,
        index: WorkspaceCompletionIndex
    ) -> CompletionResult? {
        let ns = source as NSString
        guard cursorUTF16Offset >= 0, cursorUTF16Offset <= ns.length else { return nil }

        let lineRange = ns.lineRange(for: NSRange(location: cursorUTF16Offset, length: 0))
        let prefixRange = NSRange(location: lineRange.location, length: cursorUTF16Offset - lineRange.location)
        let linePrefix = ns.substring(with: prefixRange)

        // 1. Gherkin completions
        if language == "gherkin" {
            return gherkinCompletions(linePrefix: linePrefix, cursorOffset: cursorUTF16Offset, index: index)
        }

        // 2. Import / require path completion inside quotes: from './... or require('./...
        if let importMatch = matchImportStringPrefix(linePrefix) {
            let typed = importMatch.typedPath
            let replaceRange = NSRange(location: cursorUTF16Offset - (typed as NSString).length, length: (typed as NSString).length)
            let candidates = relativeImportSuggestions(
                typed: typed,
                sourceFileURL: sourceFileURL,
                workspace: workspace
            )
            return candidates.isEmpty ? nil : CompletionResult(replacementRange: replaceRange, items: candidates)
        }

        // 3. Tag completion after `@` (e.g. inside Scenario('... @sm'))
        if let tagPrefix = matchTrailingRegex(#"(@[A-Za-z0-9_:-]*)$"#, in: linePrefix) {
            let replaceRange = NSRange(location: cursorUTF16Offset - (tagPrefix as NSString).length, length: (tagPrefix as NSString).length)
            let lower = tagPrefix.lowercased()
            let pool = Array(Set(index.workspaceTags + ["@smoke", "@e2e", "@api", "@regression", "@slow", "@wip"])).sorted()
            let matches = pool
                .filter { $0.lowercased().hasPrefix(lower) }
                .map { CompletionItem(label: $0, insertText: $0, signature: "", detail: "CodeceptJS tag", kind: .tag) }
            return matches.isEmpty ? nil : CompletionResult(replacementRange: replaceRange, items: matches)
        }

        // 4. Member access after `I.` / `I.retry(...).` / `<alias>.`
        if let memberMatch = matchMemberAccess(linePrefix) {
            let receiver = memberMatch.receiver
            let typed = memberMatch.memberPrefix
            let replaceRange = NSRange(location: cursorUTF16Offset - (typed as NSString).length, length: (typed as NSString).length)

            var pool: [CompletionItem] = []
            if receiver == "I" {
                pool.append(contentsOf: index.customActorMethods)
                let customNames = Set(index.customActorMethods.map(\.label))
                pool.append(contentsOf: builtInActorActions.filter { !customNames.contains($0.label) })
            } else if receiver == "Scenario" {
                pool = [
                    CompletionItem(label: "only", insertText: "only('', async ({ I }) => {\n  \n});", signature: "(title, fn)", detail: "Run only this scenario", kind: .dsl, cursorBackOffset: 24),
                    CompletionItem(label: "skip", insertText: "skip('', async ({ I }) => {\n  \n});", signature: "(title, fn)", detail: "Skip scenario", kind: .dsl, cursorBackOffset: 24),
                    CompletionItem(label: "todo", insertText: "todo('');", signature: "(title)", detail: "Pending todo scenario", kind: .dsl, cursorBackOffset: 3),
                    CompletionItem(label: "tag", insertText: "tag('@smoke')", signature: "(tag)", detail: "Attach tag", kind: .dsl, cursorBackOffset: 2)
                ]
            } else if let aliasMembers = index.memberMethodsByAlias[receiver] {
                pool = aliasMembers
            } else if let sourceFileURL, let workspace {
                // Dynamically inspect an imported file for `receiver.<member>`
                if let span = ImportNavigator.resolveTarget(
                    atUTF16Offset: max(0, cursorUTF16Offset - (typed as NSString).length - 2),
                    in: source,
                    sourceFileURL: sourceFileURL,
                    workspaceRoot: workspace.rootURL,
                    config: workspace.config
                ), let fileText = try? String(contentsOf: span.target.fileURL, encoding: .utf8) {
                    pool = extractMethodSignatures(from: fileText, sourceLabel: span.target.fileURL.lastPathComponent, kind: .method)
                }
            }

            let ranked = rankAndFilter(pool, prefix: typed)
            return ranked.isEmpty ? nil : CompletionResult(replacementRange: replaceRange, items: ranked)
        }

        // 5. General identifier / CodeceptJS DSL / Keywords / Local symbols
        guard let wordPrefix = matchTrailingRegex(#"([A-Za-z_$][\w$]*)$"#, in: linePrefix), !wordPrefix.isEmpty else {
            return nil
        }

        let replaceRange = NSRange(location: cursorUTF16Offset - (wordPrefix as NSString).length, length: (wordPrefix as NSString).length)
        var pool: [CompletionItem] = builtInDSLItems + jsKeywordItems

        // Configured include aliases (`I`, `homePage`, `loginPage`, etc.)
        if let includes = workspace?.config.includes {
            for inc in includes {
                pool.append(CompletionItem(
                    label: inc.alias,
                    insertText: inc.alias,
                    signature: "",
                    detail: "include: \(inc.relativePath)",
                    kind: .symbol
                ))
            }
        }

        // Local identifiers in current file
        let existingLabels = Set(pool.map(\.label))
        for local in extractLocalIdentifiers(from: source) where !existingLabels.contains(local) && local != wordPrefix {
            pool.append(CompletionItem(label: local, insertText: local, signature: "", detail: "local symbol", kind: .symbol))
        }

        let ranked = rankAndFilter(pool, prefix: wordPrefix)
        return ranked.isEmpty ? nil : CompletionResult(replacementRange: replaceRange, items: ranked)
    }

    // MARK: - Gherkin Completions

    private static func gherkinCompletions(
        linePrefix: String,
        cursorOffset: Int,
        index: WorkspaceCompletionIndex
    ) -> CompletionResult? {
        if let tagPrefix = matchTrailingRegex(#"(@[A-Za-z0-9_:-]*)$"#, in: linePrefix) {
            let replaceRange = NSRange(location: cursorOffset - (tagPrefix as NSString).length, length: (tagPrefix as NSString).length)
            let pool = Array(Set(index.workspaceTags + ["@smoke", "@e2e", "@regression"])).sorted()
            let items = pool
                .filter { $0.lowercased().hasPrefix(tagPrefix.lowercased()) }
                .map { CompletionItem(label: $0, detail: "Gherkin tag", kind: .tag) }
            return items.isEmpty ? nil : CompletionResult(replacementRange: replaceRange, items: items)
        }

        // Step completion after `Given ` / `When ` / `Then ` / `And `
        if let stepPrefix = matchTrailingRegex(#"(?:Given|When|Then|And|But)\s+(.+)$"#, in: linePrefix) {
            let replaceRange = NSRange(location: cursorOffset - (stepPrefix as NSString).length, length: (stepPrefix as NSString).length)
            let items = index.gherkinSteps
                .filter { $0.lowercased().contains(stepPrefix.lowercased()) }
                .prefix(20)
                .map { CompletionItem(label: $0, insertText: $0, detail: "Step definition", kind: .action) }
            return items.isEmpty ? nil : CompletionResult(replacementRange: replaceRange, items: Array(items))
        }

        let trimmed = linePrefix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let replaceRange = NSRange(location: cursorOffset - (trimmed as NSString).length, length: (trimmed as NSString).length)
        let keywords = [
            CompletionItem(label: "Feature:", insertText: "Feature: ", detail: "Gherkin feature header", kind: .dsl),
            CompletionItem(label: "Background:", insertText: "Background:\n  Given ", detail: "Shared setup steps", kind: .dsl),
            CompletionItem(label: "Scenario:", insertText: "Scenario: ", detail: "Gherkin scenario", kind: .dsl),
            CompletionItem(label: "Scenario Outline:", insertText: "Scenario Outline: ", detail: "Parameterized scenario", kind: .dsl),
            CompletionItem(label: "Examples:", insertText: "Examples:\n  | param |\n  | value |", detail: "Scenario outline data", kind: .dsl),
            CompletionItem(label: "Given", insertText: "Given ", detail: "Precondition step", kind: .keyword),
            CompletionItem(label: "When", insertText: "When ", detail: "Action step", kind: .keyword),
            CompletionItem(label: "Then", insertText: "Then ", detail: "Assertion step", kind: .keyword),
            CompletionItem(label: "And", insertText: "And ", detail: "Additional step", kind: .keyword),
            CompletionItem(label: "But", insertText: "But ", detail: "Negative step", kind: .keyword)
        ]
        let ranked = rankAndFilter(keywords, prefix: trimmed)
        return ranked.isEmpty ? nil : CompletionResult(replacementRange: replaceRange, items: ranked)
    }

    // MARK: - Helpers

    private static func rankAndFilter(_ items: [CompletionItem], prefix: String) -> [CompletionItem] {
        let lower = prefix.lowercased()
        let filtered: [CompletionItem]
        if lower.isEmpty {
            filtered = items
        } else {
            filtered = items.filter { item in
                let target = item.label.lowercased()
                return target.hasPrefix(lower) || target.contains(lower)
            }
        }
        return filtered
            .sorted { lhs, rhs in
                let lPref = lhs.label.lowercased().hasPrefix(lower)
                let rPref = rhs.label.lowercased().hasPrefix(lower)
                if lPref != rPref { return lPref }
                if lhs.kind != rhs.kind { return kindPriority(lhs.kind) < kindPriority(rhs.kind) }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            .prefix(28)
            .map { $0 }
    }

    private static func kindPriority(_ kind: CompletionKind) -> Int {
        switch kind {
        case .action: return 0
        case .method: return 1
        case .dsl: return 2
        case .symbol: return 3
        case .path: return 4
        case .tag: return 5
        case .keyword: return 6
        }
    }

    private static func matchImportStringPrefix(_ linePrefix: String) -> (typedPath: String, quote: String)? {
        let patterns = [
            #"(?:from|import)\s+(['"`])([^'"`]*)$"#,
            #"(?:require|import)\s*\(\s*(['"`])([^'"`]*)$"#
        ]
        let ns = linePrefix as NSString
        let range = NSRange(location: 0, length: ns.length)
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let m = regex.firstMatch(in: linePrefix, range: range) {
                let quote = ns.substring(with: m.range(at: 1))
                let typed = ns.substring(with: m.range(at: 2))
                return (typed, quote)
            }
        }
        return nil
    }

    private static func relativeImportSuggestions(
        typed: String,
        sourceFileURL: URL?,
        workspace: CodeceptWorkspace?
    ) -> [CompletionItem] {
        guard let sourceFileURL, let workspace else { return [] }
        let sourceDir = sourceFileURL.deletingLastPathComponent().standardizedFileURL
        let lower = typed.lowercased()

        var items: [CompletionItem] = []
        for file in workspace.files where file.path != sourceFileURL.standardizedFileURL.path {
            let rel = relativePath(from: sourceDir, to: file.url.standardizedFileURL)
            if lower.isEmpty || rel.lowercased().contains(lower) {
                items.append(CompletionItem(
                    label: rel,
                    insertText: rel,
                    signature: "",
                    detail: file.category.displayTitle,
                    kind: .path
                ))
            }
        }
        return Array(items.sorted { $0.label < $1.label }.prefix(24))
    }

    private static func relativePath(from baseDir: URL, to targetFile: URL) -> String {
        let baseParts = baseDir.pathComponents
        let targetParts = targetFile.pathComponents
        var common = 0
        while common < baseParts.count && common < targetParts.count && baseParts[common] == targetParts[common] {
            common += 1
        }
        let upCount = baseParts.count - common
        var parts = Array(repeating: "..", count: upCount)
        parts.append(contentsOf: targetParts[common...])
        let joined = parts.joined(separator: "/")
        return joined.hasPrefix("..") ? joined : "./\(joined)"
    }

    private static func matchMemberAccess(_ linePrefix: String) -> (receiver: String, memberPrefix: String)? {
        // Supports `I.click`, `I.retry(2).see`, `loginPage.sub`
        let pattern = #"([A-Za-z_$][\w$]*)(?:\.retry\s*\([^)]*\))?\.([A-Za-z_$][\w$]*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = linePrefix as NSString
        guard let m = regex.firstMatch(in: linePrefix, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let receiver = ns.substring(with: m.range(at: 1))
        let member = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
        return (receiver, member)
    }

    private static func matchTrailingRegex(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func extractMethodSignatures(
        from content: String,
        sourceLabel: String,
        kind: CompletionKind
    ) -> [CompletionItem] {
        let patterns = [
            // TS / JS class/object methods & .d.ts methods: `async click(locator: string)` or `getUserById(id: number)`
            #"^\s*(?:public\s+|export\s+)?(?:async\s+)?([A-Za-z_$][\w$]*)\s*\(([^)\n]{0,80})\)\s*(?::\s*([^\{;\n]{1,40}))?\s*(?:\{|;)"#,
            // Object arrow method: `login: async (email, pass) =>`
            #"^\s*([A-Za-z_$][\w$]*)\s*:\s*(?:async\s*)?\(([^)\n]{0,80})\)\s*=>"#,
            // Named exported function: `export async function sendLogin(user)`
            #"^\s*export\s+(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\s*\(([^)\n]{0,80})\)"#
        ]
        let ignored: Set<String> = ["if", "for", "while", "switch", "catch", "constructor", "return", "function", "Scenario", "Feature", "Before", "After"]
        var results: [CompletionItem] = []
        var seen = Set<String>()

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            let ns = content as NSString
            for match in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: match.range(at: 1))
                guard !ignored.contains(name), seen.insert(name).inserted else { continue }
                let params = match.range(at: 2).location != NSNotFound
                    ? ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    : ""
                let hasParams = !params.isEmpty
                results.append(CompletionItem(
                    label: name,
                    insertText: "\(name)()",
                    signature: "(\(params))",
                    detail: sourceLabel,
                    kind: kind,
                    cursorBackOffset: hasParams ? 1 : 0
                ))
            }
        }
        return results
    }

    private static func extractLocalIdentifiers(from source: String) -> [String] {
        let pattern = #"\b(?:const|let|var|function|class)\s+([A-Za-z_$][\w$]*)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        var out = Set<String>()
        for m in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            out.insert(ns.substring(with: m.range(at: 1)))
        }
        return Array(out).sorted()
    }

    // MARK: - Curated CodeceptJS 4.x Catalog

    public static let builtInDSLItems: [CompletionItem] = [
        CompletionItem(label: "Feature", insertText: "Feature('');", signature: "(title, opts?)", detail: "CodeceptJS test suite", kind: .dsl, cursorBackOffset: 3),
        CompletionItem(label: "Scenario", insertText: "Scenario('', async ({ I }) => {\n  \n});", signature: "(title, fn)", detail: "CodeceptJS scenario", kind: .dsl, cursorBackOffset: 24),
        CompletionItem(label: "xScenario", insertText: "xScenario('', async ({ I }) => {\n  \n});", signature: "(title, fn)", detail: "Skipped scenario", kind: .dsl, cursorBackOffset: 24),
        CompletionItem(label: "Before", insertText: "Before(({ I }) => {\n  \n});", signature: "(fn)", detail: "Hook before each scenario", kind: .dsl, cursorBackOffset: 4),
        CompletionItem(label: "After", insertText: "After(({ I }) => {\n  \n});", signature: "(fn)", detail: "Hook after each scenario", kind: .dsl, cursorBackOffset: 4),
        CompletionItem(label: "BeforeSuite", insertText: "BeforeSuite(({ I }) => {\n  \n});", signature: "(fn)", detail: "Hook once before suite", kind: .dsl, cursorBackOffset: 4),
        CompletionItem(label: "AfterSuite", insertText: "AfterSuite(({ I }) => {\n  \n});", signature: "(fn)", detail: "Hook once after suite", kind: .dsl, cursorBackOffset: 4),
        CompletionItem(label: "Data", insertText: "Data().Scenario('', async ({ I, current }) => {\n  \n});", signature: "(table)", detail: "Data-driven scenario", kind: .dsl, cursorBackOffset: 48),
        CompletionItem(label: "DataTable", insertText: "new DataTable([''])", signature: "(columns)", detail: "Create parameterized table", kind: .dsl, cursorBackOffset: 3),
        CompletionItem(label: "retryTo", insertText: "await retryTo((retryNum) => {\n  \n}, 3);", signature: "(fn, maxRetries)", detail: "Retry block on failure", kind: .dsl, cursorBackOffset: 7),
        CompletionItem(label: "tryTo", insertText: "await tryTo(() => {\n  \n});", signature: "(fn)", detail: "Soft-try block returning bool", kind: .dsl, cursorBackOffset: 4),
        CompletionItem(label: "within", insertText: "within('', () => {\n  \n});", signature: "(context, fn)", detail: "Scope actions to locator", kind: .dsl, cursorBackOffset: 16),
        CompletionItem(label: "session", insertText: "session('', () => {\n  \n});", signature: "(name, fn)", detail: "Isolated browser session", kind: .dsl, cursorBackOffset: 16),
        CompletionItem(label: "locate", insertText: "locate('')", signature: "(selector)", detail: "Fluent locator builder", kind: .dsl, cursorBackOffset: 2),
        CompletionItem(label: "secret", insertText: "secret('')", signature: "(value)", detail: "Mask sensitive value in logs", kind: .dsl, cursorBackOffset: 2),
        CompletionItem(label: "inject", insertText: "const { I } = inject();", signature: "()", detail: "Inject CodeceptJS support objects", kind: .dsl),
        CompletionItem(label: "pause", insertText: "pause();", signature: "()", detail: "Interactive REPL pause", kind: .dsl),
        CompletionItem(label: "eachElement", insertText: "await eachElement('', '', async (el) => {\n  \n});", signature: "(purpose, locator, fn)", detail: "Iterate matched elements", kind: .dsl, cursorBackOffset: 29)
    ]

    public static let jsKeywordItems: [CompletionItem] = [
        "async", "await", "const", "let", "import", "export", "from", "default",
        "return", "function", "if", "else", "for", "try", "catch", "throw", "new", "expect"
    ].map { CompletionItem(label: $0, insertText: $0, signature: "", detail: "keyword", kind: .keyword) }

    public static let builtInActorActions: [CompletionItem] = [
        // Navigation
        CompletionItem(label: "amOnPage", insertText: "amOnPage('')", signature: "(url)", detail: "Navigate to URL", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "refreshPage", insertText: "refreshPage()", signature: "()", detail: "Reload current page", kind: .action),
        CompletionItem(label: "openNewTab", insertText: "openNewTab()", signature: "()", detail: "Open a new browser tab", kind: .action),
        CompletionItem(label: "switchToNextTab", insertText: "switchToNextTab()", signature: "(num?)", detail: "Switch to next tab", kind: .action),
        CompletionItem(label: "switchToPreviousTab", insertText: "switchToPreviousTab()", signature: "(num?)", detail: "Switch to previous tab", kind: .action),
        CompletionItem(label: "closeCurrentTab", insertText: "closeCurrentTab()", signature: "()", detail: "Close active tab", kind: .action),
        CompletionItem(label: "resizeWindow", insertText: "resizeWindow(1440, 900)", signature: "(width, height)", detail: "Resize browser viewport", kind: .action),
        // Interaction
        CompletionItem(label: "click", insertText: "click('')", signature: "(locator, context?)", detail: "Click element or text", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "forceClick", insertText: "forceClick('')", signature: "(locator)", detail: "Force click element", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "doubleClick", insertText: "doubleClick('')", signature: "(locator)", detail: "Double-click element", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "rightClick", insertText: "rightClick('')", signature: "(locator)", detail: "Context-click element", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "fillField", insertText: "fillField('', '')", signature: "(field, value)", detail: "Clear and type into field", kind: .action, cursorBackOffset: 6),
        CompletionItem(label: "appendField", insertText: "appendField('', '')", signature: "(field, value)", detail: "Append text to field", kind: .action, cursorBackOffset: 6),
        CompletionItem(label: "clearField", insertText: "clearField('')", signature: "(field)", detail: "Clear input field", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "type", insertText: "type('')", signature: "(keys, delay?)", detail: "Type keystrokes", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "pressKey", insertText: "pressKey('Enter')", signature: "(key)", detail: "Press keyboard key", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "selectOption", insertText: "selectOption('', '')", signature: "(select, option)", detail: "Select dropdown option", kind: .action, cursorBackOffset: 6),
        CompletionItem(label: "checkOption", insertText: "checkOption('')", signature: "(field)", detail: "Check checkbox/radio", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "uncheckOption", insertText: "uncheckOption('')", signature: "(field)", detail: "Uncheck checkbox", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "attachFile", insertText: "attachFile('', '')", signature: "(locator, path)", detail: "Upload file to input", kind: .action, cursorBackOffset: 6),
        CompletionItem(label: "moveCursorTo", insertText: "moveCursorTo('')", signature: "(locator)", detail: "Hover over element", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "scrollTo", insertText: "scrollTo('')", signature: "(locator)", detail: "Scroll element into view", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "dragAndDrop", insertText: "dragAndDrop('', '')", signature: "(src, dst)", detail: "Drag element to target", kind: .action, cursorBackOffset: 6),
        // Assertions
        CompletionItem(label: "see", insertText: "see('')", signature: "(text, context?)", detail: "Assert text is visible", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "dontSee", insertText: "dontSee('')", signature: "(text, context?)", detail: "Assert text is absent", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "seeElement", insertText: "seeElement('')", signature: "(locator)", detail: "Assert element visible", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "dontSeeElement", insertText: "dontSeeElement('')", signature: "(locator)", detail: "Assert element not visible", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "seeInField", insertText: "seeInField('', '')", signature: "(field, value)", detail: "Assert field value", kind: .action, cursorBackOffset: 6),
        CompletionItem(label: "seeInCurrentUrl", insertText: "seeInCurrentUrl('')", signature: "(url)", detail: "Assert URL contains text", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "seeInTitle", insertText: "seeInTitle('')", signature: "(text)", detail: "Assert page title", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "seeNumberOfElements", insertText: "seeNumberOfElements('', 1)", signature: "(locator, num)", detail: "Assert element count", kind: .action, cursorBackOffset: 5),
        CompletionItem(label: "seeNumberOfVisibleElements", insertText: "seeNumberOfVisibleElements('', 1)", signature: "(locator, num)", detail: "Assert visible element count", kind: .action, cursorBackOffset: 5),
        CompletionItem(label: "seeCheckboxIsChecked", insertText: "seeCheckboxIsChecked('')", signature: "(field)", detail: "Assert checkbox checked", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "seeTextEquals", insertText: "seeTextEquals('', '')", signature: "(text, context?)", detail: "Assert exact text match", kind: .action, cursorBackOffset: 6),
        // Waits
        CompletionItem(label: "wait", insertText: "wait(1)", signature: "(sec)", detail: "Pause for seconds", kind: .action, cursorBackOffset: 1),
        CompletionItem(label: "waitForElement", insertText: "waitForElement('', 5)", signature: "(locator, sec?)", detail: "Wait until element appears", kind: .action, cursorBackOffset: 5),
        CompletionItem(label: "waitForVisible", insertText: "waitForVisible('', 5)", signature: "(locator, sec?)", detail: "Wait until visible", kind: .action, cursorBackOffset: 5),
        CompletionItem(label: "waitForInvisible", insertText: "waitForInvisible('', 5)", signature: "(locator, sec?)", detail: "Wait until hidden", kind: .action, cursorBackOffset: 5),
        CompletionItem(label: "waitForText", insertText: "waitForText('', 5)", signature: "(text, sec?, context?)", detail: "Wait for text on page", kind: .action, cursorBackOffset: 5),
        CompletionItem(label: "waitForDetached", insertText: "waitForDetached('', 5)", signature: "(locator, sec?)", detail: "Wait for element removal", kind: .action, cursorBackOffset: 5),
        CompletionItem(label: "waitForClickable", insertText: "waitForClickable('', 5)", signature: "(locator, sec?)", detail: "Wait until clickable", kind: .action, cursorBackOffset: 5),
        CompletionItem(label: "waitInUrl", insertText: "waitInUrl('', 5)", signature: "(urlPart, sec?)", detail: "Wait for URL fragment", kind: .action, cursorBackOffset: 5),
        CompletionItem(label: "waitForNavigation", insertText: "waitForNavigation()", signature: "(opts?)", detail: "Wait for navigation", kind: .action),
        CompletionItem(label: "waitForResponse", insertText: "waitForResponse('')", signature: "(matcher, sec?)", detail: "Wait for network response", kind: .action, cursorBackOffset: 2),
        // Grabbers
        CompletionItem(label: "grabTextFrom", insertText: "grabTextFrom('')", signature: "(locator)", detail: "Grab element text", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "grabTextFromAll", insertText: "grabTextFromAll('')", signature: "(locator)", detail: "Grab text array", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "grabValueFrom", insertText: "grabValueFrom('')", signature: "(field)", detail: "Grab input value", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "grabAttributeFrom", insertText: "grabAttributeFrom('', '')", signature: "(locator, attr)", detail: "Grab HTML attribute", kind: .action, cursorBackOffset: 6),
        CompletionItem(label: "grabCurrentUrl", insertText: "grabCurrentUrl()", signature: "()", detail: "Grab current URL", kind: .action),
        CompletionItem(label: "grabTitle", insertText: "grabTitle()", signature: "()", detail: "Grab page title", kind: .action),
        CompletionItem(label: "grabCookie", insertText: "grabCookie('')", signature: "(name?)", detail: "Grab browser cookie", kind: .action, cursorBackOffset: 2),
        // REST / GraphQL / JSONResponse
        CompletionItem(label: "sendGetRequest", insertText: "sendGetRequest('')", signature: "(url, headers?)", detail: "REST GET request", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "sendPostRequest", insertText: "sendPostRequest('', {})", signature: "(url, payload?, headers?)", detail: "REST POST request", kind: .action, cursorBackOffset: 6),
        CompletionItem(label: "sendPutRequest", insertText: "sendPutRequest('', {})", signature: "(url, payload?, headers?)", detail: "REST PUT request", kind: .action, cursorBackOffset: 6),
        CompletionItem(label: "sendPatchRequest", insertText: "sendPatchRequest('', {})", signature: "(url, payload?, headers?)", detail: "REST PATCH request", kind: .action, cursorBackOffset: 6),
        CompletionItem(label: "sendDeleteRequest", insertText: "sendDeleteRequest('')", signature: "(url, headers?)", detail: "REST DELETE request", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "sendQuery", insertText: "sendQuery('')", signature: "(query, vars?)", detail: "GraphQL query", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "sendMutation", insertText: "sendMutation('')", signature: "(mutation, vars?)", detail: "GraphQL mutation", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "amBearerAuthenticated", insertText: "amBearerAuthenticated('')", signature: "(token)", detail: "Set Bearer token", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "haveRequestHeaders", insertText: "haveRequestHeaders({})", signature: "(headers)", detail: "Set HTTP headers", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "seeResponseCodeIs", insertText: "seeResponseCodeIs(200)", signature: "(code)", detail: "Assert HTTP status code", kind: .action, cursorBackOffset: 1),
        CompletionItem(label: "seeResponseCodeIsSuccessful", insertText: "seeResponseCodeIsSuccessful()", signature: "()", detail: "Assert 2xx HTTP status", kind: .action),
        CompletionItem(label: "seeResponseCodeIsClientError", insertText: "seeResponseCodeIsClientError()", signature: "()", detail: "Assert 4xx HTTP status", kind: .action),
        CompletionItem(label: "seeResponseCodeIsServerError", insertText: "seeResponseCodeIsServerError()", signature: "()", detail: "Assert 5xx HTTP status", kind: .action),
        CompletionItem(label: "seeResponseContainsJson", insertText: "seeResponseContainsJson({})", signature: "(json)", detail: "Assert JSON subset", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "seeResponseContainsKeys", insertText: "seeResponseContainsKeys([''])", signature: "(keys)", detail: "Assert top-level JSON keys", kind: .action, cursorBackOffset: 3),
        CompletionItem(label: "seeResponseMatchesJsonSchema", insertText: "seeResponseMatchesJsonSchema()", signature: "(schema)", detail: "Validate JSON schema", kind: .action, cursorBackOffset: 1),
        // Utilities
        CompletionItem(label: "retry", insertText: "retry(2)", signature: "(opts)", detail: "Retry chained step", kind: .action, cursorBackOffset: 1),
        CompletionItem(label: "saveScreenshot", insertText: "saveScreenshot('shot.png')", signature: "(fileName, fullPage?)", detail: "Capture screenshot", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "setCookie", insertText: "setCookie({ name: '', value: '' })", signature: "(cookie)", detail: "Set browser cookie", kind: .action, cursorBackOffset: 15),
        CompletionItem(label: "clearCookie", insertText: "clearCookie()", signature: "(name?)", detail: "Clear browser cookies", kind: .action),
        CompletionItem(label: "switchTo", insertText: "switchTo('')", signature: "(locator?)", detail: "Switch into iframe", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "executeScript", insertText: "executeScript(() => {\n  \n})", signature: "(fn, args?)", detail: "Run JS in browser context", kind: .action, cursorBackOffset: 3)
    ]
}
