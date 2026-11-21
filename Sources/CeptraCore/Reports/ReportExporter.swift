import Foundation

public enum ReportExporter {
    public static func toMarkdown(_ report: TestRunReport) -> String {
        let formatter = ISO8601DateFormatter()
        let passPct = Int((report.passRate * 100.0).rounded())
        var lines: [String] = [
            "# Ceptra Test Report — \(report.projectName)",
            "",
            "- **Run:** \(report.label)",
            "- **Status:** \(report.overallStatus.rawValue.uppercased())",
            "- **Pass Rate:** \(passPct)% (\(report.passedCount) passed, \(report.failedCount) failed, \(report.skippedCount) skipped)",
            "- **Duration:** \(formatDuration(ms: report.durationMs))",
            "- **Started:** \(formatter.string(from: report.startedAt))",
            "- **Command:** `\(report.commandLine)`",
            ""
        ]

        if !report.scenarios.isEmpty {
            lines.append("## Scenarios")
            lines.append("")
            lines.append("| Status | Feature | Scenario | Duration |")
            lines.append("| --- | --- | --- | ---: |")
            for sc in report.scenarios {
                let badge: String
                switch sc.status {
                case .passed: badge = "PASS"
                case .failed: badge = "FAIL"
                case .skipped: badge = "SKIP"
                default: badge = sc.status.rawValue.uppercased()
                }
                lines.append("| \(badge) | \(escapePipe(sc.featureTitle)) | \(escapePipe(sc.scenarioTitle)) | \(formatDuration(ms: sc.durationMs)) |")
            }
            lines.append("")

            let failures = report.scenarios.filter { $0.status == .failed }
            if !failures.isEmpty {
                lines.append("## Failures")
                lines.append("")
                for sc in failures {
                    lines.append("### \(sc.featureTitle) — \(sc.scenarioTitle)")
                    if let msg = sc.errorMessage {
                        lines.append("")
                        lines.append("```text")
                        lines.append(msg)
                        if let stack = sc.errorStack, stack != msg {
                            lines.append("")
                            lines.append(stack)
                        }
                        lines.append("```")
                    }
                    if !sc.steps.isEmpty {
                        lines.append("")
                        lines.append("**Steps:**")
                        for step in sc.steps {
                            let mark = step.status == .failed ? "[FAIL] " : ""
                            lines.append("- \(mark)`\(step.text)`")
                        }
                    }
                    lines.append("")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    public static func toHTML(_ report: TestRunReport, traceBundle: TimeTravelTraceBundle? = nil) -> String {
        TimeTravelHTMLReportBuilder.build(report, traceBundle: traceBundle)
    }

    public static func formatDuration(ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000.0
        if seconds < 60 { return String(format: "%.2fs", seconds) }
        let mins = Int(seconds) / 60
        let rem = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%dm %.1fs", mins, rem)
    }

    private static func escapePipe(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }
}
