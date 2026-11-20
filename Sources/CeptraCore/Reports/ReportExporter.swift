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

    public static func toHTML(_ report: TestRunReport) -> String {
        let passPct = Int((report.passRate * 100.0).rounded())
        let statusColor = report.overallStatus == .passed ? "#34d399" : (report.overallStatus == .failed ? "#f87171" : "#fbbf24")
        let rowsHTML = report.scenarios.map { sc -> String in
            let badgeClass: String
            let badgeText: String
            switch sc.status {
            case .passed: badgeClass = "pass"; badgeText = "PASS"
            case .failed: badgeClass = "fail"; badgeText = "FAIL"
            case .skipped: badgeClass = "skip"; badgeText = "SKIP"
            default: badgeClass = "skip"; badgeText = sc.status.rawValue.uppercased()
            }
            let stepsHTML = sc.steps.map { step in
                let cls = step.status == .failed ? "step fail" : "step"
                return "<div class=\"\(cls)\" style=\"margin-left:\(step.depth * 14)px\">\(escapeHTML(step.text))</div>"
            }.joined()
            let errHTML = sc.errorMessage.map { "<pre class=\"error\">\(escapeHTML($0))</pre>" } ?? ""
            return """
            <details class="scenario \(badgeClass)"\(sc.status == .failed ? " open" : "")>
              <summary>
                <span class="badge \(badgeClass)">\(badgeText)</span>
                <span class="feature">\(escapeHTML(sc.featureTitle))</span>
                <span class="title">\(escapeHTML(sc.scenarioTitle))</span>
                <span class="dur">\(formatDuration(ms: sc.durationMs))</span>
              </summary>
              <div class="details-body">\(stepsHTML)\(errHTML)</div>
            </details>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8" />
        <title>Ceptra Report — \(escapeHTML(report.projectName))</title>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; background: #0f1117; color: #e5e7eb; margin: 0; padding: 32px; }
          .container { max-width: 980px; margin: 0 auto; }
          h1 { margin: 0 0 6px; font-size: 24px; }
          .meta { color: #9ca3af; font-size: 13px; margin-bottom: 24px; }
          .kpis { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-bottom: 24px; }
          .kpi { background: #171a23; border: 1px solid #262b38; border-radius: 10px; padding: 14px; }
          .kpi .label { color: #9ca3af; font-size: 11px; text-transform: uppercase; letter-spacing: .06em; }
          .kpi .value { font-size: 24px; font-weight: 700; margin-top: 4px; }
          .scenario { background: #151821; border: 1px solid #242936; border-radius: 8px; margin-bottom: 8px; }
          summary { display: flex; align-items: center; gap: 10px; padding: 12px 14px; cursor: pointer; list-style: none; }
          .badge { font-size: 11px; font-weight: 700; padding: 2px 7px; border-radius: 4px; }
          .badge.pass { background: rgba(52,211,153,.15); color: #34d399; }
          .badge.fail { background: rgba(248,113,113,.15); color: #f87171; }
          .badge.skip { background: rgba(251,191,36,.15); color: #fbbf24; }
          .feature { color: #9ca3af; font-size: 12px; }
          .title { flex: 1; font-weight: 500; }
          .dur { color: #9ca3af; font-family: ui-monospace, monospace; font-size: 12px; }
          .details-body { padding: 0 16px 14px; border-top: 1px solid #202532; }
          .step { font-family: ui-monospace, monospace; font-size: 12px; color: #cbd5e1; padding: 3px 0; }
          .step.fail { color: #f87171; font-weight: 600; }
          pre.error { background: #1f1417; border: 1px solid #4c1d24; color: #fca5a5; padding: 12px; border-radius: 6px; overflow-x: auto; font-size: 12px; }
        </style>
        </head>
        <body>
          <div class="container">
            <h1>\(escapeHTML(report.projectName)) — \(escapeHTML(report.label))</h1>
            <div class="meta">Command: <code>\(escapeHTML(report.commandLine))</code> · Duration: \(formatDuration(ms: report.durationMs))</div>
            <div class="kpis">
              <div class="kpi"><div class="label">Pass Rate</div><div class="value" style="color:\(statusColor)">\(passPct)%</div></div>
              <div class="kpi"><div class="label">Passed</div><div class="value" style="color:#34d399">\(report.passedCount)</div></div>
              <div class="kpi"><div class="label">Failed</div><div class="value" style="color:#f87171">\(report.failedCount)</div></div>
              <div class="kpi"><div class="label">Skipped</div><div class="value" style="color:#fbbf24">\(report.skippedCount)</div></div>
            </div>
            \(rowsHTML)
          </div>
        </body>
        </html>
        """
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

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
