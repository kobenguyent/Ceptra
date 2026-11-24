import Foundation

public enum LiveOutputEvent: Equatable, Sendable {
    case suiteStarted(title: String, filePath: String?)
    case scenarioStarted(featureTitle: String, scenarioTitle: String)
    case stepLogged(text: String, depth: Int)
    case scenarioFinished(ExecutedScenarioRecord)
    case summary(passed: Int, failed: Int, skipped: Int, durationLabel: String)
    case logLine(text: String, isError: Bool)
    case inspectorListening(URL)
    case inspectorWaitingToDisconnect
    case interactiveShellState(active: Bool)
}

public final class LiveOutputParser {
    private static let ansiRegex = try! NSRegularExpression(pattern: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]")
    private static let inspectorURLRegex = try! NSRegularExpression(pattern: #"Debugger listening on (ws://(?:127\.0\.0\.1|localhost):\d+/[^\s]+)"#)
    private static let workerPrefixRegex = try! NSRegularExpression(pattern: #"^\[(?:Worker\s+\d+|[^\]]+:\w+)\]\s*"#)
    private static let suiteHeaderRegex = try! NSRegularExpression(pattern: #"^(.+?)\s+--(?:\s+(.*))?$"#)
    private static let passedCompactRegex = try! NSRegularExpression(pattern: #"^\s*[✔✓]\s+(?:(.+?)\s+›\s+)?(.+?)\s+in\s+(\d+)ms\s*$"#)
    private static let failedCompactRegex = try! NSRegularExpression(pattern: #"^\s*[✖✘×]\s+(?:(.+?)\s+›\s+)?(.+?)\s+in\s+(\d+)ms\s*$"#)
    private static let skippedRegex = try! NSRegularExpression(pattern: #"^\s*S\s+(?:(.+?)\s+›\s+)?(.+?)\s*$"#)
    private static let scenarioOKRegex = try! NSRegularExpression(pattern: #"^\s*[✔✓]\s+OK\s+in\s+(\d+)ms\s*$"#)
    private static let scenarioFailRegex = try! NSRegularExpression(pattern: #"^\s*[✖✘×]\s+FAILED\s+in\s+(\d+)ms\s*$"#)
    private static let summaryRegex = try! NSRegularExpression(pattern: #"(?:OK|FAIL)\s*\|\s*(.+?)\s*//\s*(.+)$"#)
    // Playwright Test `list` reporter patterns:
    //   "  ✓  1 [chromium] › tests/example.spec.ts:3:5 › Suite › has title (1.2s)"
    //   "  ok 1 [chromium] › tests/example.spec.ts:3:5 › has title (450ms)"
    //   "  ✘  2 [chromium] › tests/example.spec.ts:10:5 › fails (2.1s)"
    //   "  -  3 [chromium] › tests/example.spec.ts:20:5 › skipped test"
    private static let pwListResultRegex = try! NSRegularExpression(
        pattern: #"^\s*(ok|[✓✔✘✖×xF\-±])\s+\d+\s+(.+?)(?:\s+\((\d+(?:\.\d+)?(?:ms|s|m))\))?\s*$"#
    )
    private static let pwSummaryLineRegex = try! NSRegularExpression(
        pattern: #"^\s*(\d+)\s+(passed|failed|skipped|flaky|interrupted|did not run)(?:\s+\(([^)]+)\))?\s*$"#
    )
    // pytest -v result lines:
    //   "tests/test_example.py::test_has_title[chromium] PASSED [ 50%]"
    //   "tests/test_api.py::TestAPI::test_todo[chromium] FAILED [100%]"
    //   "tests/test_skip.py::test_legacy SKIPPED (reason) [ 33%]"
    private static let pytestResultRegex = try! NSRegularExpression(
        pattern: #"^([^\s:]+\.py)::(.+?)\s+(PASSED|FAILED|SKIPPED|ERROR|XFAIL|XPASS)\b"#
    )
    private static let pytestSummaryRegex = try! NSRegularExpression(
        pattern: #"^=+\s+(.+?)\s+in\s+([0-9.]+s(?:\s*\([^)]+\))?)\s*=+$"#
    )

    private var currentSuiteTitle: String = "Default"
    private var currentSuiteFile: String? = nil
    private var currentScenarioTitle: String? = nil
    private var currentSteps: [ExecutedStepRecord] = []
    private var inFailuresSection = false
    private var lastFailedIndex: Int? = nil
    private var sawPlaywrightListOutput = false
    private var pwPassedCount = 0
    private var pwFailedCount = 0
    private var pwSkippedCount = 0
    private var pwDurationLabel = ""

    public private(set) var scenarios: [ExecutedScenarioRecord] = []
    public private(set) var summaryPassed: Int? = nil
    public private(set) var summaryFailed: Int? = nil
    public private(set) var summarySkipped: Int? = nil

    public init() {}

    public static func stripANSI(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return ansiRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    public func feed(line rawLine: String, isStderr: Bool = false) -> [LiveOutputEvent] {
        let stripped = Self.stripANSI(rawLine).replacingOccurrences(of: "\r", with: "")
        let cleanLine = removeWorkerPrefix(stripped)
        let trimmed = cleanLine.trimmingCharacters(in: .whitespaces)
        var events: [LiveOutputEvent] = [.logLine(text: stripped, isError: isStderr)]

        guard !trimmed.isEmpty else { return events }

        // 0. Node.js V8 Inspector listening URL (strictly loopback 127.0.0.1 / localhost)
        if let inspectMatch = match(Self.inspectorURLRegex, in: stripped),
           let rawURL = capture(inspectMatch, at: 1, in: stripped),
           let parsedURL = URL(string: rawURL),
           CDPInspectorClient.validateLoopbackInspectorURL(parsedURL) {
            events.append(.inspectorListening(parsedURL))
            return events
        }

        if stripped.localizedCaseInsensitiveContains("Waiting for the debugger to disconnect") {
            events.append(.inspectorWaitingToDisconnect)
            return events
        }

        // 0b. CodeceptJS interactive pause() shell lifecycle
        if trimmed.localizedCaseInsensitiveContains("Interactive shell started") {
            events.append(.interactiveShellState(active: true))
            return events
        }
        if trimmed.localizedCaseInsensitiveContains("Exiting interactive shell") {
            events.append(.interactiveShellState(active: false))
            return events
        }

        if trimmed == "-- FAILURES:" {
            inFailuresSection = true
            return events
        }

        // 1. Final summary banner: "OK | 4 passed // 2s" or "FAIL | 3 passed, 1 failed // 3s"
        if let summaryMatch = match(Self.summaryRegex, in: trimmed) {
            let countsSegment = capture(summaryMatch, at: 1, in: trimmed) ?? ""
            let durationLabel = capture(summaryMatch, at: 2, in: trimmed) ?? ""
            let passed = extractCount(named: "passed", in: countsSegment)
            let failed = extractCount(named: "failed", in: countsSegment)
            let skipped = extractCount(named: "skipped", in: countsSegment)
            summaryPassed = passed
            summaryFailed = failed
            summarySkipped = skipped
            events.append(.summary(passed: passed, failed: failed, skipped: skipped, durationLabel: durationLabel))
            return events
        }

        // 1b. Playwright Test `list` reporter result lines & multi-line summary counts
        if trimmed.hasPrefix("Running ") && trimmed.contains(" using ") && trimmed.contains(" worker") {
            sawPlaywrightListOutput = true
            return events
        }
        if let pwMatch = match(Self.pwListResultRegex, in: cleanLine),
           let body = capture(pwMatch, at: 2, in: cleanLine),
           body.contains("›") {
            sawPlaywrightListOutput = true
            let symbol = capture(pwMatch, at: 1, in: cleanLine) ?? "✓"
            let durationToken = capture(pwMatch, at: 3, in: cleanLine)
            let durationMs = parseDurationMs(durationToken)

            let status: ExecutionStatus
            switch symbol {
            case "✓", "✔", "ok", "±": status = .passed
            case "-": status = .skipped
            default: status = .failed
            }

            let parsed = parsePlaywrightBreadcrumb(body)
            let record = ExecutedScenarioRecord(
                featureTitle: parsed.featureTitle,
                scenarioTitle: parsed.scenarioTitle,
                filePath: parsed.filePath,
                status: status,
                durationMs: durationMs,
                tags: extractInlineTags(from: parsed.scenarioTitle),
                steps: []
            )
            scenarios.append(record)
            if status == .failed {
                lastFailedIndex = scenarios.count - 1
            }
            events.append(.scenarioFinished(record))
            return events
        }
        if sawPlaywrightListOutput,
           let pwSum = match(Self.pwSummaryLineRegex, in: trimmed),
           let countStr = capture(pwSum, at: 1, in: trimmed),
           let kind = capture(pwSum, at: 2, in: trimmed),
           let count = Int(countStr) {
            if let dur = capture(pwSum, at: 3, in: trimmed), !dur.isEmpty {
                pwDurationLabel = dur
            }
            switch kind {
            case "passed", "flaky": pwPassedCount += count
            case "failed", "interrupted": pwFailedCount += count
            case "skipped", "did not run": pwSkippedCount += count
            default: break
            }
            summaryPassed = pwPassedCount
            summaryFailed = pwFailedCount
            summarySkipped = pwSkippedCount
            events.append(.summary(
                passed: pwPassedCount,
                failed: pwFailedCount,
                skipped: pwSkippedCount,
                durationLabel: pwDurationLabel
            ))
            return events
        }

        // 1c. pytest -v (Playwright Python) result & summary lines
        if let pyMatch = match(Self.pytestResultRegex, in: trimmed),
           let relFile = capture(pyMatch, at: 1, in: trimmed),
           let testExpr = capture(pyMatch, at: 2, in: trimmed),
           let rawOutcome = capture(pyMatch, at: 3, in: trimmed) {
            let status: ExecutionStatus
            switch rawOutcome {
            case "PASSED", "XPASS": status = .passed
            case "SKIPPED", "XFAIL": status = .skipped
            default: status = .failed
            }

            let parsed = parsePytestNodeID(file: relFile, testExpr: testExpr)
            let record = ExecutedScenarioRecord(
                featureTitle: parsed.featureTitle,
                scenarioTitle: parsed.scenarioTitle,
                filePath: relFile,
                status: status,
                durationMs: 0,
                tags: [],
                steps: []
            )
            scenarios.append(record)
            if status == .failed {
                lastFailedIndex = scenarios.count - 1
            }
            events.append(.scenarioFinished(record))
            return events
        }
        if let pySum = match(Self.pytestSummaryRegex, in: trimmed),
           let body = capture(pySum, at: 1, in: trimmed),
           let dur = capture(pySum, at: 2, in: trimmed),
           (body.contains("passed") || body.contains("failed") || body.contains("skipped") || body.contains("error")) {
            let passed = extractCount(named: "passed", in: body) + extractCount(named: "xpassed", in: body)
            let failed = extractCount(named: "failed", in: body) + extractCount(named: "error", in: body) + extractCount(named: "errors", in: body)
            let skipped = extractCount(named: "skipped", in: body) + extractCount(named: "xfailed", in: body)
            summaryPassed = passed
            summaryFailed = failed
            summarySkipped = skipped
            events.append(.summary(passed: passed, failed: failed, skipped: skipped, durationLabel: dur))
            return events
        }

        if inFailuresSection {
            // Attach error message snippet to last failed scenario if helpful
            if let idx = lastFailedIndex, idx < scenarios.count,
               !trimmed.hasPrefix("1)"), !trimmed.hasPrefix("Run with") {
                let existing = scenarios[idx]
                let combinedError = [existing.errorMessage, trimmed].compactMap { $0 }.joined(separator: "\n")
                if combinedError.count < 1600 {
                    scenarios[idx] = ExecutedScenarioRecord(
                        id: existing.id,
                        featureTitle: existing.featureTitle,
                        scenarioTitle: existing.scenarioTitle,
                        filePath: existing.filePath,
                        status: existing.status,
                        durationMs: existing.durationMs,
                        tags: existing.tags,
                        steps: existing.steps,
                        errorMessage: combinedError,
                        errorStack: existing.errorStack
                    )
                }
            }
            return events
        }

        // 2. Steps-mode scenario completion: "✔ OK in 123ms" / "✖ FAILED in 456ms"
        if let okMatch = match(Self.scenarioOKRegex, in: cleanLine) {
            let duration = Int(capture(okMatch, at: 1, in: cleanLine) ?? "0") ?? 0
            let title = currentScenarioTitle ?? "Scenario"
            let record = ExecutedScenarioRecord(
                featureTitle: currentSuiteTitle,
                scenarioTitle: title,
                filePath: currentSuiteFile,
                status: .passed,
                durationMs: duration,
                tags: extractInlineTags(from: title),
                steps: currentSteps
            )
            scenarios.append(record)
            currentScenarioTitle = nil
            currentSteps = []
            events.append(.scenarioFinished(record))
            return events
        }

        if let failMatch = match(Self.scenarioFailRegex, in: cleanLine) {
            let duration = Int(capture(failMatch, at: 1, in: cleanLine) ?? "0") ?? 0
            let title = currentScenarioTitle ?? "Scenario"
            var steps = currentSteps
            if let last = steps.last {
                steps[steps.count - 1] = ExecutedStepRecord(
                    id: last.id,
                    text: last.text,
                    depth: last.depth,
                    status: .failed,
                    durationMs: last.durationMs
                )
            }
            let record = ExecutedScenarioRecord(
                featureTitle: currentSuiteTitle,
                scenarioTitle: title,
                filePath: currentSuiteFile,
                status: .failed,
                durationMs: duration,
                tags: extractInlineTags(from: title),
                steps: steps
            )
            scenarios.append(record)
            lastFailedIndex = scenarios.count - 1
            currentScenarioTitle = nil
            currentSteps = []
            events.append(.scenarioFinished(record))
            return events
        }

        // 3. Compact-mode pass/fail/skip lines: "  ✔ Scenario in 42ms"
        if let passMatch = match(Self.passedCompactRegex, in: cleanLine) {
            let suite = capture(passMatch, at: 1, in: cleanLine) ?? currentSuiteTitle
            let title = capture(passMatch, at: 2, in: cleanLine) ?? "Scenario"
            let duration = Int(capture(passMatch, at: 3, in: cleanLine) ?? "0") ?? 0
            let record = ExecutedScenarioRecord(
                featureTitle: suite,
                scenarioTitle: title,
                filePath: currentSuiteFile,
                status: .passed,
                durationMs: duration,
                tags: extractInlineTags(from: title),
                steps: currentSteps
            )
            scenarios.append(record)
            currentScenarioTitle = nil
            currentSteps = []
            events.append(.scenarioFinished(record))
            return events
        }

        if let failMatch = match(Self.failedCompactRegex, in: cleanLine) {
            let suite = capture(failMatch, at: 1, in: cleanLine) ?? currentSuiteTitle
            let title = capture(failMatch, at: 2, in: cleanLine) ?? "Scenario"
            let duration = Int(capture(failMatch, at: 3, in: cleanLine) ?? "0") ?? 0
            let record = ExecutedScenarioRecord(
                featureTitle: suite,
                scenarioTitle: title,
                filePath: currentSuiteFile,
                status: .failed,
                durationMs: duration,
                tags: extractInlineTags(from: title),
                steps: currentSteps
            )
            scenarios.append(record)
            lastFailedIndex = scenarios.count - 1
            currentScenarioTitle = nil
            currentSteps = []
            events.append(.scenarioFinished(record))
            return events
        }

        if let skipMatch = match(Self.skippedRegex, in: cleanLine) {
            let suite = capture(skipMatch, at: 1, in: cleanLine) ?? currentSuiteTitle
            let title = capture(skipMatch, at: 2, in: cleanLine) ?? "Scenario"
            let record = ExecutedScenarioRecord(
                featureTitle: suite,
                scenarioTitle: title,
                filePath: currentSuiteFile,
                status: .skipped,
                durationMs: 0,
                tags: extractInlineTags(from: title),
                steps: []
            )
            scenarios.append(record)
            events.append(.scenarioFinished(record))
            return events
        }

        // 4. Suite header: "Checkout --" or "GET tests -- /path/to/GET_test.ts"
        if !cleanLine.hasPrefix(" ") && !trimmed.hasPrefix("---") && !trimmed.hasPrefix("CodeceptJS") {
            if let suiteMatch = match(Self.suiteHeaderRegex, in: trimmed) {
                let title = capture(suiteMatch, at: 1, in: trimmed) ?? trimmed
                let fileCandidate = capture(suiteMatch, at: 2, in: trimmed)?.trimmingCharacters(in: .whitespaces)
                currentSuiteTitle = title
                currentSuiteFile = (fileCandidate?.isEmpty == false) ? fileCandidate : nil
                events.append(.suiteStarted(title: title, filePath: currentSuiteFile))
                return events
            }
        }

        // 5. Suite file line immediately under "Suite --"
        if currentSuiteFile == nil && !cleanLine.hasPrefix(" ") && (trimmed.hasSuffix(".js") || trimmed.hasSuffix(".ts") || trimmed.hasSuffix(".feature") || trimmed.hasSuffix(".mjs") || trimmed.hasSuffix(".cjs")) {
            currentSuiteFile = trimmed
            return events
        }

        // 6. Step line in --steps mode (typically "    I amOnPage ..." or "    • ..." or actor step)
        let leadingSpaces = cleanLine.prefix(while: { $0 == " " }).count
        if currentScenarioTitle != nil && leadingSpaces >= 4 {
            let depth = max(0, (leadingSpaces - 4) / 2)
            let step = ExecutedStepRecord(text: trimmed, depth: depth, status: .passed)
            currentSteps.append(step)
            events.append(.stepLogged(text: trimmed, depth: depth))
            return events
        }

        // 7. Scenario started header in --steps mode ("  Scenario title")
        if leadingSpaces == 2 && trimmed != "Scenario()" && !trimmed.hasPrefix("Before") && !trimmed.hasPrefix("After") && !trimmed.hasPrefix("☐") && !trimmed.hasPrefix("Total:") {
            let parts = trimmed.components(separatedBy: " › ")
            if parts.count == 2 {
                currentSuiteTitle = parts[0]
                currentScenarioTitle = parts[1]
            } else {
                currentScenarioTitle = trimmed
            }
            currentSteps = []
            events.append(.scenarioStarted(featureTitle: currentSuiteTitle, scenarioTitle: currentScenarioTitle ?? trimmed))
        }

        return events
    }

    private func removeWorkerPrefix(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        return Self.workerPrefixRegex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
    }

    private func match(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        let ns = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
    }

    private func capture(_ match: NSTextCheckingResult, at index: Int, in text: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return (text as NSString).substring(with: range)
    }

    private func extractCount(named word: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: "(\\d+)\\s+\(word)") else { return 0 }
        guard let m = match(regex, in: text), let s = capture(m, at: 1, in: text) else { return 0 }
        return Int(s) ?? 0
    }

    private func extractInlineTags(from text: String) -> [String] {
        text.split(separator: " ").map(String.init).filter { $0.hasPrefix("@") }
    }

    private func parseDurationMs(_ token: String?) -> Int {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return 0
        }
        if token.hasSuffix("ms"), let val = Double(token.dropLast(2)) {
            return max(0, Int(val.rounded()))
        }
        if token.hasSuffix("s"), let val = Double(token.dropLast(1)) {
            return max(0, Int((val * 1000.0).rounded()))
        }
        if token.hasSuffix("m"), let val = Double(token.dropLast(1)) {
            return max(0, Int((val * 60_000.0).rounded()))
        }
        return 0
    }

    /// Parses Playwright list line body like:
    /// `[chromium] › tests/login.spec.ts:5:5 › Login › User signs in`
    /// or `tests/login.spec.ts:5:5 › User signs in`.
    private func parsePlaywrightBreadcrumb(_ body: String) -> (featureTitle: String, scenarioTitle: String, filePath: String?) {
        var parts = body
            .components(separatedBy: "›")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else {
            return ("Playwright", body, nil)
        }

        var projectName: String? = nil
        if let first = parts.first, first.hasPrefix("["), first.hasSuffix("]"), first.count > 2 {
            projectName = String(first.dropFirst().dropLast())
            parts.removeFirst()
        }

        var filePath: String? = nil
        if let first = parts.first, first.contains(".spec.") || first.contains(".test.") || first.contains(".ts:") || first.contains(".js:") {
            // Strip trailing `:line:col`
            let filePart = first.replacingOccurrences(of: #":\d+(?::\d+)?$"#, with: "", options: .regularExpression)
            filePath = filePart
            parts.removeFirst()
        }

        guard let scenarioTitle = parts.last else {
            let fallback = filePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Test"
            let feat = projectName.map { "[\($0)] Playwright" } ?? "Playwright"
            return (feat, fallback, filePath)
        }

        let describeParts = parts.dropLast()
        var featureTitle: String
        if !describeParts.isEmpty {
            featureTitle = describeParts.joined(separator: " › ")
        } else if let filePath {
            let stem = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: ".spec", with: "")
                .replacingOccurrences(of: ".test", with: "")
            featureTitle = stem.isEmpty ? "Playwright" : stem
        } else {
            featureTitle = "Playwright"
        }

        if let projectName, !projectName.isEmpty {
            featureTitle = "[\(projectName)] \(featureTitle)"
        }

        return (featureTitle, scenarioTitle, filePath)
    }

    /// Parses a pytest node ID tail like `TestDocs::test_has_title[chromium]` or `test_todo[chromium]`
    /// matching `PlaywrightPythonTimeTravelLoader` 1:1 so trace merging produces zero duplicates.
    private func parsePytestNodeID(file: String, testExpr: String) -> (featureTitle: String, scenarioTitle: String) {
        let segments = testExpr.components(separatedBy: "::").filter { !$0.isEmpty }
        let rawTest = segments.last ?? testExpr

        var browserName: String? = nil
        var scenarioTitle = rawTest
        for browser in ["chromium", "firefox", "webkit"] {
            let suffix = "[\(browser)]"
            if rawTest.hasSuffix(suffix) {
                browserName = browser
                scenarioTitle = String(rawTest.dropLast(suffix.count))
                break
            }
        }

        let suiteStem: String
        if segments.count >= 2 {
            suiteStem = segments.dropLast().joined(separator: " › ")
        } else {
            let stem = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
            suiteStem = stem.isEmpty ? "pytest" : stem
        }

        let featureTitle = browserName.map { "[\($0)] \(suiteStem)" } ?? suiteStem
        return (featureTitle, scenarioTitle)
    }
}
