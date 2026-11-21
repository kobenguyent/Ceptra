import Foundation

public enum NavigationKind: String, Equatable, Hashable, Sendable {
    case declaration
    case usage
    case modulePath
    case stepDefinition
}

public struct NavigationTarget: Equatable, Hashable, Sendable {
    public let fileURL: URL
    public let lineNumber: Int?
    public let columnNumber: Int?
    public let displayLabel: String
    public let symbolName: String?
    public let previewText: String?
    public let isSymlink: Bool
    public let kind: NavigationKind

    public init(
        fileURL: URL,
        lineNumber: Int? = nil,
        columnNumber: Int? = nil,
        displayLabel: String,
        symbolName: String? = nil,
        previewText: String? = nil,
        isSymlink: Bool = false,
        kind: NavigationKind = .declaration
    ) {
        self.fileURL = fileURL
        self.lineNumber = lineNumber
        self.columnNumber = columnNumber
        self.displayLabel = displayLabel
        self.symbolName = symbolName
        self.previewText = previewText
        self.isSymlink = isSymlink
        self.kind = kind
    }
}

public struct NavigableSpan: Equatable, Sendable {
    public let range: NSRange // UTF-16 range inside the source text
    public let specifier: String
    public let target: NavigationTarget
    public let targets: [NavigationTarget]
    public let kind: NavigationKind

    public var hasMultipleTargets: Bool {
        targets.count > 1
    }

