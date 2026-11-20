import Foundation

public enum LiveOutputEvent: Equatable, Sendable {
    case suiteStarted(title: String, filePath: String?)
    case scenarioStarted(featureTitle: String, scenarioTitle: String)
    case stepLogged(text: String, depth: Int)
    case scenarioFinished(ExecutedScenarioRecord)
    case summary(passed: Int, failed: Int, skipped: Int, durationLabel: String)
    case logLine(text: String, isError: Bool)
}

public final class LiveOutputParser {
    private static let ansiRegex = try! NSRegularExpression(pattern: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]")
    private static let workerPrefixRegex = try! NSRegularExpression(pattern: #"^\[(?:Worker\s+\d+|[^\]]+:\w+)\]\s*"#)
    private static let suiteHeaderRegex = try! NSRegularExpression(pattern: #"^(.+?)\s+--(?:\s+(.*))?$"#)
    private static let passedCompactRegex = try! NSRegularExpression(pattern: #"^\s*[✔✓]\s+(?:(.+?)\s+›\s+)?(.+?)\s+in\s+(\d+)ms\s*$"#)
    private static let failedCompactRegex = try! NSRegularExpression(pattern: #"^\s*[✖✘×]\s+(?:(.+?)\s+›\s+)?(.+?)\s+in\s+(\d+)ms\s*$"#)
    private static let skippedRegex = try! NSRegularExpression(pattern: #"^\s*S\s+(?:(.+?)\s+›\s+)?(.+?)\s*$"#)
    private static let scenarioOKRegex = try! NSRegularExpression(pattern: #"^\s*[✔✓]\s+OK\s+in\s+(\d+)ms\s*$"#)
    private static let scenarioFailRegex = try! NSRegularExpression(pattern: #"^\s*[✖✘×]\s+FAILED\s+in\s+(\d+)ms\s*$"#)
    private static let summaryRegex = try! NSRegularExpression(pattern: #"(?:OK|FAIL)\s*\|\s*(.+?)\s*//\s*(.+)$"#)

    private var currentSuiteTitle: String = "Default"
    private var currentSuiteFile: String? = nil
    private var currentScenarioTitle: String? = nil
    private var currentSteps: [ExecutedStepRecord] = []
    private var inFailuresSection = false
    private var lastFailedIndex: Int? = nil

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
}
