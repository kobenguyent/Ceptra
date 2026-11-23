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

        // 3. Tag completion after `@` (e.g. inside Scenario('... @sm') or test('...', { tag: '@sm' }))
        if let tagPrefix = matchTrailingRegex(#"(@[A-Za-z0-9_:-]*)$"#, in: linePrefix) {
            let replaceRange = NSRange(location: cursorUTF16Offset - (tagPrefix as NSString).length, length: (tagPrefix as NSString).length)
            let lower = tagPrefix.lowercased()
            let isPW = isPlaywrightContext(source: source, sourceFileURL: sourceFileURL, workspace: workspace)
            let pool = Array(Set(index.workspaceTags + ["@smoke", "@e2e", "@api", "@regression", "@slow", "@wip"])).sorted()
            let matches = pool
                .filter { $0.lowercased().hasPrefix(lower) }
                .map { CompletionItem(label: $0, insertText: $0, signature: "", detail: isPW ? "Playwright tag" : "CodeceptJS tag", kind: .tag) }
            return matches.isEmpty ? nil : CompletionResult(replacementRange: replaceRange, items: matches)
        }

        // 3.5. Callback argument / fixture destructuring completion:
        //      - `test('...', async ({ req` / `test.beforeEach(async ({ page, `
        //      - `Scenario('...', async ({ I, `
        //      - `test('...', async ({ request }, te` (2nd param: testInfo)
        if let argCtx = matchCallbackArgContext(linePrefix) {
            let typed = argCtx.prefix
            let replaceRange = NSRange(location: cursorUTF16Offset - (typed as NSString).length, length: (typed as NSString).length)
            let isPW = isPlaywrightContext(source: source, sourceFileURL: sourceFileURL, workspace: workspace)
            var pool: [CompletionItem] = []

            if argCtx.isSecondParam {
                if isPW {
                    pool = [
                        CompletionItem(label: "testInfo", insertText: "testInfo", signature: ": TestInfo", detail: "Playwright TestInfo metadata", kind: .symbol)
                    ]
                }
            } else if isPW {
                pool = builtInPlaywrightFixtureArgs
                let existing = Set(pool.map(\.label))
                for custom in extractPlaywrightExtendedFixtures(from: source) where !existing.contains(custom) {
                    pool.append(CompletionItem(label: custom, insertText: custom, signature: "", detail: "Custom Playwright fixture", kind: .symbol))
                }
            } else {
                pool = [
                    CompletionItem(label: "I", insertText: "I", signature: ": CodeceptJS.I", detail: "CodeceptJS primary actor", kind: .symbol),
                    CompletionItem(label: "current", insertText: "current", signature: "", detail: "DataTable row object", kind: .symbol)
                ]
                let existing = Set(pool.map(\.label))
                if let includes = workspace?.config.includes {
                    for inc in includes where !existing.contains(inc.alias) {
                        pool.append(CompletionItem(
                            label: inc.alias,
                            insertText: inc.alias,
                            signature: "",
                            detail: "include: \(inc.relativePath)",
                            kind: .symbol
                        ))
                    }
                }
            }

            let existingInObj = argCtx.existingNames
            let filteredPool = pool.filter { !existingInObj.contains($0.label) || $0.label == typed }
            let ranked = rankAndFilter(filteredPool, prefix: typed)
            return ranked.isEmpty ? nil : CompletionResult(replacementRange: replaceRange, items: ranked)
        }

        // 4. Member access after `I.` / `page.` / `request.` / `response.` / `context.` / `browser.` / `testInfo.` / `route.` / `test.` / `expect(...).` / `<arg>.`
        if let memberMatch = matchMemberAccess(linePrefix) {
            let receiver = memberMatch.receiver
            let typed = memberMatch.memberPrefix
            let replaceRange = NSRange(location: cursorUTF16Offset - (typed as NSString).length, length: (typed as NSString).length)
            let inferredTypes = inferLocalReceiverTypes(in: source, upToUTF16Offset: cursorUTF16Offset)

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
            } else if receiver == "test" {
                pool = builtInPlaywrightTestMembers
            } else if receiver == "expect" {
                pool = builtInPlaywrightExpectMatchers
            } else if let directPool = builtInMembers(forReceiverKind: receiverKind(forName: receiver, inferredTypes: inferredTypes)) {
                pool = directPool
            } else if let aliasMembers = index.memberMethodsByAlias[receiver] {
                pool = aliasMembers
            } else if let constructedClass = inferredTypes.constructedClassByVar[receiver],
                      let sourceFileURL, let workspace {
                if let classPool = resolveImportedClassMembers(
                    className: constructedClass,
                    in: source,
                    sourceFileURL: sourceFileURL,
                    workspace: workspace
                ) {
                    pool = classPool
                }
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

        // 5. General identifier / CodeceptJS or Playwright DSL / Keywords / Callback args & Local symbols
        guard let wordPrefix = matchTrailingRegex(#"([A-Za-z_$][\w$]*)$"#, in: linePrefix), !wordPrefix.isEmpty else {
            return nil
        }

        let replaceRange = NSRange(location: cursorUTF16Offset - (wordPrefix as NSString).length, length: (wordPrefix as NSString).length)
        let isPW = isPlaywrightContext(source: source, sourceFileURL: sourceFileURL, workspace: workspace)
        var pool: [CompletionItem] = (isPW ? builtInPlaywrightDSLItems : builtInDSLItems) + jsKeywordItems

        // Callback parameters & destructured fixture args in current file (`async ({ request, page }, testInfo) =>`)
        var seenLabels = Set(pool.map(\.label))
        let argParams = extractCallbackParameterIdentifiers(from: source)
        for param in argParams where !seenLabels.contains(param.name) {
            seenLabels.insert(param.name)
            pool.append(CompletionItem(
                label: param.name,
                insertText: param.name,
                signature: param.signature,
                detail: param.detail,
                kind: .symbol
            ))
        }

        // Configured include aliases (`I`, `homePage`, `loginPage`, etc.)
        if let includes = workspace?.config.includes {
            for inc in includes where !seenLabels.contains(inc.alias) {
                seenLabels.insert(inc.alias)
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
        for local in extractLocalIdentifiers(from: source) where !seenLabels.contains(local) && local != wordPrefix {
            seenLabels.insert(local)
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

        let importableExts: Set<String> = ["js", "ts", "mjs", "cjs", "mts", "cts", "jsx", "tsx", "json", "feature"]
        var items: [CompletionItem] = []
        for file in workspace.files
            where file.path != sourceFileURL.standardizedFileURL.path
            && !file.isBinaryFile
            && importableExts.contains(file.fileExtension.lowercased()) {
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

    private static func isPlaywrightContext(source: String, sourceFileURL: URL?, workspace: CodeceptWorkspace?) -> Bool {
        if source.contains("@playwright/test") || source.contains("@playwright/experimental-ct") {
            return true
        }
        if let sourceFileURL, let workspace {
            return workspace.resolvedConfig(forFilePath: sourceFileURL.path).framework == .playwright
        }
        return workspace?.config.framework == .playwright
    }

    /// True when the caret on `linePrefix` sits inside a callback parameter destructuring list
    /// such as `test('...', async ({ `, `async ({ page, `, or `async ({ request }, `.
    public static func isInsideCallbackArgList(_ linePrefix: String) -> Bool {
        matchCallbackArgContext(linePrefix) != nil
    }

    private static func matchCallbackArgContext(_ linePrefix: String) -> (prefix: String, existingNames: Set<String>, isSecondParam: Bool)? {
        let ns = linePrefix as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        // 1. 2nd callback parameter after destructuring: `async ({ request }, te` / `({ page }, `
        let secondPattern = #"(?:(?:^|[,=(\s])(?:async\s+|function(?:\s+[A-Za-z_$][\w$]*)?\s*)?)\(\s*\{([^}\n]*)\}\s*,\s*([A-Za-z_$][\w$]*)?$"#
        if let regex = try? NSRegularExpression(pattern: secondPattern),
           let m = regex.firstMatch(in: linePrefix, range: fullRange) {
            let prefix = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
            return (prefix, [], true)
        }

        // 2. Inside destructuring object parameter: `async ({ `, `async ({ req`, `({ page, con`
        let destructPattern = #"(?:^|[,=(\s])(?:async\s+|function(?:\s+[A-Za-z_$][\w$]*)?\s*)?\(\s*\{([^}\n]*)$"#
        guard let regex = try? NSRegularExpression(pattern: destructPattern),
              let m = regex.firstMatch(in: linePrefix, range: fullRange) else {
            return nil
        }

        // Reject regular function calls like `toMatchObject({ id` where an identifier other than async/function precedes `(`
        if m.range.location > 0 {
            let before = ns.substring(to: m.range.location)
            if let last = before.last, (last.isLetter || last.isNumber || last == "_" || last == "$") {
                return nil
            }
        }

        let inside = ns.substring(with: m.range(at: 1))
        let segments = inside.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let currentSeg = segments.last else { return nil }
        // Don't offer fixture names while typing an alias after `:` or default value after `=`
        if currentSeg.contains(":") || currentSeg.contains("=") {
            return nil
        }

        let trimmedCurrent = currentSeg.trimmingCharacters(in: .whitespaces)
        // Ensure the current token is empty or a valid identifier prefix
        if !trimmedCurrent.isEmpty {
            let valid = trimmedCurrent.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
            if !valid { return nil }
        }

        var existing = Set<String>()
        for seg in segments.dropLast() {
            let keyPart = seg.split(separator: ":", maxSplits: 1).first ?? Substring(seg)
            let cleanKey = keyPart.split(separator: "=", maxSplits: 1).first ?? keyPart
            let trimmed = cleanKey.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { existing.insert(trimmed) }
        }

        return (trimmedCurrent, existing, false)
    }

    private enum BuiltInReceiverKind {
        case playwrightPage
        case playwrightLocator
        case playwrightRequest
        case playwrightResponse
        case playwrightContext
        case playwrightBrowser
        case playwrightTestInfo
        case playwrightRoute
        case playwrightKeyboard
        case playwrightMouse
    }

    private struct InferredLocalTypes {
        var receiverKindByVar: [String: BuiltInReceiverKind] = [:]
        var constructedClassByVar: [String: String] = [:]
    }

    private static func builtInReceiverKind(forTypeName rawType: String) -> BuiltInReceiverKind? {
        let clean = rawType
            .replacingOccurrences(of: "Promise<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch clean {
        case "Page", "Frame": return .playwrightPage
        case "Locator", "FrameLocator": return .playwrightLocator
        case "APIRequestContext": return .playwrightRequest
        case "APIResponse", "Response": return .playwrightResponse
        case "BrowserContext": return .playwrightContext
        case "Browser": return .playwrightBrowser
        case "TestInfo": return .playwrightTestInfo
        case "Route": return .playwrightRoute
        case "Keyboard": return .playwrightKeyboard
        case "Mouse": return .playwrightMouse
        default: return nil
        }
    }

    private static func builtInReceiverKind(forFixtureName name: String) -> BuiltInReceiverKind? {
        switch name {
        case "page", "frame": return .playwrightPage
        case "request": return .playwrightRequest
        case "context": return .playwrightContext
        case "browser": return .playwrightBrowser
        case "testInfo": return .playwrightTestInfo
        case "route": return .playwrightRoute
        case "response": return .playwrightResponse
        case "keyboard": return .playwrightKeyboard
        case "mouse": return .playwrightMouse
        case "locator": return .playwrightLocator
        default:
            if name.hasSuffix("Locator") { return .playwrightLocator }
            return nil
        }
    }

    private static func receiverKind(forName receiver: String, inferredTypes: InferredLocalTypes) -> BuiltInReceiverKind? {
        if let inferred = inferredTypes.receiverKindByVar[receiver] {
            return inferred
        }
        return builtInReceiverKind(forFixtureName: receiver)
    }

    private static func builtInMembers(forReceiverKind kind: BuiltInReceiverKind?) -> [CompletionItem]? {
        guard let kind else { return nil }
        switch kind {
        case .playwrightPage: return builtInPlaywrightPageActions
        case .playwrightLocator: return builtInPlaywrightLocatorActions
        case .playwrightRequest: return builtInPlaywrightRequestActions
        case .playwrightResponse: return builtInPlaywrightResponseActions
        case .playwrightContext: return builtInPlaywrightContextActions
        case .playwrightBrowser: return builtInPlaywrightBrowserActions
        case .playwrightTestInfo: return builtInPlaywrightTestInfoMembers
        case .playwrightRoute: return builtInPlaywrightRouteActions
        case .playwrightKeyboard: return builtInPlaywrightKeyboardActions
        case .playwrightMouse: return builtInPlaywrightMouseActions
        }
    }

    private static func inferLocalReceiverTypes(in source: String, upToUTF16Offset: Int) -> InferredLocalTypes {
        var result = InferredLocalTypes()
        let nsFull = source as NSString
        let limit = min(max(0, upToUTF16Offset), nsFull.length)
        let prefixText = nsFull.substring(to: limit)
        let ns = prefixText as NSString
        let range = NSRange(location: 0, length: ns.length)

        // 1. Destructured callback args (including aliases like `async ({ request: api, page: p }, info) =>`)
        if let regex = try? NSRegularExpression(pattern: #"\(\s*\{([^}\n]+)\}(?:\s*,\s*([A-Za-z_$][\w$]*))?"#) {
            for m in regex.matches(in: prefixText, range: range) {
                let inside = ns.substring(with: m.range(at: 1))
                for rawSeg in inside.split(separator: ",") {
                    let seg = rawSeg.trimmingCharacters(in: .whitespaces)
                    if seg.isEmpty { continue }
                    let parts = seg.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    let key = parts[0].split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    let aliasRaw = parts.count > 1 ? parts[1] : key
                    let alias = aliasRaw.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? key
                    if let kind = builtInReceiverKind(forFixtureName: key), !alias.isEmpty {
                        result.receiverKindByVar[alias] = kind
                    }
                }
                if m.range(at: 2).location != NSNotFound {
                    let secondParam = ns.substring(with: m.range(at: 2))
                    if !secondParam.isEmpty {
                        result.receiverKindByVar[secondParam] = .playwrightTestInfo
                    }
                }
            }
        }

        // 2. Callback parameter in `page.route(..., (r) =>` / `context.route(..., async (r) =>`
        if let regex = try? NSRegularExpression(pattern: #"\.route\s*\([^,\n]+,\s*(?:async\s*)?\(?\s*([A-Za-z_$][\w$]*)"#) {
            for m in regex.matches(in: prefixText, range: range) {
                let name = ns.substring(with: m.range(at: 1))
                result.receiverKindByVar[name] = .playwrightRoute
            }
        }

        // 3. Explicit TypeScript type annotations: `req: APIRequestContext`, `const res: APIResponse =`
        if let regex = try? NSRegularExpression(pattern: #"\b([A-Za-z_$][\w$]*)\s*:\s*(Page|Frame|Locator|FrameLocator|APIRequestContext|APIResponse|BrowserContext|Browser|TestInfo|Route|Keyboard|Mouse)\b"#) {
            for m in regex.matches(in: prefixText, range: range) {
                let name = ns.substring(with: m.range(at: 1))
                let typeName = ns.substring(with: m.range(at: 2))
                if let kind = builtInReceiverKind(forTypeName: typeName) {
                    result.receiverKindByVar[name] = kind
                }
            }
        }

        // 4. Local variable initializers: `const res = await request.get(...)`, `const btn = page.getByRole(...)`, `const hp = new HomePage(page)`
        if let regex = try? NSRegularExpression(pattern: #"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:await\s+)?([^\n;]+)"#) {
            for m in regex.matches(in: prefixText, range: range) {
                let varName = ns.substring(with: m.range(at: 1))
                let rhs = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)

                if rhs.range(of: #"\.(?:get|post|put|patch|delete|head|fetch|waitForResponse)\s*\("#, options: .regularExpression) != nil {
                    result.receiverKindByVar[varName] = .playwrightResponse
                } else if rhs.range(of: #"\.(?:locator|frameLocator|getByRole|getByTestId|getByText|getByLabel|getByPlaceholder|getByAltText|getByTitle|first|last|nth|filter)\s*\("#, options: .regularExpression) != nil {
                    result.receiverKindByVar[varName] = .playwrightLocator
                } else if rhs.range(of: #"\.newPage\s*\("#, options: .regularExpression) != nil {
                    result.receiverKindByVar[varName] = .playwrightPage
                } else if rhs.range(of: #"(?:request\.newContext\s*\(|\.(?:request)\b)"#, options: .regularExpression) != nil {
                    result.receiverKindByVar[varName] = .playwrightRequest
                } else if rhs.range(of: #"\.(?:newContext|context)\s*\("#, options: .regularExpression) != nil {
                    result.receiverKindByVar[varName] = .playwrightContext
                } else if let newMatch = try? NSRegularExpression(pattern: #"^new\s+([A-Za-z_$][\w$]*)\s*\("#)
                    .firstMatch(in: rhs, range: NSRange(location: 0, length: (rhs as NSString).length)) {
                    let cls = (rhs as NSString).substring(with: newMatch.range(at: 1))
                    result.constructedClassByVar[varName] = cls
                }
            }
        }

        return result
    }

    private static func extractPlaywrightExtendedFixtures(from source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"test\.extend\s*(?:<[^>]+>)?\s*\(\s*\{([\s\S]{0,1200}?)\}\s*\)"#) else {
            return []
        }
        let ns = source as NSString
        var out: [String] = []
        var seen = Set<String>()
        let propRegex = try? NSRegularExpression(pattern: #"^\s*([A-Za-z_$][\w$]*)\s*:"#, options: [.anchorsMatchLines])
        for m in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: m.range(at: 1))
            let bns = body as NSString
            if let propRegex {
                for pm in propRegex.matches(in: body, range: NSRange(location: 0, length: bns.length)) {
                    let name = bns.substring(with: pm.range(at: 1))
                    if seen.insert(name).inserted { out.append(name) }
                }
            }
        }
        return out
    }

    private static func extractCallbackParameterIdentifiers(from source: String) -> [(name: String, signature: String, detail: String)] {
        let ns = source as NSString
        let range = NSRange(location: 0, length: ns.length)
        var results: [(name: String, signature: String, detail: String)] = []
        var seen = Set<String>()

        func addParam(_ name: String, fixtureKey: String? = nil, explicitType: String? = nil) {
            let clean = name.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty, clean.first?.isLetter == true || clean.first == "_" || clean.first == "$" else { return }
            guard seen.insert(clean).inserted else { return }
            if let fk = fixtureKey, let fixtureItem = builtInPlaywrightFixtureArgs.first(where: { $0.label == fk }) {
                results.append((clean, fixtureItem.signature, fixtureItem.detail))
            } else if let explicitType, !explicitType.isEmpty {
                results.append((clean, ": \(explicitType)", "parameter"))
            } else if clean == "testInfo" {
                results.append((clean, ": TestInfo", "Playwright TestInfo"))
            } else if clean == "I" {
                results.append((clean, ": CodeceptJS.I", "CodeceptJS actor"))
            } else {
                results.append((clean, "", "callback arg"))
            }
        }

        // 1. Destructured callback params: `async ({ request, page: p }, testInfo) =>`
        if let regex = try? NSRegularExpression(pattern: #"\(\s*\{([^}\n]+)\}(?:\s*,\s*([A-Za-z_$][\w$]*))?"#) {
            for m in regex.matches(in: source, range: range) {
                let inside = ns.substring(with: m.range(at: 1))
                for rawSeg in inside.split(separator: ",") {
                    let seg = rawSeg.trimmingCharacters(in: .whitespaces)
                    if seg.isEmpty { continue }
                    let parts = seg.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    let key = parts[0].split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    let aliasRaw = parts.count > 1 ? parts[1] : key
                    let alias = aliasRaw.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? key
                    addParam(alias, fixtureKey: key)
                }
                if m.range(at: 2).location != NSNotFound {
                    addParam(ns.substring(with: m.range(at: 2)))
                }
            }
        }

        // 2. Simple positional arrow/function parameters: `async (route) =>` / `function login(page: Page, email: string)`
        if let regex = try? NSRegularExpression(pattern: #"(?:async\s+)?\(\s*([A-Za-z_$][\w$]*(?:\s*:\s*[A-Za-z_$][\w$.<>| ]*)?(?:\s*,\s*[A-Za-z_$][\w$]*(?:\s*:\s*[A-Za-z_$][\w$.<>| ]*)?)*)\s*\)\s*(?:=>|\{)"#) {
            for m in regex.matches(in: source, range: range) {
                let paramsStr = ns.substring(with: m.range(at: 1))
                for rawP in paramsStr.split(separator: ",") {
                    let parts = rawP.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    let name = parts[0]
                    let typeStr = parts.count > 1 ? parts[1] : nil
                    addParam(name, explicitType: typeStr)
                }
            }
        }

        return results
    }

    private static func resolveImportedClassMembers(
        className: String,
        in source: String,
        sourceFileURL: URL,
        workspace: CodeceptWorkspace
    ) -> [CompletionItem]? {
        let escaped = NSRegularExpression.escapedPattern(for: className)
        let patterns = [
            #"import\s+(?:\{[^}\n]*\b\#(escaped)\b[^}\n]*\}|\#(escaped))\s+from\s+['"`]([^'"`\n]+)['"`]"#,
            #"require\s*\(\s*['"`]([^'"`\n]+)['"`]\s*\)"#
        ]
        let ns = source as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let regex = try? NSRegularExpression(pattern: patterns[0]),
           let m = regex.firstMatch(in: source, range: range),
           m.numberOfRanges >= 2 {
            let spec = ns.substring(with: m.range(at: 1))
            if let resolved = ImportNavigator.resolveImportPath(
                specifier: spec,
                fromFileURL: sourceFileURL,
                workspaceRoot: workspace.rootURL,
                config: workspace.config
            ), let fileText = try? String(contentsOf: resolved.fileURL, encoding: .utf8) {
                let methods = extractMethodSignatures(from: fileText, sourceLabel: resolved.fileURL.lastPathComponent, kind: .method)
                if !methods.isEmpty { return methods }
            }
        }
        return nil
    }

    private static func matchMemberAccess(_ linePrefix: String) -> (receiver: String, memberPrefix: String)? {
        // 1. Balanced-paren call chain & chained property access ending in `.memberPrefix`:
        //    - `expect(page.getByRole('button')).toBe` / `expect.soft(loc).not.toHave`
        //    - `page.getByRole('button', { name: 'Save' }).cli`
        //    - `page.context().newPage` / `(await request.get('/x')).json`
        //    - `page.request.get` / `context.request.post` / `page.keyboard.press` / `page.mouse.click`
        if let trailingDotMatch = matchTrailingMemberPrefix(linePrefix) {
            let member = trailingDotMatch.memberPrefix
            var beforeDot = trailingDotMatch.prefixBeforeDot
            if beforeDot.hasSuffix(".not") {
                beforeDot = String(beforeDot.dropLast(4))
            }
            if beforeDot.hasSuffix(".request") {
                return ("request", member)
            }
            if beforeDot.hasSuffix(".keyboard") {
                return ("keyboard", member)
            }
            if beforeDot.hasSuffix(".mouse") {
                return ("mouse", member)
            }
            if beforeDot.hasSuffix(")"),
               let callHead = receiverBeforeBalancedCall(beforeDot) {
                if callHead == "expect" || callHead == "expect.soft" || callHead == "expect.poll" {
                    return ("expect", member)
                }
                if callHead.hasSuffix(".context") || callHead.hasSuffix(".newContext") {
                    return ("context", member)
                }
                if callHead.hasSuffix(".newPage") {
                    return ("page", member)
                }
                let responseMethods = [
                    ".get", ".post", ".put", ".patch", ".delete", ".head", ".fetch", ".waitForResponse"
                ]
                if responseMethods.contains(where: { callHead.hasSuffix($0) }) {
                    return ("response", member)
                }
                let locatorMethods = [
                    ".locator", ".frameLocator", ".getByRole", ".getByTestId", ".getByText", ".getByLabel",
                    ".getByPlaceholder", ".getByAltText", ".getByTitle",
                    ".first", ".last", ".nth", ".filter"
                ]
                if locatorMethods.contains(where: { callHead.hasSuffix($0) }) {
                    return ("locator", member)
                }
            }
            // Handle parenthesized `(await request.get(...)).json`
            if beforeDot.hasSuffix(")"),
               beforeDot.contains(".get(") || beforeDot.contains(".post(") || beforeDot.contains(".put(") ||
               beforeDot.contains(".patch(") || beforeDot.contains(".delete(") || beforeDot.contains(".fetch(") {
                return ("response", member)
            }
        }
        // 2. Direct identifier member access: `I.click`, `I.retry(2).see`, `page.goto`, `request.get`, `response.json`, `test.describe`, `loginPage.sub`
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

    private static func matchTrailingMemberPrefix(_ linePrefix: String) -> (prefixBeforeDot: String, memberPrefix: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"\.([A-Za-z_$][\w$]*)?$"#) else { return nil }
        let ns = linePrefix as NSString
        guard let m = regex.firstMatch(in: linePrefix, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let prefixBeforeDot = ns.substring(to: m.range.location)
        let member = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
        return (prefixBeforeDot, member)
    }

    /// Given a prefix ending in `)` (e.g. `await expect(page.getByRole('button'))`),
    /// walks backwards across balanced parentheses/strings and returns the identifier chain
    /// immediately preceding the opening `(` (e.g. `expect` or `page.getByRole`).
    private static func receiverBeforeBalancedCall(_ text: String) -> String? {
        let chars = Array(text)
        guard !chars.isEmpty, chars.last == ")" else { return nil }
        var depth = 0
        var inString: Character? = nil
        var openIndex: Int? = nil

        var i = chars.count - 1
        while i >= 0 {
            let c = chars[i]
            if let quote = inString {
                if c == quote {
                    // Check if escaped
                    var backslashes = 0
                    var k = i - 1
                    while k >= 0 && chars[k] == "\\" {
                        backslashes += 1
                        k -= 1
                    }
                    if backslashes % 2 == 0 {
                        inString = nil
                    }
                }
                i -= 1
                continue
            }
            if c == "'" || c == "\"" || c == "`" {
                inString = c
                i -= 1
                continue
            }
            if c == ")" {
                depth += 1
            } else if c == "(" {
                depth -= 1
                if depth == 0 {
                    openIndex = i
                    break
                }
            }
            i -= 1
        }

        guard let openIdx = openIndex else { return nil }
        var end = openIdx - 1
        while end >= 0 && chars[end].isWhitespace {
            end -= 1
        }
        guard end >= 0 else { return nil }
        var start = end
        while start >= 0 {
            let ch = chars[start]
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "$" || ch == "." {
                start -= 1
            } else {
                break
            }
        }
        let head = String(chars[(start + 1)...end])
        return head.isEmpty ? nil : head
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

    // MARK: - Curated Playwright Test (@playwright/test) Catalog

    public static let builtInPlaywrightDSLItems: [CompletionItem] = [
        CompletionItem(label: "test", insertText: "test('', async ({ page }) => {\n  \n});", signature: "(title, fn)", detail: "Playwright test case", kind: .dsl, cursorBackOffset: 27),
        CompletionItem(label: "expect", insertText: "await expect().toBeVisible();", signature: "(actual)", detail: "Playwright web-first assertion", kind: .dsl, cursorBackOffset: 16),
        CompletionItem(label: "defineConfig", insertText: "defineConfig({\n  \n})", signature: "(config)", detail: "Playwright config helper", kind: .dsl, cursorBackOffset: 2),
        CompletionItem(label: "devices", insertText: "devices['Desktop Chrome']", signature: "[name]", detail: "Playwright device descriptors", kind: .dsl)
    ]

    public static let builtInPlaywrightTestMembers: [CompletionItem] = [
        CompletionItem(label: "describe", insertText: "describe('', () => {\n  \n});", signature: "(title, fn)", detail: "Group related tests", kind: .dsl, cursorBackOffset: 17),
        CompletionItem(label: "step", insertText: "step('', async () => {\n  \n});", signature: "(title, fn)", detail: "Named step in trace & replay", kind: .dsl, cursorBackOffset: 19),
        CompletionItem(label: "beforeEach", insertText: "beforeEach(async ({ page }) => {\n  \n});", signature: "(fn)", detail: "Run before each test", kind: .dsl, cursorBackOffset: 4),
        CompletionItem(label: "afterEach", insertText: "afterEach(async ({ page }) => {\n  \n});", signature: "(fn)", detail: "Run after each test", kind: .dsl, cursorBackOffset: 4),
        CompletionItem(label: "beforeAll", insertText: "beforeAll(async () => {\n  \n});", signature: "(fn)", detail: "Run once before suite", kind: .dsl, cursorBackOffset: 4),
        CompletionItem(label: "afterAll", insertText: "afterAll(async () => {\n  \n});", signature: "(fn)", detail: "Run once after suite", kind: .dsl, cursorBackOffset: 4),
        CompletionItem(label: "only", insertText: "only('', async ({ page }) => {\n  \n});", signature: "(title, fn)", detail: "Run only this test", kind: .dsl, cursorBackOffset: 27),
        CompletionItem(label: "skip", insertText: "skip('', async ({ page }) => {\n  \n});", signature: "(title, fn)", detail: "Skip this test", kind: .dsl, cursorBackOffset: 27),
        CompletionItem(label: "fixme", insertText: "fixme('', async ({ page }) => {\n  \n});", signature: "(title, fn)", detail: "Mark test as fixme", kind: .dsl, cursorBackOffset: 27),
        CompletionItem(label: "fail", insertText: "fail('', async ({ page }) => {\n  \n});", signature: "(title, fn)", detail: "Expect test to fail", kind: .dsl, cursorBackOffset: 27),
        CompletionItem(label: "slow", insertText: "slow();", signature: "()", detail: "Triple timeout for test", kind: .dsl),
        CompletionItem(label: "use", insertText: "use({});", signature: "(options)", detail: "Override test options", kind: .dsl, cursorBackOffset: 3),
        CompletionItem(label: "extend", insertText: "extend({});", signature: "(fixtures)", detail: "Create custom fixtures", kind: .dsl, cursorBackOffset: 3),
        CompletionItem(label: "setTimeout", insertText: "setTimeout(60_000);", signature: "(ms)", detail: "Set test timeout in ms", kind: .dsl, cursorBackOffset: 2)
    ]

    public static let builtInPlaywrightPageActions: [CompletionItem] = [
        CompletionItem(label: "goto", insertText: "goto('')", signature: "(url, opts?)", detail: "Navigate to URL", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "getByRole", insertText: "getByRole('button', { name: '' })", signature: "(role, opts?)", detail: "Locate by ARIA role", kind: .action, cursorBackOffset: 4),
        CompletionItem(label: "getByTestId", insertText: "getByTestId('')", signature: "(testId)", detail: "Locate by data-testid", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "getByText", insertText: "getByText('')", signature: "(text, opts?)", detail: "Locate by visible text", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "getByLabel", insertText: "getByLabel('')", signature: "(text, opts?)", detail: "Locate form control by label", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "getByPlaceholder", insertText: "getByPlaceholder('')", signature: "(text, opts?)", detail: "Locate input by placeholder", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "getByAltText", insertText: "getByAltText('')", signature: "(text, opts?)", detail: "Locate image by alt text", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "getByTitle", insertText: "getByTitle('')", signature: "(text, opts?)", detail: "Locate by title attribute", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "locator", insertText: "locator('')", signature: "(selector, opts?)", detail: "Create CSS/XPath locator", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "frameLocator", insertText: "frameLocator('')", signature: "(selector)", detail: "Locate elements inside iframe", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "click", insertText: "click('')", signature: "(selector, opts?)", detail: "Click element", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "fill", insertText: "fill('', '')", signature: "(selector, value)", detail: "Fill input field", kind: .action, cursorBackOffset: 6),
        CompletionItem(label: "press", insertText: "press('', 'Enter')", signature: "(selector, key)", detail: "Press keyboard key", kind: .action, cursorBackOffset: 11),
        CompletionItem(label: "hover", insertText: "hover('')", signature: "(selector)", detail: "Hover over element", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "check", insertText: "check('')", signature: "(selector)", detail: "Check checkbox/radio", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "uncheck", insertText: "uncheck('')", signature: "(selector)", detail: "Uncheck checkbox", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "selectOption", insertText: "selectOption('', '')", signature: "(selector, values)", detail: "Select dropdown option", kind: .action, cursorBackOffset: 6),
        CompletionItem(label: "waitForURL", insertText: "waitForURL('')", signature: "(url, opts?)", detail: "Wait for navigation URL", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "waitForResponse", insertText: "waitForResponse('')", signature: "(urlOrPred, opts?)", detail: "Wait for network response", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "waitForRequest", insertText: "waitForRequest('')", signature: "(urlOrPred, opts?)", detail: "Wait for network request", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "waitForLoadState", insertText: "waitForLoadState('networkidle')", signature: "(state?)", detail: "Wait for load state", kind: .action),
        CompletionItem(label: "route", insertText: "route('**/*', (route) => route.continue())", signature: "(url, handler)", detail: "Intercept network requests", kind: .action),
        CompletionItem(label: "screenshot", insertText: "screenshot({ path: 'screenshot.png' })", signature: "(opts?)", detail: "Capture screenshot", kind: .action),
        CompletionItem(label: "evaluate", insertText: "evaluate(() => {\n  \n})", signature: "(fn, arg?)", detail: "Execute JS in page", kind: .action, cursorBackOffset: 3),
        CompletionItem(label: "reload", insertText: "reload()", signature: "(opts?)", detail: "Reload current page", kind: .action),
        CompletionItem(label: "goBack", insertText: "goBack()", signature: "(opts?)", detail: "Navigate back", kind: .action),
        CompletionItem(label: "setViewportSize", insertText: "setViewportSize({ width: 1440, height: 900 })", signature: "(size)", detail: "Resize viewport", kind: .action),
        CompletionItem(label: "pause", insertText: "pause()", signature: "()", detail: "Pause in Playwright Inspector", kind: .action),
        CompletionItem(label: "title", insertText: "title()", signature: "()", detail: "Return page title", kind: .action),
        CompletionItem(label: "url", insertText: "url()", signature: "()", detail: "Return current URL", kind: .action),
        CompletionItem(label: "content", insertText: "content()", signature: "()", detail: "Return full page HTML", kind: .action),
        CompletionItem(label: "request", insertText: "request", signature: ": APIRequestContext", detail: "Page-scoped APIRequestContext", kind: .symbol),
        CompletionItem(label: "context", insertText: "context()", signature: "()", detail: "Parent BrowserContext", kind: .action),
        CompletionItem(label: "keyboard", insertText: "keyboard", signature: ": Keyboard", detail: "Low-level keyboard input", kind: .symbol),
        CompletionItem(label: "mouse", insertText: "mouse", signature: ": Mouse", detail: "Low-level mouse input", kind: .symbol),
        CompletionItem(label: "close", insertText: "close()", signature: "()", detail: "Close page", kind: .action)
    ]

    public static let builtInPlaywrightFixtureArgs: [CompletionItem] = [
        CompletionItem(label: "page", insertText: "page", signature: ": Page", detail: "Isolated Playwright browser page", kind: .symbol),
        CompletionItem(label: "request", insertText: "request", signature: ": APIRequestContext", detail: "Playwright HTTP / API testing client", kind: .symbol),
        CompletionItem(label: "context", insertText: "context", signature: ": BrowserContext", detail: "Isolated browser context", kind: .symbol),
        CompletionItem(label: "browser", insertText: "browser", signature: ": Browser", detail: "Shared browser instance", kind: .symbol),
        CompletionItem(label: "browserName", insertText: "browserName", signature: ": 'chromium' | 'firefox' | 'webkit'", detail: "Active browser engine name", kind: .symbol),
        CompletionItem(label: "baseURL", insertText: "baseURL", signature: ": string | undefined", detail: "Configured project baseURL", kind: .symbol),
        CompletionItem(label: "viewport", insertText: "viewport", signature: ": ViewportSize | null", detail: "Configured viewport size", kind: .symbol),
        CompletionItem(label: "isMobile", insertText: "isMobile", signature: ": boolean", detail: "Whether mobile emulation is active", kind: .symbol),
        CompletionItem(label: "hasTouch", insertText: "hasTouch", signature: ": boolean", detail: "Whether touch events are enabled", kind: .symbol),
        CompletionItem(label: "locale", insertText: "locale", signature: ": string", detail: "Configured browser locale", kind: .symbol),
        CompletionItem(label: "timezoneId", insertText: "timezoneId", signature: ": string", detail: "Configured timezone identifier", kind: .symbol),
        CompletionItem(label: "storageState", insertText: "storageState", signature: ": StorageState", detail: "Configured cookies & localStorage", kind: .symbol)
    ]

    public static let builtInPlaywrightLocatorActions: [CompletionItem] = [
        CompletionItem(label: "click", insertText: "click()", signature: "(opts?)", detail: "Click matched element", kind: .action),
        CompletionItem(label: "dblclick", insertText: "dblclick()", signature: "(opts?)", detail: "Double-click element", kind: .action),
        CompletionItem(label: "fill", insertText: "fill('')", signature: "(value, opts?)", detail: "Fill input text", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "clear", insertText: "clear()", signature: "(opts?)", detail: "Clear input field", kind: .action),
        CompletionItem(label: "press", insertText: "press('Enter')", signature: "(key, opts?)", detail: "Press key on element", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "pressSequentially", insertText: "pressSequentially('')", signature: "(text, opts?)", detail: "Type character by character", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "hover", insertText: "hover()", signature: "(opts?)", detail: "Hover over element", kind: .action),
        CompletionItem(label: "focus", insertText: "focus()", signature: "(opts?)", detail: "Focus element", kind: .action),
        CompletionItem(label: "check", insertText: "check()", signature: "(opts?)", detail: "Check checkbox/radio", kind: .action),
        CompletionItem(label: "uncheck", insertText: "uncheck()", signature: "(opts?)", detail: "Uncheck checkbox", kind: .action),
        CompletionItem(label: "selectOption", insertText: "selectOption('')", signature: "(values, opts?)", detail: "Select option", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "setInputFiles", insertText: "setInputFiles('')", signature: "(files)", detail: "Upload file(s)", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "waitFor", insertText: "waitFor({ state: 'visible' })", signature: "(opts?)", detail: "Wait for locator state", kind: .action),
        CompletionItem(label: "scrollIntoViewIfNeeded", insertText: "scrollIntoViewIfNeeded()", signature: "()", detail: "Scroll element into view", kind: .action),
        CompletionItem(label: "textContent", insertText: "textContent()", signature: "()", detail: "Read textContent", kind: .action),
        CompletionItem(label: "innerText", insertText: "innerText()", signature: "()", detail: "Read innerText", kind: .action),
        CompletionItem(label: "inputValue", insertText: "inputValue()", signature: "()", detail: "Read input value", kind: .action),
        CompletionItem(label: "getAttribute", insertText: "getAttribute('')", signature: "(name)", detail: "Read HTML attribute", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "isVisible", insertText: "isVisible()", signature: "()", detail: "Check immediate visibility", kind: .action),
        CompletionItem(label: "isEnabled", insertText: "isEnabled()", signature: "()", detail: "Check enabled state", kind: .action),
        CompletionItem(label: "isChecked", insertText: "isChecked()", signature: "()", detail: "Check checked state", kind: .action),
        CompletionItem(label: "count", insertText: "count()", signature: "()", detail: "Count matched elements", kind: .action),
        CompletionItem(label: "first", insertText: "first()", signature: "()", detail: "First matched element", kind: .action),
        CompletionItem(label: "last", insertText: "last()", signature: "()", detail: "Last matched element", kind: .action),
        CompletionItem(label: "nth", insertText: "nth(0)", signature: "(index)", detail: "Nth matched element", kind: .action, cursorBackOffset: 1),
        CompletionItem(label: "filter", insertText: "filter({ hasText: '' })", signature: "(opts)", detail: "Narrow locator matches", kind: .action, cursorBackOffset: 4),
        CompletionItem(label: "screenshot", insertText: "screenshot()", signature: "(opts?)", detail: "Screenshot element", kind: .action)
    ]

    public static let builtInPlaywrightRequestActions: [CompletionItem] = [
        CompletionItem(label: "get", insertText: "get('')", signature: "(url, opts?)", detail: "HTTP GET request", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "post", insertText: "post('', { data: {} })", signature: "(url, opts?)", detail: "HTTP POST request", kind: .action, cursorBackOffset: 15),
        CompletionItem(label: "put", insertText: "put('', { data: {} })", signature: "(url, opts?)", detail: "HTTP PUT request", kind: .action, cursorBackOffset: 15),
        CompletionItem(label: "patch", insertText: "patch('', { data: {} })", signature: "(url, opts?)", detail: "HTTP PATCH request", kind: .action, cursorBackOffset: 15),
        CompletionItem(label: "delete", insertText: "delete('')", signature: "(url, opts?)", detail: "HTTP DELETE request", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "head", insertText: "head('')", signature: "(url, opts?)", detail: "HTTP HEAD request", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "fetch", insertText: "fetch('', { method: 'GET' })", signature: "(urlOrReq, opts?)", detail: "Generic HTTP request", kind: .action, cursorBackOffset: 21),
        CompletionItem(label: "storageState", insertText: "storageState()", signature: "(opts?)", detail: "Export cookies & storage", kind: .action),
        CompletionItem(label: "dispose", insertText: "dispose()", signature: "()", detail: "Dispose APIRequestContext", kind: .action)
    ]

    public static let builtInPlaywrightResponseActions: [CompletionItem] = [
        CompletionItem(label: "ok", insertText: "ok()", signature: "()", detail: "True if HTTP status is 2xx", kind: .action),
        CompletionItem(label: "status", insertText: "status()", signature: "()", detail: "HTTP status code (e.g. 200)", kind: .action),
        CompletionItem(label: "statusText", insertText: "statusText()", signature: "()", detail: "HTTP status text (e.g. OK)", kind: .action),
        CompletionItem(label: "json", insertText: "json()", signature: "()", detail: "Parse JSON response body", kind: .action),
        CompletionItem(label: "text", insertText: "text()", signature: "()", detail: "Read response body as UTF-8 text", kind: .action),
        CompletionItem(label: "body", insertText: "body()", signature: "()", detail: "Read raw response Buffer", kind: .action),
        CompletionItem(label: "headers", insertText: "headers()", signature: "()", detail: "Response headers dictionary", kind: .action),
        CompletionItem(label: "headersArray", insertText: "headersArray()", signature: "()", detail: "Raw response header pairs", kind: .action),
        CompletionItem(label: "url", insertText: "url()", signature: "()", detail: "Final response URL", kind: .action),
        CompletionItem(label: "dispose", insertText: "dispose()", signature: "()", detail: "Release response body buffer", kind: .action)
    ]

    public static let builtInPlaywrightContextActions: [CompletionItem] = [
        CompletionItem(label: "newPage", insertText: "newPage()", signature: "()", detail: "Open a new page in context", kind: .action),
        CompletionItem(label: "pages", insertText: "pages()", signature: "()", detail: "List open pages in context", kind: .action),
        CompletionItem(label: "cookies", insertText: "cookies()", signature: "(urls?)", detail: "Read context cookies", kind: .action),
        CompletionItem(label: "addCookies", insertText: "addCookies([])", signature: "(cookies)", detail: "Add cookies to context", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "clearCookies", insertText: "clearCookies()", signature: "(opts?)", detail: "Clear context cookies", kind: .action),
        CompletionItem(label: "storageState", insertText: "storageState({ path: '' })", signature: "(opts?)", detail: "Export cookies & localStorage", kind: .action, cursorBackOffset: 4),
        CompletionItem(label: "route", insertText: "route('**/*', (route) => route.continue())", signature: "(url, handler)", detail: "Intercept context requests", kind: .action),
        CompletionItem(label: "unroute", insertText: "unroute('**/*')", signature: "(url, handler?)", detail: "Remove route interceptor", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "setExtraHTTPHeaders", insertText: "setExtraHTTPHeaders({})", signature: "(headers)", detail: "Add default HTTP headers", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "grantPermissions", insertText: "grantPermissions([''])", signature: "(permissions, opts?)", detail: "Grant browser permissions", kind: .action, cursorBackOffset: 3),
        CompletionItem(label: "clearPermissions", insertText: "clearPermissions()", signature: "()", detail: "Reset browser permissions", kind: .action),
        CompletionItem(label: "setGeolocation", insertText: "setGeolocation({ latitude: 0, longitude: 0 })", signature: "(geo)", detail: "Mock geolocation", kind: .action),
        CompletionItem(label: "setOffline", insertText: "setOffline(true)", signature: "(offline)", detail: "Simulate offline network", kind: .action, cursorBackOffset: 1),
        CompletionItem(label: "waitForEvent", insertText: "waitForEvent('page')", signature: "(event, opts?)", detail: "Wait for context event", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "request", insertText: "request", signature: ": APIRequestContext", detail: "Context APIRequestContext", kind: .symbol),
        CompletionItem(label: "browser", insertText: "browser()", signature: "()", detail: "Owning Browser instance", kind: .action),
        CompletionItem(label: "close", insertText: "close()", signature: "()", detail: "Close browser context", kind: .action)
    ]

    public static let builtInPlaywrightBrowserActions: [CompletionItem] = [
        CompletionItem(label: "newContext", insertText: "newContext()", signature: "(opts?)", detail: "Create isolated BrowserContext", kind: .action),
        CompletionItem(label: "newPage", insertText: "newPage()", signature: "(opts?)", detail: "Create page in new context", kind: .action),
        CompletionItem(label: "contexts", insertText: "contexts()", signature: "()", detail: "List open browser contexts", kind: .action),
        CompletionItem(label: "version", insertText: "version()", signature: "()", detail: "Browser engine version", kind: .action),
        CompletionItem(label: "isConnected", insertText: "isConnected()", signature: "()", detail: "Check browser connection", kind: .action),
        CompletionItem(label: "browserType", insertText: "browserType()", signature: "()", detail: "BrowserType (chromium/firefox/webkit)", kind: .action),
        CompletionItem(label: "close", insertText: "close()", signature: "()", detail: "Close browser instance", kind: .action)
    ]

    public static let builtInPlaywrightTestInfoMembers: [CompletionItem] = [
        CompletionItem(label: "title", insertText: "title", signature: ": string", detail: "Current test title", kind: .symbol),
        CompletionItem(label: "titlePath", insertText: "titlePath", signature: ": string[]", detail: "Full file & describe path", kind: .symbol),
        CompletionItem(label: "project", insertText: "project", signature: ": FullProject", detail: "Active Playwright project config", kind: .symbol),
        CompletionItem(label: "retry", insertText: "retry", signature: ": number", detail: "Current retry attempt index", kind: .symbol),
        CompletionItem(label: "workerIndex", insertText: "workerIndex", signature: ": number", detail: "Unique worker index", kind: .symbol),
        CompletionItem(label: "status", insertText: "status", signature: ": TestStatus", detail: "Actual execution status", kind: .symbol),
        CompletionItem(label: "expectedStatus", insertText: "expectedStatus", signature: ": TestStatus", detail: "Expected test status", kind: .symbol),
        CompletionItem(label: "duration", insertText: "duration", signature: ": number", detail: "Elapsed duration in ms", kind: .symbol),
        CompletionItem(label: "annotations", insertText: "annotations", signature: ": Annotation[]", detail: "Test metadata annotations", kind: .symbol),
        CompletionItem(label: "attachments", insertText: "attachments", signature: ": TestInfoAttachment[]", detail: "Attached files & artifacts", kind: .symbol),
        CompletionItem(label: "outputDir", insertText: "outputDir", signature: ": string", detail: "Per-test artifact directory", kind: .symbol),
        CompletionItem(label: "attach", insertText: "attach('', { body: '', contentType: 'text/plain' })", signature: "(name, opts)", detail: "Attach artifact to test report", kind: .action, cursorBackOffset: 43),
        CompletionItem(label: "outputPath", insertText: "outputPath('')", signature: "(...segments)", detail: "Resolve test artifact path", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "snapshotPath", insertText: "snapshotPath('')", signature: "(...segments)", detail: "Resolve snapshot path", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "skip", insertText: "skip()", signature: "(condition?, description?)", detail: "Skip test dynamically", kind: .action),
        CompletionItem(label: "fixme", insertText: "fixme()", signature: "(condition?, description?)", detail: "Mark test as fixme", kind: .action),
        CompletionItem(label: "fail", insertText: "fail()", signature: "(condition?, description?)", detail: "Expect test to fail", kind: .action),
        CompletionItem(label: "slow", insertText: "slow()", signature: "(condition?, description?)", detail: "Triple test timeout", kind: .action),
        CompletionItem(label: "setTimeout", insertText: "setTimeout(60_000)", signature: "(ms)", detail: "Override test timeout", kind: .action, cursorBackOffset: 1)
    ]

    public static let builtInPlaywrightRouteActions: [CompletionItem] = [
        CompletionItem(label: "continue", insertText: "continue()", signature: "(overrides?)", detail: "Continue request to network", kind: .action),
        CompletionItem(label: "fulfill", insertText: "fulfill({ status: 200, json: {} })", signature: "(response)", detail: "Mock HTTP response", kind: .action, cursorBackOffset: 3),
        CompletionItem(label: "abort", insertText: "abort()", signature: "(errorCode?)", detail: "Abort network request", kind: .action),
        CompletionItem(label: "fetch", insertText: "fetch()", signature: "(overrides?)", detail: "Perform request & inspect response", kind: .action),
        CompletionItem(label: "fallback", insertText: "fallback()", signature: "(overrides?)", detail: "Delegate to next route handler", kind: .action),
        CompletionItem(label: "request", insertText: "request()", signature: "()", detail: "Intercepted Request object", kind: .action)
    ]

    public static let builtInPlaywrightKeyboardActions: [CompletionItem] = [
        CompletionItem(label: "press", insertText: "press('Enter')", signature: "(key, opts?)", detail: "Press & release key", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "type", insertText: "type('')", signature: "(text, opts?)", detail: "Type text with key events", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "insertText", insertText: "insertText('')", signature: "(text)", detail: "Insert text directly", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "down", insertText: "down('')", signature: "(key)", detail: "Hold key down", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "up", insertText: "up('')", signature: "(key)", detail: "Release held key", kind: .action, cursorBackOffset: 2)
    ]

    public static let builtInPlaywrightMouseActions: [CompletionItem] = [
        CompletionItem(label: "click", insertText: "click(0, 0)", signature: "(x, y, opts?)", detail: "Click at viewport coordinates", kind: .action, cursorBackOffset: 1),
        CompletionItem(label: "dblclick", insertText: "dblclick(0, 0)", signature: "(x, y, opts?)", detail: "Double-click at coordinates", kind: .action, cursorBackOffset: 1),
        CompletionItem(label: "move", insertText: "move(0, 0)", signature: "(x, y, opts?)", detail: "Move mouse cursor", kind: .action, cursorBackOffset: 1),
        CompletionItem(label: "down", insertText: "down()", signature: "(opts?)", detail: "Press mouse button", kind: .action),
        CompletionItem(label: "up", insertText: "up()", signature: "(opts?)", detail: "Release mouse button", kind: .action),
        CompletionItem(label: "wheel", insertText: "wheel(0, 100)", signature: "(deltaX, deltaY)", detail: "Dispatch scroll wheel event", kind: .action, cursorBackOffset: 1)
    ]

    public static let builtInPlaywrightExpectMatchers: [CompletionItem] = [
        CompletionItem(label: "toBeVisible", insertText: "toBeVisible()", signature: "(opts?)", detail: "Assert locator is visible", kind: .action),
        CompletionItem(label: "toBeHidden", insertText: "toBeHidden()", signature: "(opts?)", detail: "Assert locator is hidden", kind: .action),
        CompletionItem(label: "toBeEnabled", insertText: "toBeEnabled()", signature: "(opts?)", detail: "Assert locator is enabled", kind: .action),
        CompletionItem(label: "toBeDisabled", insertText: "toBeDisabled()", signature: "(opts?)", detail: "Assert locator is disabled", kind: .action),
        CompletionItem(label: "toBeChecked", insertText: "toBeChecked()", signature: "(opts?)", detail: "Assert checkbox is checked", kind: .action),
        CompletionItem(label: "toBeFocused", insertText: "toBeFocused()", signature: "(opts?)", detail: "Assert element has focus", kind: .action),
        CompletionItem(label: "toHaveText", insertText: "toHaveText('')", signature: "(expected, opts?)", detail: "Assert exact/regex text", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "toContainText", insertText: "toContainText('')", signature: "(expected, opts?)", detail: "Assert substring text", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "toHaveValue", insertText: "toHaveValue('')", signature: "(value, opts?)", detail: "Assert input value", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "toHaveAttribute", insertText: "toHaveAttribute('', '')", signature: "(name, value)", detail: "Assert DOM attribute", kind: .action, cursorBackOffset: 6),
        CompletionItem(label: "toHaveClass", insertText: "toHaveClass('')", signature: "(expected)", detail: "Assert CSS class", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "toHaveCount", insertText: "toHaveCount(1)", signature: "(count)", detail: "Assert matched element count", kind: .action, cursorBackOffset: 1),
        CompletionItem(label: "toHaveURL", insertText: "toHaveURL('')", signature: "(urlOrRegex)", detail: "Assert page URL", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "toHaveTitle", insertText: "toHaveTitle('')", signature: "(titleOrRegex)", detail: "Assert page title", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "toHaveScreenshot", insertText: "toHaveScreenshot()", signature: "(name?, opts?)", detail: "Visual regression assertion", kind: .action),
        CompletionItem(label: "toBeOK", insertText: "toBeOK()", signature: "()", detail: "Assert HTTP 2xx APIResponse", kind: .action),
        CompletionItem(label: "toEqual", insertText: "toEqual()", signature: "(expected)", detail: "Deep equality assertion", kind: .action, cursorBackOffset: 1),
        CompletionItem(label: "toContain", insertText: "toContain()", signature: "(item)", detail: "Assert array/string contains", kind: .action, cursorBackOffset: 1),
        CompletionItem(label: "toBeTruthy", insertText: "toBeTruthy()", signature: "()", detail: "Assert truthy value", kind: .action),
        CompletionItem(label: "toMatchObject", insertText: "toMatchObject({})", signature: "(subset)", detail: "Assert object subset match", kind: .action, cursorBackOffset: 2),
        CompletionItem(label: "not", insertText: "not.", signature: "", detail: "Negate matcher", kind: .dsl)
    ]
}