    public init(
        range: NSRange,
        specifier: String,
        target: NavigationTarget,
        targets: [NavigationTarget]? = nil,
        kind: NavigationKind? = nil
    ) {
        self.range = range
        self.specifier = specifier
        self.target = target
        let resolvedTargets = (targets?.isEmpty == false) ? targets! : [target]
        self.targets = resolvedTargets
        self.kind = kind ?? target.kind
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

    private static let reservedKeywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "break", "continue",
        "return", "throw", "try", "catch", "finally", "const", "let", "var",
        "function", "class", "extends", "implements", "interface", "type", "enum",
        "import", "export", "from", "default", "async", "await", "new", "typeof",
        "instanceof", "void", "delete", "in", "of", "true", "false", "null", "undefined",
        "this", "super", "Feature", "Scenario", "xScenario", "Before", "After",
        "BeforeSuite", "AfterSuite", "Data", "Given", "When", "Then", "And", "But"
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
                    let target = NavigationTarget(
                        fileURL: resolved.fileURL,
                        lineNumber: resolved.lineNumber,
                        displayLabel: resolved.displayLabel,
                        isSymlink: resolved.isSymlink,
                        kind: .modulePath
                    )
                    spans.append(NavigableSpan(range: specRange, specifier: specifier, target: target, kind: .modulePath))
                }
            }
        }

        return spans.sorted { $0.range.location < $1.range.location }
    }

    /// PyCharm-style multi-hop resolver: resolves whatever is at `utf16Offset` in `source` to its true root
    /// implementation (or call-site usages when invoked directly on a declaration).
    public static func resolveTarget(
        atUTF16Offset offset: Int,
        in source: String,
        sourceFileURL: URL,
        workspaceRoot: URL,
        config: CodeceptConfigSummary? = nil,
        workspaceFiles: [WorkspaceFile] = []
    ) -> NavigableSpan? {
        let ns = source as NSString
        guard offset >= 0, offset <= ns.length else { return nil }

        // Stage 1: Direct import / require / config path string literal under cursor
        let importSpans = findNavigableImportSpans(
            in: source,
            sourceFileURL: sourceFileURL,
            workspaceRoot: workspaceRoot,
            config: config
        )
        if let hit = importSpans.first(where: { offset >= $0.range.location && offset <= NSMaxRange($0.range) }) {
            return hit
        }

        // Stage 2: Gherkin `.feature` step line -> `Given / When / Then` step definition implementation
        if sourceFileURL.pathExtension.lowercased() == "feature" {
            if let gherkinHit = resolveGherkinStepLine(
                atUTF16Offset: offset,
                in: source,
                workspaceRoot: workspaceRoot,
                config: config,
                workspaceFiles: workspaceFiles
            ) {
                return gherkinHit
            }
        }

        // Extract identifier under cursor
        guard let wordInfo = identifierAt(offset: offset, in: ns),
              !reservedKeywords.contains(wordInfo.word) else {
            return nil
        }

        let currentLine = lineNumber(atUTF16Offset: wordInfo.range.location, in: ns)
        let receiver = precedingReceiver(before: wordInfo.range.location, in: ns)
        let importedBindings = parseImportedBindings(in: source)
        let localBindings = parseLocalBindings(in: source)

        // Stage 3: `this.<member>` inside a PageObject, Helper, or Class (plus `extends` inheritance chain)
        if receiver == "this" {
            if let selfHit = resolveMemberInFileOrAncestors(
                memberName: wordInfo.word,
                fileURL: sourceFileURL,
                fileContent: source,
                workspaceRoot: workspaceRoot,
                config: config,
                visited: []
            ) {
                return NavigableSpan(range: wordInfo.range, specifier: "this.\(wordInfo.word)", target: selfHit)
            }
        }

        // Stage 4: `receiver.member` (Imported module/class, Local `new Class()`, `inject()`, CodeceptJS `include`, or `I.<step>`)
        if let receiver, receiver != "this" {
            // 4a. Local `const page = new ClassName()` or `const page = alias`
            if let local = localBindings[receiver] {
                if let targetHit = resolveViaLocalBinding(
                    local,
                    memberName: wordInfo.word,
                    in: source,
                    sourceFileURL: sourceFileURL,
                    importedBindings: importedBindings,
                    workspaceRoot: workspaceRoot,
                    config: config
                ) {
                    return NavigableSpan(range: wordInfo.range, specifier: "\(receiver).\(wordInfo.word)", target: targetHit)
                }
            }

            // 4b. Imported namespace / default / class (`import CheckoutPage from ...`)
            if let binding = importedBindings[receiver],
               let resolved = resolveImportPath(
                   specifier: binding.specifier,
                   fromFileURL: sourceFileURL,
                   workspaceRoot: workspaceRoot,
                   config: config
               ) {
                if let rootHit = resolveRootSymbol(
                    exportedSymbol: binding.exportedName,
                    memberName: wordInfo.word,
                    inFileURL: resolved.fileURL,
                    isSymlink: resolved.isSymlink,
                    workspaceRoot: workspaceRoot,
                    config: config,
                    visited: []
                ) {
                    return NavigableSpan(range: wordInfo.range, specifier: "\(receiver).\(wordInfo.word)", target: rootHit)
                }
            }

            // 4c. CodeceptJS `I.<step>` — Implementation-First Resolution (`include.I` -> custom helpers -> step files -> `steps.d.ts`)
            if receiver == "I" {
                if let actorHit = resolveActorMethodImplementationFirst(
                    methodName: wordInfo.word,
                    fromFileURL: sourceFileURL,
                    workspaceRoot: workspaceRoot,
                    config: config,
                    workspaceFiles: workspaceFiles
                ) {
                    return NavigableSpan(range: wordInfo.range, specifier: "I.\(wordInfo.word)", target: actorHit)
                }
            }

            // 4d. Configured CodeceptJS `include` object (`checkoutPage.submitOrder`, `loginPage.login`)
            if let config,
               let inc = config.includes.first(where: { $0.alias == receiver }),
               let resolved = resolveIncludeEntry(inc, workspaceRoot: workspaceRoot, config: config) {
                if let rootHit = resolveRootSymbol(
                    exportedSymbol: inc.alias,
                    memberName: wordInfo.word,
                    inFileURL: resolved.fileURL,
                    isSymlink: resolved.isSymlink,
                    workspaceRoot: workspaceRoot,
                    config: config,
                    visited: []
                ) {
                    return NavigableSpan(range: wordInfo.range, specifier: "\(receiver).\(wordInfo.word)", target: rootHit)
                }
            }

            // 4e. Same-file object or class named `receiver`
            if let sameFileHit = resolveMemberInFileOrAncestors(
                memberName: wordInfo.word,
                fileURL: sourceFileURL,
                fileContent: source,
                workspaceRoot: workspaceRoot,
                config: config,
                visited: []
            ), sameFileHit.lineNumber != currentLine {
                return NavigableSpan(range: wordInfo.range, specifier: "\(receiver).\(wordInfo.word)", target: sameFileHit)
            }
        }

        // Stage 5: Standalone Identifier (Destructured method, Imported symbol, Same-file declaration, or `include` alias)
        if receiver == nil {
            // 5a. Local destructured method or alias (`const { submitOrder } = checkoutPage; await submitOrder()`)
            if let local = localBindings[wordInfo.word] {
                switch local {
                case .destructuredMember(let sourceObject, let propertyName):
                    if sourceObject == "inject()" {
                        if let config,
                           let inc = config.includes.first(where: { $0.alias == propertyName }),
                           let resolved = resolveIncludeEntry(inc, workspaceRoot: workspaceRoot, config: config) {
                            let rootTarget = resolveRootSymbol(
                                exportedSymbol: propertyName,
                                memberName: nil,
                                inFileURL: resolved.fileURL,
                                isSymlink: resolved.isSymlink,
                                workspaceRoot: workspaceRoot,
                                config: config,
                                visited: []
                            ) ?? resolved
                            return NavigableSpan(range: wordInfo.range, specifier: wordInfo.word, target: rootTarget)
                        }
                    } else if let targetHit = resolveReceiverMember(
                        receiver: sourceObject,
                        memberName: propertyName,
                        in: source,
                        sourceFileURL: sourceFileURL,
                        importedBindings: importedBindings,
                        localBindings: localBindings,
                        workspaceRoot: workspaceRoot,
                        config: config
                    ) {
                        return NavigableSpan(range: wordInfo.range, specifier: wordInfo.word, target: targetHit)
                    }
                case .classInstance(let className, let declLine):
                    if currentLine != declLine {
                        if let classTarget = resolveClassDeclaration(
                            className: className,
                            in: source,
                            sourceFileURL: sourceFileURL,
                            importedBindings: importedBindings,
                            workspaceRoot: workspaceRoot,
                            config: config
                        ) {
                            return NavigableSpan(range: wordInfo.range, specifier: wordInfo.word, target: classTarget)
                        }
                    }
                case .alias(let targetName, let declLine):
                    if currentLine != declLine,
                       let aliasedTarget = resolveStandaloneSymbol(
                           named: targetName,
                           currentLine: currentLine,
                           in: source,
                           sourceFileURL: sourceFileURL,
                           importedBindings: importedBindings,
                           workspaceRoot: workspaceRoot,
                           config: config
                       ) {
                        return NavigableSpan(range: wordInfo.range, specifier: wordInfo.word, target: aliasedTarget)
                    }
                }
            }

            // 5b. Direct imported symbol (`import { defaultHeaders, CheckoutPage } from ...`)
            if let binding = importedBindings[wordInfo.word],
               let resolved = resolveImportPath(
                   specifier: binding.specifier,
                   fromFileURL: sourceFileURL,
                   workspaceRoot: workspaceRoot,
                   config: config
               ) {
                let rootTarget = resolveRootSymbol(
                    exportedSymbol: binding.exportedName,
                    memberName: nil,
                    inFileURL: resolved.fileURL,
                    isSymlink: resolved.isSymlink,
                    workspaceRoot: workspaceRoot,
                    config: config,
                    visited: []
                ) ?? resolved
                return NavigableSpan(range: wordInfo.range, specifier: wordInfo.word, target: rootTarget)
            }

            // 5c. Direct CodeceptJS `include` alias under cursor (e.g., `async ({ I, checkoutPage })`)
            if let config,
               let inc = config.includes.first(where: { $0.alias == wordInfo.word }),
               let resolved = resolveIncludeEntry(inc, workspaceRoot: workspaceRoot, config: config) {
                let rootTarget = resolveRootSymbol(
                    exportedSymbol: inc.alias,
                    memberName: nil,
                    inFileURL: resolved.fileURL,
                    isSymlink: resolved.isSymlink,
                    workspaceRoot: workspaceRoot,
                    config: config,
                    visited: []
                ) ?? resolved
                return NavigableSpan(range: wordInfo.range, specifier: wordInfo.word, target: rootTarget)
            }

            // 5d. Same-file function / method / class / variable declaration
            if let sameFileDecl = findSymbolDeclaration(
                named: wordInfo.word,
                inContent: source,
                fileURL: sourceFileURL,
                workspaceRoot: workspaceRoot
            ) {
                if sameFileDecl.lineNumber != currentLine {
                    return NavigableSpan(range: wordInfo.range, specifier: wordInfo.word, target: sameFileDecl)
                } else {
                    // Stage 7: Cursor IS on the declaration line itself -> PyCharm Reverse Usage Lookup!
                    let usages = findWorkspaceUsages(
                        symbol: wordInfo.word,
                        declarationFileURL: sourceFileURL,
                        declarationLine: currentLine,
                        currentSource: source,
                        workspaceRoot: workspaceRoot,
                        workspaceFiles: workspaceFiles
                    )
                    if let firstUsage = usages.first {
                        return NavigableSpan(
                            range: wordInfo.range,
                            specifier: wordInfo.word,
                            target: firstUsage,
                            targets: usages,
                            kind: .usage
                        )
                    }
                    // If no external usages exist yet, still return the declaration itself so F12/Cmd+Click gives feedback
                    return NavigableSpan(range: wordInfo.range, specifier: wordInfo.word, target: sameFileDecl)
                }
            }
        }

        // Stage 6: Workspace-Wide Method & Symbol Fallback Index
        let workspaceCandidates = findWorkspaceDeclarations(
            symbol: wordInfo.word,
            excludingFileURL: sourceFileURL,
            excludingLine: currentLine,
            workspaceRoot: workspaceRoot,
            workspaceFiles: workspaceFiles
        )
        if let primary = workspaceCandidates.first {
            return NavigableSpan(
                range: wordInfo.range,
                specifier: receiver.map { "\($0).\(wordInfo.word)" } ?? wordInfo.word,
                target: primary,
                targets: workspaceCandidates,
                kind: .declaration
            )
        }

        return nil
    }

    // MARK: - Transitive Root Symbol & Inheritance Resolution

    private static func resolveRootSymbol(
        exportedSymbol: String?,
        memberName: String?,
        inFileURL fileURL: URL,
        isSymlink: Bool,
        workspaceRoot: URL,
        config: CodeceptConfigSummary?,
        visited: Set<String>
    ) -> NavigationTarget? {
        let stdPath = fileURL.standardizedFileURL.path
        guard visited.count < 8, !visited.contains(stdPath),
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        var nextVisited = visited
        nextVisited.insert(stdPath)
        let symlinkFlag = isSymlink || isSymlinkPath(fileURL)

        // 1. If we're looking for a specific member (e.g. `checkoutPage.submitOrder`), check if it's declared in this file
        if let memberName {
            if let directMember = findSymbolDeclaration(
                named: memberName,
                inContent: content,
                fileURL: fileURL,
                workspaceRoot: workspaceRoot,
                isSymlink: symlinkFlag
            ) {
                return directMember
            }
        }

        // 2. Check barrel re-exports in `fileURL` (`export { ... } from './...'`, `export * from './...'`, `module.exports = require(...)`)
        let targetSymbolForExport = exportedSymbol ?? memberName
        for reExport in parseReExports(in: content) {
            let matchesSymbol: Bool
            let nextExportedSymbol: String?
            switch reExport.kind {
            case .named(let exportedAs, let localOriginal):
                if let sym = targetSymbolForExport, exportedAs == sym {
                    matchesSymbol = true
                    nextExportedSymbol = (localOriginal == "default") ? nil : localOriginal
                } else if exportedAs == "default" {
                    matchesSymbol = true
                    nextExportedSymbol = (localOriginal == "default") ? nil : localOriginal
                } else {
                    matchesSymbol = false
                    nextExportedSymbol = nil
                }
            case .wildcard:
                matchesSymbol = true
                nextExportedSymbol = exportedSymbol
            }

            guard matchesSymbol,
                  let resolvedNext = resolveImportPath(
                      specifier: reExport.specifier,
                      fromFileURL: fileURL,
                      workspaceRoot: workspaceRoot,
                      config: config
                  ) else {
                continue
            }

            if let hopped = resolveRootSymbol(
                exportedSymbol: nextExportedSymbol,
                memberName: memberName,
                inFileURL: resolvedNext.fileURL,
                isSymlink: symlinkFlag || resolvedNext.isSymlink,
                workspaceRoot: workspaceRoot,
                config: config,
                visited: nextVisited
            ) {
                return hopped
            }
        }

        // 3. Check if `fileURL` imports a local symbol and then exports it (`import X from './X'; export default X` or `export default new X()`)
        let localImports = parseImportedBindings(in: content)
        if let sym = targetSymbolForExport, let imp = localImports[sym],
           let resolvedNext = resolveImportPath(specifier: imp.specifier, fromFileURL: fileURL, workspaceRoot: workspaceRoot, config: config) {
            if let hopped = resolveRootSymbol(
                exportedSymbol: imp.exportedName,
                memberName: memberName,
                inFileURL: resolvedNext.fileURL,
                isSymlink: symlinkFlag || resolvedNext.isSymlink,
                workspaceRoot: workspaceRoot,
                config: config,
                visited: nextVisited
            ) {
                return hopped
            }
        }

        // 4. If looking for `memberName`, check `class ... extends BaseClass` inheritance chain in `fileURL`!
        if let memberName {
            for baseClassName in extractExtendedBaseClasses(in: content) {
                if let imp = localImports[baseClassName],
                   let resolvedBase = resolveImportPath(
                       specifier: imp.specifier,
                       fromFileURL: fileURL,
                       workspaceRoot: workspaceRoot,
                       config: config
                   ),
                   let inherited = resolveRootSymbol(
                       exportedSymbol: imp.exportedName,
                       memberName: memberName,
                       inFileURL: resolvedBase.fileURL,
                       isSymlink: symlinkFlag || resolvedBase.isSymlink,
                       workspaceRoot: workspaceRoot,
                       config: config,
                       visited: nextVisited
                   ) {
                    return inherited
                }
            }
        }

        // 5. If no `memberName` (navigating to the symbol/module itself), locate `exportedSymbol` in `fileURL`
        if memberName == nil {
            if let exportedSymbol,
               let decl = findSymbolDeclaration(
                   named: exportedSymbol,
                   inContent: content,
                   fileURL: fileURL,
                   workspaceRoot: workspaceRoot,
                   isSymlink: symlinkFlag
               ) {
                return decl
            }
            let relLabel = relativeDisplay(fileURL, to: workspaceRoot)
            return NavigationTarget(
                fileURL: fileURL,
                lineNumber: nil,
                displayLabel: relLabel,
                symbolName: exportedSymbol,
                isSymlink: symlinkFlag,
                kind: .declaration
            )
        }

        return nil
    }

    private static func resolveMemberInFileOrAncestors(
        memberName: String,
        fileURL: URL,
        fileContent: String,
        workspaceRoot: URL,
        config: CodeceptConfigSummary?,
        visited: Set<String>
    ) -> NavigationTarget? {
        if let direct = findSymbolDeclaration(
            named: memberName,
            inContent: fileContent,
            fileURL: fileURL,
            workspaceRoot: workspaceRoot
        ) {
            return direct
        }
        let localImports = parseImportedBindings(in: fileContent)
        for baseClass in extractExtendedBaseClasses(in: fileContent) {
            if let imp = localImports[baseClass],
               let resolvedBase = resolveImportPath(
                   specifier: imp.specifier,
                   fromFileURL: fileURL,
                   workspaceRoot: workspaceRoot,
                   config: config
               ),
               let inherited = resolveRootSymbol(
                   exportedSymbol: imp.exportedName,
                   memberName: memberName,
                   inFileURL: resolvedBase.fileURL,
                   isSymlink: resolvedBase.isSymlink,
                   workspaceRoot: workspaceRoot,
                   config: config,
                   visited: visited
               ) {
                return inherited
            }
        }
        return nil
    }

    // MARK: - Implementation-First `I.<method>` Resolution

    private static func resolveActorMethodImplementationFirst(
        methodName: String,
        fromFileURL: URL,
        workspaceRoot: URL,
        config: CodeceptConfigSummary?,
        workspaceFiles: [WorkspaceFile]
    ) -> NavigationTarget? {
        var implementationFiles: [URL] = []
        var typeStubFiles: [URL] = []
        var seenPaths = Set<String>()

        func appendCandidate(_ url: URL, isStub: Bool) {
            let std = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: std.path),
                  seenPaths.insert(std.path).inserted else { return }
            if isStub || std.path.lowercased().hasSuffix(".d.ts") {
                typeStubFiles.append(std)
            } else {
                implementationFiles.append(std)
            }
        }

        if let config {
            let testRoot = config.resolvedTestRootURL(workspaceRoot: workspaceRoot)
            // Priority 1: `include.I` (e.g. `steps_file.ts` or `custom.steps.ts`)
            for inc in config.includes where inc.alias == "I" {
                if let resolved = resolveIncludeEntry(inc, workspaceRoot: workspaceRoot, config: config) {
                    appendCandidate(resolved.fileURL, isStub: false)
                }
            }
            // Priority 2: Custom helpers (`helpers.*.require`)
            for helper in config.helpers {
                if let req = helper.requirePath {
                    for anchor in configAnchorFiles(workspaceRoot: workspaceRoot, config: config) {
                        if let resolved = resolveImportPath(specifier: req, fromFileURL: anchor, workspaceRoot: workspaceRoot, config: config) {
                            appendCandidate(resolved.fileURL, isStub: false)
                            break
                        }
                    }
                }
            }
            // Priority 4 (fallback): `steps.d.ts`
            appendCandidate(testRoot.appendingPathComponent("steps.d.ts"), isStub: true)
        }
        appendCandidate(workspaceRoot.appendingPathComponent("steps.d.ts"), isStub: true)

        // Priority 3: Workspace helper / step implementation files discovered by scanner
        let pool = workspaceFiles.isEmpty ? discoverSourceFiles(in: workspaceRoot) : workspaceFiles.map(\.url)
        for fileURL in pool {
            let lower = fileURL.lastPathComponent.lowercased()
            if lower.hasSuffix(".d.ts") {
                appendCandidate(fileURL, isStub: true)
            } else if lower.contains("step") || lower.contains("helper") || lower.contains("actor") {
                appendCandidate(fileURL, isStub: false)
            }
        }

        // Search all real implementation files FIRST (and follow re-exports/inheritance!)
        for implURL in implementationFiles {
            if let hit = resolveRootSymbol(
                exportedSymbol: nil,
                memberName: methodName,
                inFileURL: implURL,
                isSymlink: isSymlinkPath(implURL),
                workspaceRoot: workspaceRoot,
                config: config,
                visited: []
            ) {
                return hit
            }
        }

        // Fallback to `.d.ts` type stub only when no implementation file defines `methodName`
        for stubURL in typeStubFiles {
            if let content = try? String(contentsOf: stubURL, encoding: .utf8),
               let stubHit = findSymbolDeclaration(
                   named: methodName,
                   inContent: content,
                   fileURL: stubURL,
                   workspaceRoot: workspaceRoot,
                   isDeclarationFile: true
               ) {
                return stubHit
            }
        }

        return nil
    }

    // MARK: - Local Bindings (`new Class()`, `inject()`, Destructuring)

    private enum LocalBinding {
        case classInstance(className: String, line: Int)
        case destructuredMember(sourceObject: String, propertyName: String)
        case alias(targetName: String, line: Int)
    }

    private static func parseLocalBindings(in source: String) -> [String: LocalBinding] {
        let masked = maskCommentsPreservingNewlines(in: source)
        let ns = masked as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var map: [String: LocalBinding] = [:]

        // 1. `const page = new CheckoutPage(...)`
        if let newRegex = try? NSRegularExpression(pattern: #"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*new\s+([A-Za-z_$][\w$]*)\s*\("#) {
            for m in newRegex.matches(in: masked, range: fullRange) {
                let varName = ns.substring(with: m.range(at: 1))
                let className = ns.substring(with: m.range(at: 2))
                let line = lineNumber(atUTF16Offset: m.range.location, in: ns)
                map[varName] = .classInstance(className: className, line: line)
            }
        }

        // 2. `const { submitOrder, login: doLogin } = checkoutPage` or `= inject()`
        if let destrRegex = try? NSRegularExpression(pattern: #"\b(?:const|let|var)\s*\{\s*([^}]+)\s*\}\s*=\s*(inject\s*\(\s*\)|[A-Za-z_$][\w$]*)"#) {
            for m in destrRegex.matches(in: masked, range: fullRange) {
                let fieldsRaw = ns.substring(with: m.range(at: 1))
                let rhsRaw = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: " ", with: "")
                let sourceObj = rhsRaw.hasPrefix("inject(") ? "inject()" : rhsRaw
                for item in fieldsRaw.split(separator: ",") {
                    let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                    let eqRemoved = trimmed.components(separatedBy: "=").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
                    let parts = eqRemoved.split(separator: ":").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    guard let prop = parts.first, !prop.isEmpty else { continue }
                    let localName = parts.count > 1 ? parts[1] : prop
                    map[localName] = .destructuredMember(sourceObject: sourceObj, propertyName: prop)
                }
            }
        }

        // 3. `const aliasPage = checkoutPage`
        if let aliasRegex = try? NSRegularExpression(pattern: #"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*([A-Za-z_$][\w$]*)\s*(?:;|$)"#, options: [.anchorsMatchLines]) {
            for m in aliasRegex.matches(in: masked, range: fullRange) {
                let lhs = ns.substring(with: m.range(at: 1))
                let rhs = ns.substring(with: m.range(at: 2))
                if map[lhs] == nil && !reservedKeywords.contains(rhs) {
                    let line = lineNumber(atUTF16Offset: m.range.location, in: ns)
                    map[lhs] = .alias(targetName: rhs, line: line)
                }
            }
        }

        return map
    }

    private static func resolveViaLocalBinding(
        _ binding: LocalBinding,
        memberName: String,
        in source: String,
        sourceFileURL: URL,
        importedBindings: [String: ImportedBinding],
        workspaceRoot: URL,
        config: CodeceptConfigSummary?
    ) -> NavigationTarget? {
        switch binding {
        case .classInstance(let className, _):
            if let imp = importedBindings[className],
               let resolved = resolveImportPath(specifier: imp.specifier, fromFileURL: sourceFileURL, workspaceRoot: workspaceRoot, config: config) {
                return resolveRootSymbol(
                    exportedSymbol: imp.exportedName,
                    memberName: memberName,
                    inFileURL: resolved.fileURL,
                    isSymlink: resolved.isSymlink,
                    workspaceRoot: workspaceRoot,
                    config: config,
                    visited: []
                )
            }
            return resolveMemberInFileOrAncestors(
                memberName: memberName,
                fileURL: sourceFileURL,
                fileContent: source,
                workspaceRoot: workspaceRoot,
                config: config,
                visited: []
            )
        case .destructuredMember(let sourceObj, let propName):
            if sourceObj == "inject()", let config,
               let inc = config.includes.first(where: { $0.alias == propName }),
               let resolved = resolveIncludeEntry(inc, workspaceRoot: workspaceRoot, config: config) {
                return resolveRootSymbol(
                    exportedSymbol: propName,
                    memberName: memberName,
                    inFileURL: resolved.fileURL,
                    isSymlink: resolved.isSymlink,
                    workspaceRoot: workspaceRoot,
                    config: config,
                    visited: []
                )
            }
            return nil
        case .alias(let targetName, _):
            return resolveReceiverMember(
                receiver: targetName,
                memberName: memberName,
                in: source,
                sourceFileURL: sourceFileURL,
                importedBindings: importedBindings,
                localBindings: [:],
                workspaceRoot: workspaceRoot,
                config: config
            )
        }
    }

    private static func resolveReceiverMember(
        receiver: String,
        memberName: String,
        in source: String,
        sourceFileURL: URL,
        importedBindings: [String: ImportedBinding],
        localBindings: [String: LocalBinding],
        workspaceRoot: URL,
        config: CodeceptConfigSummary?
    ) -> NavigationTarget? {
        if let local = localBindings[receiver],
           let hit = resolveViaLocalBinding(
               local,
               memberName: memberName,
               in: source,
               sourceFileURL: sourceFileURL,
               importedBindings: importedBindings,
               workspaceRoot: workspaceRoot,
               config: config
           ) {
            return hit
        }
        if let imp = importedBindings[receiver],
           let resolved = resolveImportPath(specifier: imp.specifier, fromFileURL: sourceFileURL, workspaceRoot: workspaceRoot, config: config),
           let hit = resolveRootSymbol(
               exportedSymbol: imp.exportedName,
               memberName: memberName,
               inFileURL: resolved.fileURL,
               isSymlink: resolved.isSymlink,
               workspaceRoot: workspaceRoot,
               config: config,
               visited: []
           ) {
            return hit
        }
        if let config,
           let inc = config.includes.first(where: { $0.alias == receiver }),
           let resolved = resolveIncludeEntry(inc, workspaceRoot: workspaceRoot, config: config),
           let hit = resolveRootSymbol(
               exportedSymbol: inc.alias,
               memberName: memberName,
               inFileURL: resolved.fileURL,
               isSymlink: resolved.isSymlink,
               workspaceRoot: workspaceRoot,
               config: config,
               visited: []
           ) {
            return hit
        }
        return nil
    }

    private static func resolveClassDeclaration(
        className: String,
        in source: String,
        sourceFileURL: URL,
        importedBindings: [String: ImportedBinding],
        workspaceRoot: URL,
        config: CodeceptConfigSummary?
    ) -> NavigationTarget? {
        if let imp = importedBindings[className],
           let resolved = resolveImportPath(specifier: imp.specifier, fromFileURL: sourceFileURL, workspaceRoot: workspaceRoot, config: config) {
            return resolveRootSymbol(
                exportedSymbol: imp.exportedName,
                memberName: nil,
                inFileURL: resolved.fileURL,
                isSymlink: resolved.isSymlink,
                workspaceRoot: workspaceRoot,
                config: config,
                visited: []
            ) ?? resolved
        }
        return findSymbolDeclaration(named: className, inContent: source, fileURL: sourceFileURL, workspaceRoot: workspaceRoot)
    }

    private static func resolveStandaloneSymbol(
        named symbol: String,
        currentLine: Int,
        in source: String,
        sourceFileURL: URL,
        importedBindings: [String: ImportedBinding],
        workspaceRoot: URL,
        config: CodeceptConfigSummary?
    ) -> NavigationTarget? {
        if let imp = importedBindings[symbol],
           let resolved = resolveImportPath(specifier: imp.specifier, fromFileURL: sourceFileURL, workspaceRoot: workspaceRoot, config: config) {
            return resolveRootSymbol(
                exportedSymbol: imp.exportedName,
                memberName: nil,
                inFileURL: resolved.fileURL,
                isSymlink: resolved.isSymlink,
                workspaceRoot: workspaceRoot,
                config: config,
                visited: []
            ) ?? resolved
        }
        if let config,
           let inc = config.includes.first(where: { $0.alias == symbol }),
           let resolved = resolveIncludeEntry(inc, workspaceRoot: workspaceRoot, config: config) {
            return resolveRootSymbol(
                exportedSymbol: inc.alias,
                memberName: nil,
                inFileURL: resolved.fileURL,
                isSymlink: resolved.isSymlink,
                workspaceRoot: workspaceRoot,
                config: config,
                visited: []
            ) ?? resolved
        }
        if let decl = findSymbolDeclaration(named: symbol, inContent: source, fileURL: sourceFileURL, workspaceRoot: workspaceRoot),
           decl.lineNumber != currentLine {
            return decl
        }
        return nil
    }

    // MARK: - Gherkin `.feature` Step -> Step Definition Implementation

    private static func resolveGherkinStepLine(
        atUTF16Offset offset: Int,
        in source: String,
        workspaceRoot: URL,
        config: CodeceptConfigSummary?,
        workspaceFiles: [WorkspaceFile]
    ) -> NavigableSpan? {
        let ns = source as NSString
        let lineRange = ns.lineRange(for: NSRange(location: min(offset, ns.length), length: 0))
        let lineText = ns.substring(with: lineRange)
        guard let stepRegex = try? NSRegularExpression(pattern: #"^\s*(?:Given|When|Then|And|But)\s+(.+?)\s*$"#),
              let match = stepRegex.firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) else {
            return nil
        }

        let stepSubRangeInLine = match.range(at: 1)
        let stepText = (lineText as NSString).substring(with: stepSubRangeInLine)
        let globalStepRange = NSRange(location: lineRange.location + stepSubRangeInLine.location, length: stepSubRangeInLine.length)

        var stepFiles: [URL] = []
        var seen = Set<String>()
        func addStepFile(_ url: URL) {
            let std = url.standardizedFileURL
            if FileManager.default.fileExists(atPath: std.path), seen.insert(std.path).inserted {
                stepFiles.append(std)
            }
        }

        if let config {
            for rel in config.gherkinStepsPaths {
                for anchor in configAnchorFiles(workspaceRoot: workspaceRoot, config: config) {
                    if let resolved = resolveImportPath(specifier: rel, fromFileURL: anchor, workspaceRoot: workspaceRoot, config: config) {
                        addStepFile(resolved.fileURL)
                    }
                }
            }
        }
        for wf in workspaceFiles where wf.category == .stepDefinition || wf.name.lowercased().contains("step") {
            addStepFile(wf.url)
        }
        if stepFiles.isEmpty {
            for url in discoverSourceFiles(in: workspaceRoot) where url.lastPathComponent.lowercased().contains("step") {
                addStepFile(url)
            }
        }

        let defPattern = #"\b(?:Given|When|Then)\s*\(\s*(?:(['"`])([^'"`\n]+)\1|/((?:\\/|[^/\n])+)/[gimsuy]*)"#
        guard let defRegex = try? NSRegularExpression(pattern: defPattern) else { return nil }

        for fileURL in stepFiles {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let masked = maskCommentsPreservingNewlines(in: content)
            let fileNS = content as NSString
            let maskedNS = masked as NSString
            let lines = content.components(separatedBy: .newlines)

            for m in defRegex.matches(in: masked, range: NSRange(location: 0, length: maskedNS.length)) {
                let matcherRegex: NSRegularExpression?
                if m.range(at: 2).location != NSNotFound {
                    let cucumberExpr = fileNS.substring(with: m.range(at: 2))
                    matcherRegex = compileCucumberExpression(cucumberExpr)
                } else if m.range(at: 3).location != NSNotFound {
                    let rawRegex = fileNS.substring(with: m.range(at: 3))
                    matcherRegex = try? NSRegularExpression(pattern: rawRegex)
                } else {
                    matcherRegex = nil
                }

                if let matcherRegex,
                   matcherRegex.firstMatch(in: stepText, range: NSRange(location: 0, length: (stepText as NSString).length)) != nil {
                    let line = lineNumber(atUTF16Offset: m.range.location, in: fileNS)
                    let preview = (line >= 1 && line <= lines.count)
                        ? lines[line - 1].trimmingCharacters(in: .whitespaces)
                        : stepText
                    let label = relativeDisplay(fileURL, to: workspaceRoot)
                    let target = NavigationTarget(
                        fileURL: fileURL,
                        lineNumber: line,
                        displayLabel: "\(label):\(line)",
                        symbolName: stepText,
                        previewText: preview,
                        isSymlink: isSymlinkPath(fileURL),
                        kind: .stepDefinition
                    )
                    return NavigableSpan(range: globalStepRange, specifier: stepText, target: target, kind: .stepDefinition)
                }
            }
        }

        return nil
    }

    private static func compileCucumberExpression(_ expression: String) -> NSRegularExpression? {
        var regexPattern = "^"
        var idx = expression.startIndex
        while idx < expression.endIndex {
            if expression[idx] == "{", let closeIdx = expression[idx...].firstIndex(of: "}") {
                let token = String(expression[expression.index(after: idx)..<closeIdx]).lowercased()
                switch token {
                case "string":
                    regexPattern += #"(?:"[^"]*"|'[^']*')"#
                case "int":
                    regexPattern += #"-?\d+"#
                case "float":
                    regexPattern += #"-?\d+(?:\.\d+)?"#
                case "word":
                    regexPattern += #"[^\s]+"#
                default:
                    regexPattern += #".+"#
                }
                idx = expression.index(after: closeIdx)
            } else {
                let ch = String(expression[idx])
                regexPattern += NSRegularExpression.escapedPattern(for: ch)
                idx = expression.index(after: idx)
            }
        }
        regexPattern += "$"
        return try? NSRegularExpression(pattern: regexPattern)
    }

    // MARK: - Comment-Safe Symbol Declaration Finder

    public static func findSymbolDeclarationLine(named symbol: String, in fileURL: URL) -> Int? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        return findSymbolDeclaration(
            named: symbol,
            inContent: content,
            fileURL: fileURL,
            workspaceRoot: fileURL.deletingLastPathComponent(),
            isDeclarationFile: fileURL.path.lowercased().hasSuffix(".d.ts")
        )?.lineNumber
    }

    public static func findSymbolDeclaration(
        named symbol: String,
        inContent content: String,
        fileURL: URL,
        workspaceRoot: URL,
        isSymlink: Bool = false,
        isDeclarationFile: Bool? = nil
    ) -> NavigationTarget? {
        guard !symbol.isEmpty, !reservedKeywords.contains(symbol) else { return nil }
        let isDts = isDeclarationFile ?? fileURL.path.lowercased().hasSuffix(".d.ts")
        let masked = maskCommentsPreservingNewlines(in: content)
        let originalLines = content.components(separatedBy: .newlines)
        let maskedLines = masked.components(separatedBy: .newlines)
        let escaped = NSRegularExpression.escapedPattern(for: symbol)

        // Strict declaration patterns that never match comments or bare call sites (`submitOrder(x);`)
        let highConfidencePatterns: [NSRegularExpression] = [
            // 1. `function foo(` or `export async function foo(`
            try? NSRegularExpression(pattern: #"\b(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*\s*"# + escaped + #"\b|\b(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+"# + escaped + #"\b"#),
            // 2. `const/let/var/class/interface/type/enum foo`
            try? NSRegularExpression(pattern: #"\b(?:export\s+)?(?:default\s+)?(?:declare\s+)?(?:const|let|var|class|interface|type|enum)\s+"# + escaped + #"\b"#),
            // 3. Object property method or arrow property: `foo: async (x) =>` or `foo: function(`
            try? NSRegularExpression(pattern: #"^\s*(?:readonly\s+)?["']?"# + escaped + #"["']?\s*:\s*(?:async\s*)?(?:function\b|\([^;\n]*\)\s*(?::[^=;\n]+)?=>|\{)"#),
            // 4. Class / object method with explicit modifier (`async foo(`, `public foo(`, `static foo(`, `get foo(`)
            try? NSRegularExpression(pattern: #"^\s*(?:(?:public|private|protected|static|readonly|override|abstract|async|get|set)\s+)+"# + escaped + #"\s*(?:<[^>]*>)?\s*\("#),
            // 5. Shorthand class / object method with opening brace `{` on the same line (`foo(a: number): number {` or `foo() {`)
            try? NSRegularExpression(pattern: #"^\s*"# + escaped + #"\s*(?:<[^>]*>)?\s*\([^;\n]*\)\s*(?::\s*[^\{;\n]+)?\{"#)
        ].compactMap { $0 }

        let dtsPattern = isDts
            ? (try? NSRegularExpression(pattern: #"^\s*(?:readonly\s+)?"# + escaped + #"\??\s*(?:<[^>]*>)?\s*\([^)]*\)\s*:"#))
            : nil

        let symRegex = try? NSRegularExpression(pattern: #"\b"# + escaped + #"\b"#)

        for (idx, maskedLine) in maskedLines.enumerated() {
            let trimmed = maskedLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let nsLine = maskedLine as NSString
            let range = NSRange(location: 0, length: nsLine.length)

            var matched = highConfidencePatterns.contains { $0.firstMatch(in: maskedLine, range: range) != nil }
            if !matched, let dtsPattern, dtsPattern.firstMatch(in: maskedLine, range: range) != nil {
                matched = true
            }

            // Multi-line method signature check (`foo(\n a: string\n) {`)
            if !matched,
               let multilineSig = try? NSRegularExpression(pattern: #"^\s*"# + escaped + #"\s*(?:<[^>]*>)?\s*\([^;]*$"#),
               multilineSig.firstMatch(in: maskedLine, range: range) != nil {
                var lookahead = idx + 1
                while lookahead < min(maskedLines.count, idx + 6) {
                    let nextTrim = maskedLines[lookahead].trimmingCharacters(in: .whitespaces)
                    if nextTrim.hasSuffix("{") {
                        matched = true
                        break
                    }
                    if nextTrim.hasSuffix(";") { break }
                    lookahead += 1
                }
            }

            if matched {
                let lineNum = idx + 1
                let rawLine = idx < originalLines.count ? originalLines[idx] : maskedLine
                let col: Int
                if let symMatch = symRegex?.firstMatch(in: maskedLine, range: range) {
                    col = symMatch.range.location + 1
                } else {
                    col = 1
                }
                let relLabel = relativeDisplay(fileURL, to: workspaceRoot)
                let preview = rawLine.trimmingCharacters(in: .whitespaces)
                return NavigationTarget(
                    fileURL: fileURL.standardizedFileURL,
                    lineNumber: lineNum,
                    columnNumber: col,
                    displayLabel: "\(relLabel):\(lineNum)",
                    symbolName: symbol,
                    previewText: preview,
                    isSymlink: isSymlink || isSymlinkPath(fileURL),
                    kind: .declaration
                )
            }
        }

        return nil
    }

    // MARK: - Workspace Fallback & Reverse Usage Scanner

    private static func findWorkspaceDeclarations(
        symbol: String,
        excludingFileURL: URL,
        excludingLine: Int,
        workspaceRoot: URL,
        workspaceFiles: [WorkspaceFile]
    ) -> [NavigationTarget] {
        let candidateURLs: [URL]
        if !workspaceFiles.isEmpty {
            let prioritized = workspaceFiles.sorted { lhs, rhs in
                categoryPriority(lhs.category) < categoryPriority(rhs.category)
            }
            candidateURLs = prioritized
                .filter { !$0.isBinaryFile && ["ts", "js", "mjs", "cjs", "mts", "cts", "tsx", "jsx"].contains($0.fileExtension.lowercased()) }
                .map(\.url)
        } else {
            candidateURLs = discoverSourceFiles(in: workspaceRoot)
        }

        var results: [NavigationTarget] = []
        var stubResults: [NavigationTarget] = []
        for url in candidateURLs {
            let std = url.standardizedFileURL
            let isDts = std.path.lowercased().hasSuffix(".d.ts")
            guard let content = try? String(contentsOf: std, encoding: .utf8),
                  content.contains(symbol),
                  let hit = findSymbolDeclaration(
                      named: symbol,
                      inContent: content,
                      fileURL: std,
                      workspaceRoot: workspaceRoot,
                      isDeclarationFile: isDts
                  ) else {
                continue
            }
            if std.path == excludingFileURL.standardizedFileURL.path && hit.lineNumber == excludingLine {
                continue
            }
            if isDts {
                stubResults.append(hit)
            } else {
                results.append(hit)
            }
        }
        return results.isEmpty ? stubResults : results
    }

    private static func findWorkspaceUsages(
        symbol: String,
        declarationFileURL: URL,
        declarationLine: Int,
        currentSource: String,
        workspaceRoot: URL,
        workspaceFiles: [WorkspaceFile]
    ) -> [NavigationTarget] {
        let escaped = NSRegularExpression.escapedPattern(for: symbol)
        // Match call sites or member references (`symbol(`, `.symbol(`, `{ symbol }`)
        guard let usageRegex = try? NSRegularExpression(pattern: #"\b"# + escaped + #"\b"#) else {
            return []
        }

        let candidateURLs: [URL]
        if !workspaceFiles.isEmpty {
            candidateURLs = workspaceFiles
                .filter { !$0.isBinaryFile && ["ts", "js", "mjs", "cjs", "mts", "cts", "tsx", "jsx"].contains($0.fileExtension.lowercased()) }
                .map(\.url)
        } else {
            candidateURLs = discoverSourceFiles(in: workspaceRoot)
        }

        var allURLs = candidateURLs
        let declStdPath = declarationFileURL.standardizedFileURL.path
        if !allURLs.contains(where: { $0.standardizedFileURL.path == declStdPath }) {
            allURLs.insert(declarationFileURL.standardizedFileURL, at: 0)
        }

        var callSiteUsages: [NavigationTarget] = []
        var importOrBindingUsages: [NavigationTarget] = []

        for fileURL in allURLs {
            let std = fileURL.standardizedFileURL
            if std.path.lowercased().hasSuffix(".d.ts") { continue }
            let content: String
            if std.path == declStdPath {
                content = currentSource
            } else if let disk = try? String(contentsOf: std, encoding: .utf8), disk.contains(symbol) {
                content = disk
            } else {
                continue
            }

            let masked = maskCommentsPreservingNewlines(in: content)
            let rawLines = content.components(separatedBy: .newlines)
            let maskedLines = masked.components(separatedBy: .newlines)
            let relLabel = relativeDisplay(std, to: workspaceRoot)

            for (idx, mLine) in maskedLines.enumerated() {
                let lineNum = idx + 1
                if std.path == declStdPath && lineNum == declarationLine {
                    continue
                }
                let nsLine = mLine as NSString
                guard let match = usageRegex.firstMatch(in: mLine, range: NSRange(location: 0, length: nsLine.length)) else {
                    continue
                }
                let trimmed = mLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("export ") && trimmed.contains("from ") {
                    continue
                }
                let rawPreview = (idx < rawLines.count ? rawLines[idx] : mLine).trimmingCharacters(in: .whitespaces)
                let target = NavigationTarget(
                    fileURL: std,
                    lineNumber: lineNum,
                    columnNumber: match.range.location + 1,
                    displayLabel: "\(relLabel):\(lineNum)",
                    symbolName: symbol,
                    previewText: rawPreview,
                    isSymlink: isSymlinkPath(std),
                    kind: .usage
                )
                if trimmed.hasPrefix("import ") {
                    importOrBindingUsages.append(target)
                } else {
                    callSiteUsages.append(target)
                }
            }
        }

        return callSiteUsages.isEmpty ? importOrBindingUsages : callSiteUsages
    }

    private static func categoryPriority(_ category: WorkspaceFileCategory) -> Int {
        switch category {
        case .pageObject: return 0
        case .helper: return 1
        case .stepDefinition: return 2
        case .testSuite: return 3
        case .other: return 4
        case .config: return 5
        case .gherkinFeature: return 6
        }
    }

    // MARK: - Path & Module Resolution

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
            if let hit = resolveFileCandidate(workspaceRoot.appendingPathComponent(trimmed)) {
                return makeTarget(hit, workspaceRoot: workspaceRoot)
            }
            // Fallback relative to testRoot or configFilePath directory
            if let config {
                for anchor in configAnchorFiles(workspaceRoot: workspaceRoot, config: config) {
                    let dir = anchor.deletingLastPathComponent()
                    if let hit = resolveFileCandidate(dir.appendingPathComponent(trimmed)) {
                        return makeTarget(hit, workspaceRoot: workspaceRoot)
                    }
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

    private static func resolveIncludeEntry(
        _ inc: CodeceptIncludeEntry,
        workspaceRoot: URL,
        config: CodeceptConfigSummary
    ) -> NavigationTarget? {
        for anchor in configAnchorFiles(workspaceRoot: workspaceRoot, config: config) {
            if let resolved = resolveImportPath(
                specifier: inc.relativePath,
                fromFileURL: anchor,
                workspaceRoot: workspaceRoot,
                config: config
            ) {
                return resolved
            }
        }
        return nil
    }

    private static func configAnchorFiles(workspaceRoot: URL, config: CodeceptConfigSummary) -> [URL] {
        var anchors: [URL] = []
        if let cfgPath = config.configFilePath {
            anchors.append(URL(fileURLWithPath: cfgPath))
        }
        let testRoot = config.resolvedTestRootURL(workspaceRoot: workspaceRoot)
        anchors.append(testRoot.appendingPathComponent("_anchor.js"))
        anchors.append(workspaceRoot.appendingPathComponent("_anchor.js"))
        return anchors
    }

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

    // MARK: - Re-export, Inheritance & Comment-Masking Helpers

    private struct ReExportEntry {
        enum Kind {
            case named(exportedAs: String, localOriginal: String)
            case wildcard
        }
        let kind: Kind
        let specifier: String
    }

    private static func parseReExports(in content: String) -> [ReExportEntry] {
        let masked = maskCommentsPreservingNewlines(in: content)
        let ns = masked as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var entries: [ReExportEntry] = []

        // 1. `export { a, b as c, default as d } from './mod'`
        if let namedRegex = try? NSRegularExpression(pattern: #"\bexport\s+(?:type\s+)?\{\s*([^}]+)\s*\}\s*from\s*(['"`])([^'"`\n]+)\2"#) {
            for m in namedRegex.matches(in: masked, range: fullRange) {
                let list = ns.substring(with: m.range(at: 1))
                let specifier = ns.substring(with: m.range(at: 3))
                for item in list.split(separator: ",") {
                    let parts = item.trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: " as ")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    guard let orig = parts.first, !orig.isEmpty else { continue }
                    let exportedAs = parts.count > 1 ? parts[1] : orig
                    entries.append(ReExportEntry(kind: .named(exportedAs: exportedAs, localOriginal: orig), specifier: specifier))
                }
            }
        }

        // 2. `export * as ns from './mod'` or `export * from './mod'`
        if let starRegex = try? NSRegularExpression(pattern: #"\bexport\s+\*\s*(?:as\s+([A-Za-z_$][\w$]*)\s+)?from\s*(['"`])([^'"`\n]+)\2"#) {
            for m in starRegex.matches(in: masked, range: fullRange) {
                let specifier = ns.substring(with: m.range(at: 3))
                if m.range(at: 1).location != NSNotFound {
                    let alias = ns.substring(with: m.range(at: 1))
                    entries.append(ReExportEntry(kind: .named(exportedAs: alias, localOriginal: "default"), specifier: specifier))
                } else {
                    entries.append(ReExportEntry(kind: .wildcard, specifier: specifier))
                }
            }
        }

        // 3. `module.exports = require('./mod')`
        if let cjsRegex = try? NSRegularExpression(pattern: #"\bmodule\.exports\s*=\s*require\s*\(\s*(['"`])([^'"`\n]+)\1\s*\)"#) {
            for m in cjsRegex.matches(in: masked, range: fullRange) {
                let specifier = ns.substring(with: m.range(at: 2))
                entries.append(ReExportEntry(kind: .wildcard, specifier: specifier))
            }
        }

        return entries
    }

    private static func extractExtendedBaseClasses(in content: String) -> [String] {
        let masked = maskCommentsPreservingNewlines(in: content)
        guard let regex = try? NSRegularExpression(pattern: #"\bclass\s+(?:[A-Za-z_$][\w$]*\s+)?extends\s+([A-Za-z_$][\w$]*)\b"#) else {
            return []
        }
        let ns = masked as NSString
        var out: [String] = []
        for m in regex.matches(in: masked, range: NSRange(location: 0, length: ns.length)) {
            let base = ns.substring(with: m.range(at: 1))
            if base != "Helper" && !out.contains(base) {
                out.append(base)
            }
        }
        return out
    }

    /// Replaces characters inside `//...` and `/*...*/` comments with spaces while keeping all `\n`
    /// characters and string literals intact so line numbers and UTF-16 offsets stay 100% aligned.
    private static func maskCommentsPreservingNewlines(in source: String) -> String {
        var chars = Array(source.utf16)
        let count = chars.count
        var i = 0
        var inQuote: UInt16 = 0

        while i < count {
            let c = chars[i]
            if inQuote != 0 {
                if c == 92 { // '\\'
                    i += 2
                    continue
                }
                if c == inQuote {
                    inQuote = 0
                }
                i += 1
                continue
            }

            if c == 39 || c == 34 || c == 96 { // ', ", `
                inQuote = c
                i += 1
                continue
            }

            if c == 47 && i + 1 < count { // '/'
                let next = chars[i + 1]
                if next == 47 { // '//'
                    chars[i] = 32
                    chars[i + 1] = 32
                    i += 2
                    while i < count && chars[i] != 10 && chars[i] != 13 {
                        chars[i] = 32
                        i += 1
                    }
                    continue
                } else if next == 42 { // '/*'
                    chars[i] = 32
                    chars[i + 1] = 32
                    i += 2
                    while i < count {
                        if chars[i] == 42 && i + 1 < count && chars[i + 1] == 47 {
                            chars[i] = 32
                            chars[i + 1] = 32
                            i += 2
                            break
                        }
                        if chars[i] != 10 && chars[i] != 13 {
                            chars[i] = 32
                        }
                        i += 1
                    }
                    continue
                }
            }
            i += 1
        }

        return String(utf16CodeUnits: chars, count: count)
    }

    private static func lineNumber(atUTF16Offset offset: Int, in ns: NSString) -> Int {
        let clamped = min(max(0, offset), ns.length)
        guard clamped > 0 else { return 1 }
        var lines = 1
        for i in 0..<clamped where ns.character(at: i) == 10 {
            lines += 1
        }
        return lines
    }

    private static func discoverSourceFiles(in workspaceRoot: URL) -> [URL] {
        let fm = FileManager.default
        let ignored: Set<String> = ["node_modules", ".git", ".build", "build", "dist", "output", "_output", ".swiftpm"]
        let exts: Set<String> = ["ts", "js", "mjs", "cjs", "mts", "cts", "tsx", "jsx"]
        var urls: [URL] = []
        guard let enumerator = fm.enumerator(
            at: workspaceRoot.standardizedFileURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if ignored.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            if exts.contains(url.pathExtension.lowercased()) {
                urls.append(url)
            }
        }
        return urls
    }

    // MARK: - Symbol & Binding Helpers

    private struct ImportedBinding {
        let localName: String
        let exportedName: String
        let specifier: String
    }

    private static func parseImportedBindings(in source: String) -> [String: ImportedBinding] {
        let masked = maskCommentsPreservingNewlines(in: source)
        let ns = masked as NSString
        let full = NSRange(location: 0, length: ns.length)
        var map: [String: ImportedBinding] = [:]

        for match in namedImportRegex.matches(in: masked, range: full) {
            let specifier = ns.substring(with: match.range(at: 5))
            if match.range(at: 1).location != NSNotFound {
                let def = ns.substring(with: match.range(at: 1))
                map[def] = ImportedBinding(localName: def, exportedName: "default", specifier: specifier)
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

        for match in requireDestructureRegex.matches(in: masked, range: full) {
            let specifier = ns.substring(with: match.range(at: 4))
            if match.range(at: 1).location != NSNotFound {
                let def = ns.substring(with: match.range(at: 1))
                map[def] = ImportedBinding(localName: def, exportedName: "default", specifier: specifier)
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
            while i >= 0 && ns.character(at: i) != 46 { i -= 1 }
            i -= 1
        }

        guard i >= 0, let info = identifierAt(offset: i, in: ns) else { return nil }
        return info.word
    }
}
