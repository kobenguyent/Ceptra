import Foundation

public enum TestFileParser {
    public static func parse(content: String, filePath: String) -> [ParsedFeature] {
        let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
        if ext == "feature" {
            return parseGherkin(content: content, filePath: filePath)
        }
        let codeceptFeatures = parseJavaScriptOrTypeScript(content: content, filePath: filePath)
        if !codeceptFeatures.isEmpty {
            return codeceptFeatures
        }
        if looksLikePlaywrightTestFile(content: content, filePath: filePath) {
            return parsePlaywright(content: content, filePath: filePath)
        }
        return []
    }

    /// Returns `true` only if the file actually declares at least one CodeceptJS `Feature(...)` /
    /// `Scenario(...)` / `xScenario(...)` / `Data(...).Scenario(...)`, Gherkin `Feature:` / `Scenario:`,
    /// or Playwright Test `test(...)` / `test.describe(...)`.
    public static func containsCodeceptTests(content: String, filePath: String) -> Bool {
        !parse(content: content, filePath: filePath).isEmpty
    }

    // MARK: - CodeceptJS JS / TS Parser

    private static let featureRegex = try! NSRegularExpression(
        pattern: #"^\s*Feature\s*\(\s*(['"`])((?:\\.|(?!\1).)*)\1"#
    )
    private static let dynamicFeatureRegex = try! NSRegularExpression(
        pattern: #"^\s*Feature\s*\(\s*([^,)\n]+)\s*(?:,|\))(?!\s*[:{])"#
    )
    private static let scenarioRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:(Data\s*\([^)]*\)\s*\.)?\s*)?(xScenario|Scenario(?:\.(only|skip|todo))?)\s*\(\s*(['"`])((?:\\.|(?!\4).)*)\4"#
    )
    private static let dynamicScenarioRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:(Data\s*\([^)]*\)\s*\.)?\s*)?(xScenario|Scenario(?:\.(only|skip|todo))?)\s*\(\s*([^,)\n]+)\s*,"#
    )
    private static let hookRegex = try! NSRegularExpression(
        pattern: #"^\s*(BeforeSuite|AfterSuite|Before|After)\s*\("#
    )
    private static let tagMethodRegex = try! NSRegularExpression(
        pattern: #"\.tag\s*\(\s*['"`](@?[A-Za-z0-9_:-]+)['"`]\s*\)"#
    )
    private static let inlineTagRegex = try! NSRegularExpression(
        pattern: #"(?:^|\s)(@[A-Za-z0-9_:-]+)"#
    )
    private static let actorStepRegex = try! NSRegularExpression(
        pattern: #"(?:await\s+)?([A-Za-z_$][\w$]*)\s*(?:\.retry\s*\([^)]*\))?\s*\.([A-Za-z_$][\w$]*)\s*\((.*)\)"#
    )
    private static let controlFlowRegex = try! NSRegularExpression(
        pattern: #"(?:await\s+)?(retryTo|tryTo|within|session|eachElement|pause)\s*\((.*)"#
    )

    private static func parseJavaScriptOrTypeScript(content: String, filePath: String) -> [ParsedFeature] {
        let lines = content.components(separatedBy: .newlines)
        var features: [ParsedFeature] = []

        var currentFeatureTitle: String? = nil
        var currentFeatureLine: Int = 1
        var currentFeatureTags: [String] = []
        var currentHooks: [ParsedHook] = []
        var currentScenarios: [ParsedScenario] = []

        enum ActiveBlock {
            case scenario(title: String, line: Int, tags: [String], modifier: ScenarioModifier, steps: [ParsedStep], braceDepth: Int, sawBrace: Bool)
            case hook(kind: String, line: Int, steps: [ParsedStep], braceDepth: Int, sawBrace: Bool)
        }

        var activeBlock: ActiveBlock? = nil
        var inMultilineComment = false
        var sawExplicitFeatureOrScenario = false

        func flushActiveBlock(at endLine: Int) {
            guard let block = activeBlock else { return }
            switch block {
            case .scenario(let title, let line, let tags, let modifier, let steps, _, _):
                let featureTitle = currentFeatureTitle ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
                let scenario = ParsedScenario(
                    title: title,
                    filePath: filePath,
                    featureTitle: featureTitle,
                    lineNumber: line,
                    endLineNumber: max(line, endLine),
                    tags: Array(Set(tags)).sorted(),
                    modifier: modifier,
                    steps: steps
                )
                currentScenarios.append(scenario)
            case .hook(let kind, let line, let steps, _, _):
                currentHooks.append(ParsedHook(kind: kind, lineNumber: line, steps: steps))
            }
            activeBlock = nil
        }

        func flushFeature() {
            guard let title = currentFeatureTitle else { return }
            let feature = ParsedFeature(
                title: title,
                filePath: filePath,
                lineNumber: currentFeatureLine,
                tags: Array(Set(currentFeatureTags)).sorted(),
                hooks: currentHooks,
                scenarios: currentScenarios
            )
            features.append(feature)
            currentFeatureTitle = nil
            currentFeatureTags = []
            currentHooks = []
            currentScenarios = []
        }

        for (zeroIdx, rawLine) in lines.enumerated() {
            let lineNumber = zeroIdx + 1
            let cleanedLine = stripLineComment(rawLine, inMultilineComment: &inMultilineComment)
            let trimmed = cleanedLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let nsLine = cleanedLine as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            // Check Feature(...)
            if let match = featureRegex.firstMatch(in: cleanedLine, range: fullRange) {
                sawExplicitFeatureOrScenario = true
                flushActiveBlock(at: lineNumber - 1)
                flushFeature()
                let title = nsLine.substring(with: match.range(at: 2))
                currentFeatureTitle = title
                currentFeatureLine = lineNumber
                currentFeatureTags = extractTags(fromTitle: title, line: cleanedLine)
                continue
            } else if let match = dynamicFeatureRegex.firstMatch(in: cleanedLine, range: fullRange) {
                sawExplicitFeatureOrScenario = true
                flushActiveBlock(at: lineNumber - 1)
                flushFeature()
                let expr = nsLine.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                currentFeatureTitle = expr.isEmpty ? "Feature" : expr
                currentFeatureLine = lineNumber
                currentFeatureTags = extractMethodTags(from: cleanedLine)
                continue
            }

            // Check chained .tag(...) on Feature when not inside a block
            if activeBlock == nil, currentFeatureTitle != nil, trimmed.hasPrefix(".tag(") {
                let extra = extractMethodTags(from: cleanedLine)
                currentFeatureTags.append(contentsOf: extra)
                continue
            }

            // Check Scenario(...) / xScenario(...) / Data(...).Scenario(...)
            let matchedScenario = scenarioRegex.firstMatch(in: cleanedLine, range: fullRange)
            let matchedDynamicScenario = matchedScenario == nil
                ? dynamicScenarioRegex.firstMatch(in: cleanedLine, range: fullRange)
                : nil
            if let match = matchedScenario ?? matchedDynamicScenario {
                sawExplicitFeatureOrScenario = true
                flushActiveBlock(at: lineNumber - 1)
                if currentFeatureTitle == nil {
                    currentFeatureTitle = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
                    currentFeatureLine = 1
                }
                let hasDataPrefix = match.range(at: 1).location != NSNotFound
                let callName = nsLine.substring(with: match.range(at: 2))
                let subModifier = match.range(at: 3).location != NSNotFound ? nsLine.substring(with: match.range(at: 3)) : nil
                let title: String
                if matchedScenario != nil {
                    title = nsLine.substring(with: match.range(at: 5))
                } else {
                    title = nsLine.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
                }

                let modifier: ScenarioModifier
                if callName == "xScenario" || subModifier == "skip" {
                    modifier = .skip
                } else if subModifier == "only" {
                    modifier = .only
                } else if subModifier == "todo" {
                    modifier = .todo
                } else if hasDataPrefix {
                    modifier = .dataDriven
                } else {
                    modifier = .standard
                }

                let tags = extractTags(fromTitle: title, line: cleanedLine)
                let delta = braceDelta(in: cleanedLine)
                let sawBrace = cleanedLine.contains("{")

                if modifier == .todo || (sawBrace && delta <= 0) {
                    let scenario = ParsedScenario(
                        title: title,
                        filePath: filePath,
                        featureTitle: currentFeatureTitle ?? "Default",
                        lineNumber: lineNumber,
                        endLineNumber: lineNumber,
                        tags: Array(Set(tags)).sorted(),
                        modifier: modifier,
                        steps: []
                    )
                    currentScenarios.append(scenario)
                } else {
                    activeBlock = .scenario(
                        title: title,
                        line: lineNumber,
                        tags: tags,
                        modifier: modifier,
                        steps: [],
                        braceDepth: max(0, delta),
                        sawBrace: sawBrace
                    )
                }
                continue
            }

            // Check Before / After / BeforeSuite / AfterSuite
            if activeBlock == nil, let match = hookRegex.firstMatch(in: cleanedLine, range: fullRange) {
                if currentFeatureTitle == nil {
                    currentFeatureTitle = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
                    currentFeatureLine = 1
                }
                let kind = nsLine.substring(with: match.range(at: 1))
                let delta = braceDelta(in: cleanedLine)
                let sawBrace = cleanedLine.contains("{")
                if sawBrace && delta <= 0 {
                    currentHooks.append(ParsedHook(kind: kind, lineNumber: lineNumber, steps: []))
                } else {
                    activeBlock = .hook(kind: kind, line: lineNumber, steps: [], braceDepth: max(0, delta), sawBrace: sawBrace)
                }
                continue
            }

            // Inside active Scenario or Hook: extract steps and track braces
            if var block = activeBlock {
                let delta = braceDelta(in: cleanedLine)
                let lineHasBrace = cleanedLine.contains("{")

                if let step = parseStepLine(trimmed, lineNumber: lineNumber) {
                    switch block {
                    case .scenario(let title, let line, let tags, let modifier, var steps, let depth, let saw):
                        steps.append(step)
                        block = .scenario(title: title, line: line, tags: tags, modifier: modifier, steps: steps, braceDepth: depth, sawBrace: saw)
                    case .hook(let kind, let line, var steps, let depth, let saw):
                        steps.append(step)
                        block = .hook(kind: kind, line: line, steps: steps, braceDepth: depth, sawBrace: saw)
                    }
                }

                // Also capture chained .tag('@foo') on scenario closing line
                switch block {
                case .scenario(let title, let line, var tags, let modifier, let steps, let depth, let saw):
                    let extra = extractMethodTags(from: cleanedLine)
                    if !extra.isEmpty { tags.append(contentsOf: extra) }
                    let newSaw = saw || lineHasBrace
                    let newDepth = depth + delta
                    block = .scenario(title: title, line: line, tags: tags, modifier: modifier, steps: steps, braceDepth: newDepth, sawBrace: newSaw)
                    activeBlock = block
                    if newSaw && newDepth <= 0 {
                        flushActiveBlock(at: lineNumber)
                    }
                case .hook(let kind, let line, let steps, let depth, let saw):
                    let newSaw = saw || lineHasBrace
                    let newDepth = depth + delta
                    block = .hook(kind: kind, line: line, steps: steps, braceDepth: newDepth, sawBrace: newSaw)
                    activeBlock = block
                    if newSaw && newDepth <= 0 {
                        flushActiveBlock(at: lineNumber)
                    }
                }
            }
        }

        flushActiveBlock(at: lines.count)
        guard sawExplicitFeatureOrScenario else {
            return []
        }
        flushFeature()

        // If scenarios exist without explicit Feature(...)
        if features.isEmpty && !currentScenarios.isEmpty {
            let fallbackTitle = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
            features.append(ParsedFeature(title: fallbackTitle, filePath: filePath, lineNumber: 1, hooks: currentHooks, scenarios: currentScenarios))
        }

        return features
    }

    private static func parseStepLine(_ trimmedLine: String, lineNumber: Int) -> ParsedStep? {
        // Skip variable declarations that aren't actor calls unless right-hand side is an actor call
        let workingLine: String
        if let eqRange = trimmedLine.range(of: "="),
           (trimmedLine.hasPrefix("const ") || trimmedLine.hasPrefix("let ") || trimmedLine.hasPrefix("var ")) {
            workingLine = String(trimmedLine[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            workingLine = trimmedLine
        }

        let ns = workingLine as NSString
        let range = NSRange(location: 0, length: ns.length)

        // Check control flow wrappers first: retryTo, tryTo, within, session, eachElement, pause
        if let ctrl = controlFlowRegex.firstMatch(in: workingLine, range: range) {
            let fn = ns.substring(with: ctrl.range(at: 1))
            let rest = ns.substring(with: ctrl.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let summary = summarizeArguments(rest)
            return ParsedStep(
                actor: "flow",
                action: fn,
                argumentsSummary: summary,
                rawText: trimmedLine,
                lineNumber: lineNumber,
                category: .control
            )
        }

        guard let match = actorStepRegex.firstMatch(in: workingLine, range: range) else {
            return nil
        }

        let actor = ns.substring(with: match.range(at: 1))
        let action = ns.substring(with: match.range(at: 2))
        let args = ns.substring(with: match.range(at: 3))

        // Ignore generic JS runtime calls like console.log, JSON.stringify, Object.keys, Math.floor, Array.from, Promise.all
        let ignoredActors: Set<String> = [
            "console", "JSON", "Object", "Array", "Math", "Number", "String",
            "Date", "Promise", "process", "fs", "path", "Buffer", "RegExp", "Set", "Map"
        ]
        if ignoredActors.contains(actor) {
            return nil
        }

        // Prioritize CodeceptJS actors (`I`, `*Page`, `*Fragment`, `expect`, `assert`)
        let isLikelyActor = actor == "I"
            || actor.hasSuffix("Page")
            || actor.hasSuffix("Fragment")
            || actor.hasSuffix("Steps")
            || actor == "expect"
            || actor == "assert"
            || action.hasPrefix("see")
            || action.hasPrefix("dontSee")
            || action.hasPrefix("amOn")
            || action.hasPrefix("wait")
            || action.hasPrefix("send")
            || action.hasPrefix("grab")
            || action.hasPrefix("fill")
            || action.hasPrefix("click")

        guard isLikelyActor else { return nil }

        return ParsedStep(
            actor: actor,
            action: action,
            argumentsSummary: summarizeArguments(args),
            rawText: trimmedLine,
            lineNumber: lineNumber,
            category: ParsedStep.classify(actor: actor, action: action)
        )
    }

    // MARK: - Playwright Test (@playwright/test) Parser

    private static let pwDescribeRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:test\.)?describe(?:\.(only|skip|fixme|parallel|serial))?\s*\(\s*(['"`])((?:\\.|(?!\2).)*)\2"#
    )
    private static let pwTestRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:test|it)(?:\.(only|skip|fixme|fail|slow))?\s*\(\s*(['"`])((?:\\.|(?!\2).)*)\2"#
    )
    private static let pwHookRegex = try! NSRegularExpression(
        pattern: #"^\s*test\.(beforeAll|beforeEach|afterEach|afterAll)\s*\("#
    )
    private static let pwStepRegex = try! NSRegularExpression(
        pattern: #"(?:await\s+)?test\.step\s*\(\s*(['"`])((?:\\.|(?!\1).)*)\1"#
    )
    private static let pwExpectRegex = try! NSRegularExpression(
        pattern: #"(?:await\s+)?expect(?:\.(?:soft|poll))?\s*\(([^)]*)\)\s*(?:\.not)?\s*\.([A-Za-z_$][\w$]*)\s*\((.*)\)"#
    )
    private static let pwOptionSingleTagRegex = try! NSRegularExpression(
        pattern: #"\btag\s*:\s*['"`](@?[A-Za-z0-9_:-]+)['"`]"#
    )
    private static let pwOptionArrayTagRegex = try! NSRegularExpression(
        pattern: #"\btag\s*:\s*\[([^\]]*)\]"#
    )

    private static func looksLikePlaywrightTestFile(content: String, filePath: String) -> Bool {
        if content.contains("@playwright/test")
            || content.contains("@playwright/experimental-ct")
            || content.contains("from 'playwright'")
            || content.contains("from \"playwright\"")
            || content.contains("require('playwright')")
            || content.contains("require(\"playwright\")") {
            return true
        }
        let lowerName = URL(fileURLWithPath: filePath).lastPathComponent.lowercased()
        let isSpecOrTestName = lowerName.contains(".spec.")
            || lowerName.contains(".test.")
            || lowerName.contains("_spec.")
            || lowerName.contains("_test.")
        if isSpecOrTestName {
            return content.contains("test(")
                || content.contains("test.only(")
                || content.contains("test.skip(")
                || content.contains("test.fixme(")
                || content.contains("test.describe(")
        }
        // Custom fixtures files importing `{ test, expect } from '../fixtures'`
        let hasPlaywrightFixtures = content.range(
            of: #"\btest(?:\.(?:only|skip|fixme|fail))?\s*\(\s*['"`][^'"`\n]+['"`]\s*,(?:\s*\{[^}]*\}\s*,)?\s*async\s*\(\s*\{\s*(?:page|request|browser|context)\b"#,
            options: .regularExpression
        ) != nil
        return hasPlaywrightFixtures
    }

    private static func parsePlaywright(content: String, filePath: String) -> [ParsedFeature] {
        let lines = content.components(separatedBy: .newlines)
        let fallbackTitle = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ".spec", with: "")
            .replacingOccurrences(of: ".test", with: "")

        struct SuiteBucket {
            let title: String
            let lineNumber: Int
            var tags: [String]
            var hooks: [ParsedHook]
            var scenarios: [ParsedScenario]
            let openBraceDepth: Int?
        }

        enum ActivePWBlock {
            case testCase(
                suiteIndex: Int,
                title: String,
                line: Int,
                tags: [String],
                modifier: ScenarioModifier,
                steps: [ParsedStep],
                braceDepth: Int,
                sawBrace: Bool
            )
            case hook(
                suiteIndex: Int,
                kind: String,
                line: Int,
                steps: [ParsedStep],
                braceDepth: Int,
                sawBrace: Bool
            )
        }

        var suites: [SuiteBucket] = []
        var describeStack: [Int] = []
        var fileRootSuiteIndex: Int? = nil
        var activeBlock: ActivePWBlock? = nil
        var currentBraceDepth = 0
        var inMultilineComment = false
        var sawAnyTest = false

        func ensureActiveSuiteIndex() -> Int {
            if let top = describeStack.last {
                return top
            }
            if let existing = fileRootSuiteIndex {
                return existing
            }
            let idx = suites.count
            suites.append(SuiteBucket(
                title: fallbackTitle.isEmpty ? "Playwright Suite" : fallbackTitle,
                lineNumber: 1,
                tags: [],
                hooks: [],
                scenarios: [],
                openBraceDepth: nil
            ))
            fileRootSuiteIndex = idx
            return idx
        }

        func flushActiveBlock(at endLine: Int) {
            guard let block = activeBlock else { return }
            switch block {
            case .testCase(let suiteIdx, let title, let line, let tags, let modifier, let steps, _, _):
                let suiteTitle = suites[suiteIdx].title
                let scenario = ParsedScenario(
                    title: title,
                    filePath: filePath,
                    featureTitle: suiteTitle,
                    lineNumber: line,
                    endLineNumber: max(line, endLine),
                    tags: Array(Set(tags)).sorted(),
                    modifier: modifier,
                    steps: steps
                )
                suites[suiteIdx].scenarios.append(scenario)
            case .hook(let suiteIdx, let kind, let line, let steps, _, _):
                suites[suiteIdx].hooks.append(ParsedHook(kind: kind, lineNumber: line, steps: steps))
            }
            activeBlock = nil
        }

        for (zeroIdx, rawLine) in lines.enumerated() {
            let lineNumber = zeroIdx + 1
            let cleanedLine = stripLineComment(rawLine, inMultilineComment: &inMultilineComment)
            let trimmed = cleanedLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let delta = braceDelta(in: cleanedLine)
            let depthBefore = currentBraceDepth
            currentBraceDepth = max(0, currentBraceDepth + delta)

            let nsLine = cleanedLine as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            // 1. Inside an active test(...) or hook block
            if var block = activeBlock {
                let lineHasBrace = cleanedLine.contains("{")
                if let step = parsePlaywrightStepLine(trimmed, lineNumber: lineNumber) {
                    switch block {
                    case .testCase(let sIdx, let title, let line, let tags, let modifier, var steps, let depth, let saw):
                        steps.append(step)
                        block = .testCase(suiteIndex: sIdx, title: title, line: line, tags: tags, modifier: modifier, steps: steps, braceDepth: depth, sawBrace: saw)
                    case .hook(let sIdx, let kind, let line, var steps, let depth, let saw):
                        steps.append(step)
                        block = .hook(suiteIndex: sIdx, kind: kind, line: line, steps: steps, braceDepth: depth, sawBrace: saw)
                    }
                }

                switch block {
                case .testCase(let sIdx, let title, let line, var tags, let modifier, let steps, let depth, let saw):
                    let extraTags = extractPlaywrightOptionTags(from: cleanedLine)
                    if !extraTags.isEmpty { tags.append(contentsOf: extraTags) }
                    let newSaw = saw || lineHasBrace
                    let newDepth = depth + delta
                    activeBlock = .testCase(suiteIndex: sIdx, title: title, line: line, tags: tags, modifier: modifier, steps: steps, braceDepth: newDepth, sawBrace: newSaw)
                    if newSaw && newDepth <= 0 {
                        flushActiveBlock(at: lineNumber)
                    }
                case .hook(let sIdx, let kind, let line, let steps, let depth, let saw):
                    let newSaw = saw || lineHasBrace
                    let newDepth = depth + delta
                    activeBlock = .hook(suiteIndex: sIdx, kind: kind, line: line, steps: steps, braceDepth: newDepth, sawBrace: newSaw)
                    if newSaw && newDepth <= 0 {
                        flushActiveBlock(at: lineNumber)
                    }
                }
                while let topIdx = describeStack.last,
                      let openDepth = suites[topIdx].openBraceDepth,
                      currentBraceDepth <= openDepth {
                    describeStack.removeLast()
                }
                continue
            }

            // 2. Check test.describe(...)
            if let match = pwDescribeRegex.firstMatch(in: cleanedLine, range: fullRange) {
                let rawTitle = nsLine.substring(with: match.range(at: 3))
                let fullTitle: String
                if let parentIdx = describeStack.last {
                    fullTitle = "\(suites[parentIdx].title) › \(rawTitle)"
                } else {
                    fullTitle = rawTitle
                }
                let tags = extractTags(fromTitle: rawTitle, line: cleanedLine) + extractPlaywrightOptionTags(from: cleanedLine)
                let newIdx = suites.count
                suites.append(SuiteBucket(
                    title: fullTitle,
                    lineNumber: lineNumber,
                    tags: Array(Set(tags)).sorted(),
                    hooks: [],
                    scenarios: [],
                    openBraceDepth: depthBefore
                ))
                if delta > 0 {
                    describeStack.append(newIdx)
                }
                continue
            }

            // 3. Check test(...) / test.only(...) / test.skip(...) / test.fixme(...)
            if let match = pwTestRegex.firstMatch(in: cleanedLine, range: fullRange) {
                sawAnyTest = true
                let subMod = match.range(at: 1).location != NSNotFound ? nsLine.substring(with: match.range(at: 1)) : nil
                let title = nsLine.substring(with: match.range(at: 3))
                let modifier: ScenarioModifier
                switch subMod {
                case "only": modifier = .only
                case "skip": modifier = .skip
                case "fixme": modifier = .todo
                default: modifier = .standard
                }
                let suiteIdx = ensureActiveSuiteIndex()
                let tags = extractTags(fromTitle: title, line: cleanedLine)
                    + extractPlaywrightOptionTags(from: cleanedLine)
                    + suites[suiteIdx].tags
                let sawBrace = cleanedLine.contains("{")
                // Note: Playwright tests often have `{ page }` destructuring or `{ tag: '@smoke' }` on the header line!
                // Those `{ ... }` pairs balance to 0, while the trailing `=> {` contributes +1.
                if sawBrace && delta <= 0 && cleanedLine.contains("=>") {
                    suites[suiteIdx].scenarios.append(ParsedScenario(
                        title: title,
                        filePath: filePath,
                        featureTitle: suites[suiteIdx].title,
                        lineNumber: lineNumber,
                        endLineNumber: lineNumber,
                        tags: Array(Set(tags)).sorted(),
                        modifier: modifier,
                        steps: []
                    ))
                } else {
                    let bodyOpened = delta > 0
                    activeBlock = .testCase(
                        suiteIndex: suiteIdx,
                        title: title,
                        line: lineNumber,
                        tags: Array(Set(tags)).sorted(),
                        modifier: modifier,
                        steps: [],
                        braceDepth: max(0, delta),
                        sawBrace: bodyOpened
                    )
                }
                continue
            }

            // 4. Check test.beforeAll / beforeEach / afterEach / afterAll
            if let match = pwHookRegex.firstMatch(in: cleanedLine, range: fullRange) {
                let kind = nsLine.substring(with: match.range(at: 1))
                let suiteIdx = ensureActiveSuiteIndex()
                let bodyOpened = delta > 0
                if cleanedLine.contains("=>") && cleanedLine.contains("{") && delta <= 0 {
                    suites[suiteIdx].hooks.append(ParsedHook(kind: kind, lineNumber: lineNumber, steps: []))
                } else {
                    activeBlock = .hook(
                        suiteIndex: suiteIdx,
                        kind: kind,
                        line: lineNumber,
                        steps: [],
                        braceDepth: max(0, delta),
                        sawBrace: bodyOpened
                    )
                }
                continue
            }

            // Pop closed describe scopes
            while let topIdx = describeStack.last,
                  let openDepth = suites[topIdx].openBraceDepth,
                  currentBraceDepth <= openDepth {
                describeStack.removeLast()
            }
        }

        flushActiveBlock(at: lines.count)
        guard sawAnyTest else { return [] }

        return suites
            .filter { !$0.scenarios.isEmpty || !$0.hooks.isEmpty }
            .map { bucket in
                ParsedFeature(
                    title: bucket.title,
                    filePath: filePath,
                    lineNumber: bucket.lineNumber,
                    tags: Array(Set(bucket.tags)).sorted(),
                    hooks: bucket.hooks,
                    scenarios: bucket.scenarios
                )
            }
    }

    private static func parsePlaywrightStepLine(_ trimmedLine: String, lineNumber: Int) -> ParsedStep? {
        let workingLine: String
        if let eqRange = trimmedLine.range(of: "="),
           (trimmedLine.hasPrefix("const ") || trimmedLine.hasPrefix("let ") || trimmedLine.hasPrefix("var ")) {
            workingLine = String(trimmedLine[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            workingLine = trimmedLine
        }

        let ns = workingLine as NSString
        let range = NSRange(location: 0, length: ns.length)

        // 1. test.step('...', async () => { ... })
        if let stepMatch = pwStepRegex.firstMatch(in: workingLine, range: range) {
            let label = ns.substring(with: stepMatch.range(at: 2))
            return ParsedStep(
                actor: "test",
                action: "step",
                argumentsSummary: "'\(label)'",
                rawText: trimmedLine,
                lineNumber: lineNumber,
                category: .control
            )
        }

        // 2. expect(...).toBeVisible(...) / expect.soft(...).toHaveText(...)
        if let expMatch = pwExpectRegex.firstMatch(in: workingLine, range: range) {
            let target = ns.substring(with: expMatch.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let matcher = ns.substring(with: expMatch.range(at: 2))
            let args = ns.substring(with: expMatch.range(at: 3)).trimmingCharacters(in: .whitespaces)
            let summary = args.isEmpty ? summarizeArguments(target) : summarizeArguments("\(target) → \(args)")
            return ParsedStep(
                actor: "expect",
                action: matcher,
                argumentsSummary: summary,
                rawText: trimmedLine,
                lineNumber: lineNumber,
                category: .assertion
            )
        }

        // 3. page.*, request.*, context.*, browser.*, frame.*, locator.*, or Page Objects
        guard let match = actorStepRegex.firstMatch(in: workingLine, range: range) else {
            return nil
        }
        let actor = ns.substring(with: match.range(at: 1))
        let action = ns.substring(with: match.range(at: 2))
        let args = ns.substring(with: match.range(at: 3))

        let ignoredActors: Set<String> = [
            "console", "JSON", "Object", "Array", "Math", "Number", "String",
            "Date", "Promise", "process", "fs", "path", "Buffer", "RegExp", "Set", "Map"
        ]
        if ignoredActors.contains(actor) {
            return nil
        }

        let isPlaywrightActor = ["page", "request", "context", "browser", "frame", "locator", "response"].contains(actor)
            || actor.hasSuffix("Page")
            || actor.hasSuffix("Component")
            || actor.hasSuffix("Modal")
            || actor.hasSuffix("Api")
            || actor.hasSuffix("API")
            || actor.hasSuffix("Client")
            || actor.hasSuffix("Locator")
            || action.hasPrefix("getBy")
            || ["goto", "click", "fill", "press", "check", "uncheck", "hover", "locator", "screenshot", "waitFor", "waitForURL", "waitForResponse"].contains(action)

        guard isPlaywrightActor else { return nil }

        // If chained like `page.getByRole('button').click()`, prefer highlighting the chained terminal action nicely
        return ParsedStep(
            actor: actor,
            action: action,
            argumentsSummary: summarizeArguments(args),
            rawText: trimmedLine,
            lineNumber: lineNumber,
            category: ParsedStep.classify(actor: actor, action: action)
        )
    }

    private static func extractPlaywrightOptionTags(from line: String) -> [String] {
        var tags: [String] = []
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)

        for match in pwOptionSingleTagRegex.matches(in: line, range: range) {
            let raw = ns.substring(with: match.range(at: 1))
            tags.append(raw.hasPrefix("@") ? raw : "@\(raw)")
        }
        for match in pwOptionArrayTagRegex.matches(in: line, range: range) {
            let inner = ns.substring(with: match.range(at: 1))
            if let strRegex = try? NSRegularExpression(pattern: #"['"`](@?[A-Za-z0-9_:-]+)['"`]"#) {
                let innerNS = inner as NSString
                for sm in strRegex.matches(in: inner, range: NSRange(location: 0, length: innerNS.length)) {
                    let raw = innerNS.substring(with: sm.range(at: 1))
                    tags.append(raw.hasPrefix("@") ? raw : "@\(raw)")
                }
            }
        }
        return tags
    }

    // MARK: - Gherkin (.feature) Parser

    private static func parseGherkin(content: String, filePath: String) -> [ParsedFeature] {
        let lines = content.components(separatedBy: .newlines)
        var features: [ParsedFeature] = []
        var pendingTags: [String] = []

        var featureTitle: String? = nil
        var featureLine = 1
        var featureTags: [String] = []
        var hooks: [ParsedHook] = []
        var scenarios: [ParsedScenario] = []

        var activeScenarioTitle: String? = nil
        var activeScenarioLine = 1
        var activeScenarioTags: [String] = []
        var activeScenarioModifier: ScenarioModifier = .standard
        var activeSteps: [ParsedStep] = []
        var inBackground = false
        var backgroundLine = 1

        func flushCurrent(endLine: Int) {
            if inBackground {
                hooks.append(ParsedHook(kind: "Background", lineNumber: backgroundLine, steps: activeSteps))
                activeSteps = []
                inBackground = false
            } else if let title = activeScenarioTitle {
                scenarios.append(ParsedScenario(
                    title: title,
                    filePath: filePath,
                    featureTitle: featureTitle ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent,
                    lineNumber: activeScenarioLine,
                    endLineNumber: max(activeScenarioLine, endLine),
                    tags: Array(Set(activeScenarioTags)).sorted(),
                    modifier: activeScenarioModifier,
                    steps: activeSteps
                ))
                activeScenarioTitle = nil
                activeScenarioTags = []
                activeSteps = []
            }
        }

        for (zeroIdx, rawLine) in lines.enumerated() {
            let lineNumber = zeroIdx + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("@") {
                let tags = trimmed.split(separator: " ").map(String.init).filter { $0.hasPrefix("@") }
                pendingTags.append(contentsOf: tags)
                continue
            }

            if trimmed.hasPrefix("Feature:") {
                flushCurrent(endLine: lineNumber - 1)
                if let prevTitle = featureTitle {
                    features.append(ParsedFeature(
                        title: prevTitle,
                        filePath: filePath,
                        lineNumber: featureLine,
                        tags: Array(Set(featureTags)).sorted(),
                        hooks: hooks,
                        scenarios: scenarios
                    ))
                    hooks = []
                    scenarios = []
                }
                featureTitle = String(trimmed.dropFirst("Feature:".count)).trimmingCharacters(in: .whitespaces)
                featureLine = lineNumber
                featureTags = pendingTags
                pendingTags = []
                continue
            }

            if trimmed.hasPrefix("Background:") {
                flushCurrent(endLine: lineNumber - 1)
                inBackground = true
                backgroundLine = lineNumber
                pendingTags = []
                continue
            }

            if trimmed.hasPrefix("Scenario Outline:") || trimmed.hasPrefix("Scenario Template:") {
                flushCurrent(endLine: lineNumber - 1)
                let prefix = trimmed.hasPrefix("Scenario Outline:") ? "Scenario Outline:" : "Scenario Template:"
                activeScenarioTitle = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                activeScenarioLine = lineNumber
                activeScenarioTags = pendingTags
                activeScenarioModifier = .outline
                pendingTags = []
                continue
            }

            if trimmed.hasPrefix("Scenario:") {
                flushCurrent(endLine: lineNumber - 1)
                activeScenarioTitle = String(trimmed.dropFirst("Scenario:".count)).trimmingCharacters(in: .whitespaces)
                activeScenarioLine = lineNumber
                activeScenarioTags = pendingTags
                activeScenarioModifier = .standard
                pendingTags = []
                continue
            }

            let keywords = ["Given ", "When ", "Then ", "And ", "But "]
            if let kw = keywords.first(where: { trimmed.hasPrefix($0) }) {
                let keyword = kw.trimmingCharacters(in: .whitespaces)
                let rest = String(trimmed.dropFirst(kw.count)).trimmingCharacters(in: .whitespaces)
                activeSteps.append(ParsedStep(
                    actor: keyword,
                    action: rest,
                    argumentsSummary: "",
                    rawText: trimmed,
                    lineNumber: lineNumber,
                    category: .gherkin
                ))
            }
        }

        flushCurrent(endLine: lines.count)
        if let title = featureTitle {
            features.append(ParsedFeature(
                title: title,
                filePath: filePath,
                lineNumber: featureLine,
                tags: Array(Set(featureTags)).sorted(),
                hooks: hooks,
                scenarios: scenarios
            ))
        }
        return features
    }

    // MARK: - Helpers

    private static func extractTags(fromTitle title: String, line: String) -> [String] {
        var tags: [String] = []
        let nsTitle = title as NSString
        for m in inlineTagRegex.matches(in: title, range: NSRange(location: 0, length: nsTitle.length)) {
            tags.append(nsTitle.substring(with: m.range(at: 1)))
        }
        tags.append(contentsOf: extractMethodTags(from: line))
        return tags
    }

    private static func extractMethodTags(from line: String) -> [String] {
        let ns = line as NSString
        return tagMethodRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)).map { m in
            let raw = ns.substring(with: m.range(at: 1))
            return raw.hasPrefix("@") ? raw : "@\(raw)"
        }
    }

    private static func summarizeArguments(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix(";") || cleaned.hasSuffix(")") {
            if cleaned.hasSuffix(";") {
                cleaned.removeLast()
            } else {
                // Only strip trailing unmatched closing paren
                let opens = cleaned.filter { $0 == "(" }.count
                let closes = cleaned.filter { $0 == ")" }.count
                if closes > opens {
                    cleaned.removeLast()
                } else {
                    break
                }
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 72 {
            return String(cleaned.prefix(69)) + "…"
        }
        return cleaned
    }

    private static func braceDelta(in line: String) -> Int {
        var delta = 0
        var inString: Character? = nil
        var escaped = false
        for c in line {
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
            if c == "{" { delta += 1 }
            else if c == "}" { delta -= 1 }
        }
        return delta
    }

    private static func stripLineComment(_ line: String, inMultilineComment: inout Bool) -> String {
        let chars = Array(line)
        var out = ""
        var i = 0
        var inString: Character? = nil
        var escaped = false

        while i < chars.count {
            if inMultilineComment {
                if chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/" {
                    inMultilineComment = false
                    i += 2
                } else {
                    i += 1
                }
                continue
            }
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
                if chars[i + 1] == "/" {
                    break
                }
                if chars[i + 1] == "*" {
                    inMultilineComment = true
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
