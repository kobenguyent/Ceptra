import CryptoKit
import Foundation

/// Builds a 100% self-contained, offline-capable interactive HTML replay report for both
/// Web and API CodeceptJS tests:
/// - Step-by-step execution timeline with time-travel playback controls & keyboard navigation
/// - API Replay: Request/Response split inspector, interactive collapsible JSON tree with JSONPath copy,
///   parsed query params, DNS/TCP/TLS/TTFB/download timing waterfall, structural JSON diff between any
///   two exchanges, assertion inspector, one-click Copy as cURL / fetch() / CodeceptJS, and live replay
/// - Web Replay: before/after screenshots with curtain diff & target reticle, DOM snapshot tree/source/
///   sandboxed preview, per-step network traffic, and browser console/page errors
public enum TimeTravelHTMLReportBuilder {
    private struct EmbeddedPayload: Encodable {
        let meta: ReportMeta
        let scenarios: [ScenarioSummary]
        let steps: [TimelineStep]
        let assets: [String: String]
    }

    private struct ReportMeta: Encodable {
        let projectName: String
        let label: String
        let commandLine: String
        let reportMode: String
        let overallStatus: String
        let passRatePct: Int
        let passedCount: Int
        let failedCount: Int
        let skippedCount: Int
        let durationMs: Int
        let apiCallCount: Int
        let apiAvgLatencyMs: Int?
        let apiErrorCount: Int
        let startedAtISO: String
        let finishedAtISO: String
        let rawOutput: String
    }

    private struct ScenarioSummary: Encodable {
        let index: Int
        let featureTitle: String
        let scenarioTitle: String
        let filePath: String?
        let status: String
        let scenarioKind: String
        let durationMs: Int
        let tags: [String]
        let errorMessage: String?
        let errorStack: String?
        let firstStepIndex: Int
        let stepCount: Int
    }

    private struct TimelineStep: Encodable {
        let globalIndex: Int
        let scenarioIndex: Int
        let stepIndexInScenario: Int
        let featureTitle: String
        let scenarioTitle: String
        let scenarioStatus: String
        let scenarioKind: String
        let tags: [String]
        let text: String
        let depth: Int
        let status: String
        let durationMs: Int?
        let startedAtISO: String
        let relativeOffsetMs: Int
        let targetSelector: String?
        let errorMessage: String?
        let scenarioErrorMessage: String?
        let scenarioErrorStack: String?
        let pageURL: String?
        let beforeShotAssetId: String?
        let afterShotAssetId: String?
        let domAssetId: String?
        let domURL: String?
        let domTitle: String?
        let targetOuterHTML: String?
        let targetBoundingBox: TimeTravelBoundingBox?
        let matchedCount: Int?
        let assertion: TimeTravelAssertionRecord?
        let networkRequests: [TimeTravelNetworkEntry]
        let consoleEntries: [TimeTravelConsoleEntry]
    }

    /// Classifies a single scenario as `"web"`, `"api"`, or `"hybrid"` using visual captures,
    /// API client exchanges (`isApiExchange`), API vs browser assertions (`isApiAssertion`),
    /// and browser action signals so mixed Web + API suites never misclassify web tests as API replay.
    private static func classifyScenarioKind(_ sc: ExecutedScenarioRecord) -> String {
        let steps = sc.steps
        let hasWebVisuals = steps.contains { $0.diagnostics?.hasWebVisuals == true }
        let allNet = steps.flatMap { $0.diagnostics?.networkRequests ?? [] }
        let hasApiExchanges = allNet.contains(where: \.isApiExchange)
        let hasBrowserNet = allNet.contains { !$0.isApiExchange }
        let hasApiAssertions = steps.contains { $0.diagnostics?.assertion?.isApiAssertion == true }
        let hasWebAssertions = steps.contains { step in
            guard let assertion = step.diagnostics?.assertion else { return false }
            return !assertion.isApiAssertion
        }
        let hasWebStepText = steps.contains { step in
            let t = step.text
            return t.hasPrefix("page.") || t.hasPrefix("locator(") || t.hasPrefix("getBy") ||
                t == "Navigate" || t.hasPrefix("Navigate ") ||
                t == "Click" || t.hasPrefix("Click ") ||
                t == "Fill" || t.hasPrefix("Fill ") ||
                t == "Press" || t.hasPrefix("Press ") ||
                t == "Hover" || t.hasPrefix("Hover ") ||
                t == "Check" || t.hasPrefix("Check ") ||
                t.hasPrefix("I amOnPage") || t.hasPrefix("I click") ||
                t.hasPrefix("I fillField") || t.hasPrefix("I see ")
        }
        let hasWebSignals = hasWebVisuals || hasBrowserNet || hasWebAssertions || hasWebStepText
        let hasApiActivity = hasApiExchanges || hasApiAssertions || (!hasWebSignals && !allNet.isEmpty)

        if hasWebVisuals && hasApiActivity {
            return "hybrid"
        }
        if hasWebSignals && hasApiExchanges {
            return "hybrid"
        }
        if hasApiActivity && !hasWebSignals {
            return "api"
        }
        return "web"
    }

    public static func build(_ report: TestRunReport, traceBundle: TimeTravelTraceBundle? = nil) -> String {
        let baseScenarios: [ExecutedScenarioRecord]
        if let traceBundle, !traceBundle.scenarios.isEmpty {
            baseScenarios = TimeTravelTraceMerger.merge(
                primaryScenarios: report.scenarios,
                traceScenarios: traceBundle.scenarios,
                runStartedAt: report.startedAt
            )
        } else {
            baseScenarios = TimeTravelTraceMerger.merge(
                primaryScenarios: report.scenarios,
                traceScenarios: [],
                runStartedAt: report.startedAt
            )
        }

        var assets: [String: String] = [:]
        func registerAsset(_ content: String?) -> String? {
            guard let content, !content.isEmpty else { return nil }
            let digest = SHA256.hash(data: Data(content.utf8))
            let key = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
            if assets[key] == nil {
                assets[key] = content
            }
            return key
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var scenarioSummaries: [ScenarioSummary] = []
        var timelineSteps: [TimelineStep] = []

        for (scIdx, sc) in baseScenarios.enumerated() {
            let firstIdx = timelineSteps.count
            let scKind = classifyScenarioKind(sc)
            if sc.steps.isEmpty {
                let stDate = sc.startedAt ?? report.startedAt
                let offsetMs = max(0, Int((stDate.timeIntervalSince(report.startedAt) * 1000.0).rounded()))
                timelineSteps.append(TimelineStep(
                    globalIndex: timelineSteps.count,
                    scenarioIndex: scIdx,
                    stepIndexInScenario: 0,
                    featureTitle: sc.featureTitle,
                    scenarioTitle: sc.scenarioTitle,
                    scenarioStatus: sc.status.rawValue,
                    scenarioKind: scKind,
                    tags: sc.tags,
                    text: sc.scenarioTitle,
                    depth: 0,
                    status: sc.status.rawValue,
                    durationMs: sc.durationMs,
                    startedAtISO: iso.string(from: stDate),
                    relativeOffsetMs: offsetMs,
                    targetSelector: nil,
                    errorMessage: sc.errorMessage,
                    scenarioErrorMessage: sc.errorMessage,
                    scenarioErrorStack: sc.errorStack,
                    pageURL: nil,
                    beforeShotAssetId: nil,
                    afterShotAssetId: nil,
                    domAssetId: nil,
                    domURL: nil,
                    domTitle: nil,
                    targetOuterHTML: nil,
                    targetBoundingBox: nil,
                    matchedCount: nil,
                    assertion: nil,
                    networkRequests: [],
                    consoleEntries: []
                ))
            } else {
                for (stIdx, step) in sc.steps.enumerated() {
                    let stDate = step.startedAt ?? sc.startedAt ?? report.startedAt
                    let offsetMs = max(0, Int((stDate.timeIntervalSince(report.startedAt) * 1000.0).rounded()))
                    let diag = step.diagnostics
                    let dom = diag?.domSnapshot
                    let beforeId = registerAsset(diag?.beforeScreenshotDataURI)
                    let afterId = registerAsset(diag?.afterScreenshotDataURI)
                    let domId = registerAsset(dom?.html)
                    let effectiveErr = step.errorMessage ?? (step.status == .failed ? sc.errorMessage : nil)

                    timelineSteps.append(TimelineStep(
                        globalIndex: timelineSteps.count,
                        scenarioIndex: scIdx,
                        stepIndexInScenario: stIdx,
                        featureTitle: sc.featureTitle,
                        scenarioTitle: sc.scenarioTitle,
                        scenarioStatus: sc.status.rawValue,
                        scenarioKind: scKind,
                        tags: sc.tags,
                        text: step.text,
                        depth: step.depth,
                        status: step.status.rawValue,
                        durationMs: step.durationMs,
                        startedAtISO: iso.string(from: stDate),
                        relativeOffsetMs: offsetMs,
                        targetSelector: step.targetSelector ?? dom?.targetSelector,
                        errorMessage: effectiveErr,
                        scenarioErrorMessage: sc.errorMessage,
                        scenarioErrorStack: sc.errorStack,
                        pageURL: diag?.pageURL ?? dom?.url,
                        beforeShotAssetId: beforeId,
                        afterShotAssetId: afterId,
                        domAssetId: domId,
                        domURL: dom?.url,
                        domTitle: dom?.title,
                        targetOuterHTML: dom?.targetOuterHTML,
                        targetBoundingBox: dom?.targetBoundingBox,
                        matchedCount: dom?.matchedCount,
                        assertion: diag?.assertion,
                        networkRequests: diag?.networkRequests ?? [],
                        consoleEntries: diag?.consoleEntries ?? []
                    ))
                }
            }

            scenarioSummaries.append(ScenarioSummary(
                index: scIdx,
                featureTitle: sc.featureTitle,
                scenarioTitle: sc.scenarioTitle,
                filePath: sc.filePath,
                status: sc.status.rawValue,
                scenarioKind: scKind,
                durationMs: sc.durationMs,
                tags: sc.tags,
                errorMessage: sc.errorMessage,
                errorStack: sc.errorStack,
                firstStepIndex: firstIdx,
                stepCount: max(1, sc.steps.count)
            ))
        }

        let scenarioKinds = Set(scenarioSummaries.map(\.scenarioKind))
        let reportMode: String
        if scenarioKinds.contains("hybrid") || (scenarioKinds.contains("web") && scenarioKinds.contains("api")) {
            reportMode = "hybrid"
        } else if scenarioKinds.contains("api") {
            reportMode = "api"
        } else {
            reportMode = "web"
        }

        let allNetworkEntries = timelineSteps.flatMap(\.networkRequests)
        let directApiEntries = allNetworkEntries.filter(\.isApiExchange)
        let countedApiEntries = !directApiEntries.isEmpty
            ? directApiEntries
            : (reportMode == "api" ? allNetworkEntries : [])
        let apiCallCount = countedApiEntries.count
        let measuredDurations = countedApiEntries.compactMap(\.durationMs)
        let apiAvgLatencyMs: Int? = measuredDurations.isEmpty
            ? nil
            : Int((Double(measuredDurations.reduce(0, +)) / Double(measuredDurations.count)).rounded())
        let apiErrorCount = countedApiEntries.filter { req in
            req.errorText != nil || (req.status ?? 0) >= 400
        }.count

        let passPct = Int((report.passRate * 100.0).rounded())
        let payload = EmbeddedPayload(
            meta: ReportMeta(
                projectName: report.projectName,
                label: report.label,
                commandLine: report.commandLine,
                reportMode: reportMode,
                overallStatus: report.overallStatus.rawValue,
                passRatePct: passPct,
                passedCount: report.passedCount,
                failedCount: report.failedCount,
                skippedCount: report.skippedCount,
                durationMs: report.durationMs,
                apiCallCount: apiCallCount,
                apiAvgLatencyMs: apiAvgLatencyMs,
                apiErrorCount: apiErrorCount,
                startedAtISO: iso.string(from: report.startedAt),
                finishedAtISO: iso.string(from: report.finishedAt),
                rawOutput: String(report.rawOutput.prefix(64 * 1024))
            ),
            scenarios: scenarioSummaries,
            steps: timelineSteps,
            assets: assets
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let rawJSON: String
        if let data = try? encoder.encode(payload), let str = String(data: data, encoding: .utf8) {
            rawJSON = str
        } else {
            rawJSON = #"{"meta":{},"scenarios":[],"steps":[],"assets":{}}"#
        }
        let safeJSON = escapeJSONForHTMLScript(rawJSON)

        let statusClass: String
        switch report.overallStatus {
        case .passed: statusClass = "pass"
        case .failed: statusClass = "fail"
        default: statusClass = "skip"
        }

        let modeBadgeLabel: String
        let modeBadgeClass: String
        switch reportMode {
        case "api":
            modeBadgeLabel = "API REPLAY"
            modeBadgeClass = "mode-api"
        case "hybrid":
            modeBadgeLabel = "WEB + API REPLAY"
            modeBadgeClass = "mode-hybrid"
        default:
            modeBadgeLabel = "WEB REPLAY"
            modeBadgeClass = "mode-web"
        }

        let failureStepCount = timelineSteps.filter { $0.status == "failed" }.count
        let apiKPIHTML: String = apiCallCount > 0
            ? """
                <div class="kpi"><span class="kpi-label">API Calls</span><span class="kpi-val cyan">\(apiCallCount)</span></div>
                <div class="kpi"><span class="kpi-label">Avg Latency</span><span class="kpi-val">\(apiAvgLatencyMs.map { "\($0)ms" } ?? "—")</span></div>
            """
            : ""

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Ceptra \(reportMode == "api" ? "API Replay" : "Time-Travel") Report — \(escapeHTML(report.projectName))</title>
        <style>
        \(cssSource)
        </style>
        </head>
        <body data-report-mode="\(reportMode)">
          <div class="app-shell">
            <header class="topbar">
              <div class="topbar-main">
                <div class="brand-row">
                  <span class="status-pill \(statusClass)">\(escapeHTML(report.overallStatus.rawValue.uppercased()))</span>
                  <span class="mode-pill \(modeBadgeClass)">\(modeBadgeLabel)</span>
                  <h1>\(escapeHTML(report.projectName)) <span class="sep">/</span> <span class="run-label">\(escapeHTML(report.label))</span></h1>
                </div>
                <div class="cmd-line" title="\(escapeHTML(report.commandLine))"><code>\(escapeHTML(report.commandLine))</code></div>
              </div>
              <div class="kpi-strip" aria-label="Test run summary">
                <div class="kpi"><span class="kpi-label">Pass Rate</span><span class="kpi-val \(statusClass)">\(passPct)%</span></div>
                <div class="kpi"><span class="kpi-label">Passed</span><span class="kpi-val pass">\(report.passedCount)</span></div>
                <div class="kpi"><span class="kpi-label">Failed</span><span class="kpi-val fail">\(report.failedCount)</span></div>
                <div class="kpi"><span class="kpi-label">Skipped</span><span class="kpi-val skip">\(report.skippedCount)</span></div>
                <div class="kpi"><span class="kpi-label">Duration</span><span class="kpi-val accent">\(escapeHTML(ReportExporter.formatDuration(ms: report.durationMs)))</span></div>
                \(apiKPIHTML)
                <div class="kpi"><span class="kpi-label">Steps</span><span class="kpi-val">\(timelineSteps.count)</span></div>
              </div>
            </header>

            <section class="playback-bar" aria-label="Time-travel navigation">
              <div role="toolbar" focusgroup="toolbar wrap" aria-label="Time-travel playback controls" class="toolbar">
                <div role="group" aria-label="Step navigation" class="tb-group">
                  <button type="button" id="btn-first" class="tb-btn" aria-label="First step" title="First step (Home)">&#x23EE;</button>
                  <button type="button" id="btn-prev" class="tb-btn" aria-label="Previous step" title="Previous step (Left or Up arrow)">&#x25C0; Prev</button>
                  <button type="button" id="btn-play" class="tb-btn" aria-pressed="false" aria-label="Play or pause timeline" title="Play / Pause (Space)">&#x25B6; Play</button>
                  <button type="button" id="btn-next" class="tb-btn" aria-label="Next step" title="Next step (Right or Down arrow)">Next &#x25B6;</button>
                  <button type="button" id="btn-last" class="tb-btn" aria-label="Last step" title="Last step (End)">&#x23ED;</button>
                </div>
                <span role="separator" aria-orientation="vertical" class="tb-sep"></span>
                <div role="group" aria-label="Failure navigation" class="tb-group">
                  <button type="button" id="btn-fail" class="tb-btn fail-jump" title="Jump to Failure (F)"\(failureStepCount == 0 ? #" aria-disabled="true""# : "")>Jump to Failure\(failureStepCount > 0 ? " (\(failureStepCount))" : "")</button>
                </div>
              </div>

              <div class="scrubber-wrap">
                <div class="scrubber-ticks" id="scrubber-ticks" aria-hidden="true"></div>
                <input type="range" id="step-scrubber" min="0" max="\(max(0, timelineSteps.count - 1))" value="0" aria-label="Scrub through test steps"\(timelineSteps.isEmpty ? " disabled" : "") />
              </div>

              <div class="playback-meta">
                <span id="step-counter" class="mono counter">Step \(timelineSteps.isEmpty ? "0 / 0" : "1 / \(timelineSteps.count)")</span>
                <label class="speed-label" for="playback-speed">
                  <span class="sr-only">Playback speed</span>
                  <select id="playback-speed" title="Playback speed">
                    <option value="1200">0.5x</option>
                    <option value="700" selected>1x</option>
                    <option value="320">2x</option>
                  </select>
                </label>
              </div>
            </section>
            <p role="status" class="sr-only" id="live-status"></p>

            <main class="workbench">
              <aside class="timeline-pane" aria-label="Step-by-step execution timeline">
                <div class="pane-head">
                  <div class="filter-row" role="group" aria-label="Filter timeline by status">
                    <button type="button" class="chip" data-filter="all" aria-pressed="true">All</button>
                    <button type="button" class="chip" data-filter="passed" aria-pressed="false">Passed</button>
                    <button type="button" class="chip" data-filter="failed" aria-pressed="false">Failed</button>
                    <button type="button" class="chip" data-filter="skipped" aria-pressed="false">Skipped</button>
                    \(apiCallCount > 0 ? #"<button type="button" class="chip" data-filter="api" aria-pressed="false">HTTP Only</button>"# : "")
                  </div>
                  <input type="search" id="timeline-search" class="search-input" placeholder="\(reportMode == "api" ? "Filter steps, methods, URLs, status, JSON…" : "Filter steps, scenarios, selectors, URLs…")" aria-label="Filter execution timeline" />
                </div>
                <div id="timeline-list" class="timeline-list" role="listbox" aria-label="Test execution steps"></div>
              </aside>

              <section class="inspector-pane" aria-label="Per-step diagnostic inspector">
                <div id="step-hero" class="step-hero"></div>

                <div class="tabs-shell">
                  <div class="tablist" focusgroup="tablist nomemory" role="tablist" aria-label="Diagnostic inspection panels">
                    <button type="button" role="tab" id="tab-api" aria-selected="false">API Exchange <span class="tab-badge" id="badge-api"></span></button>
                    <button type="button" role="tab" id="tab-waterfall" aria-selected="false">Waterfall &amp; Diff <span class="tab-badge" id="badge-waterfall"></span></button>
                    <button type="button" role="tab" id="tab-visual" aria-selected="true" focusgroupstart>Visual &amp; Console <span class="tab-badge" id="badge-visual"></span></button>
                    <button type="button" role="tab" id="tab-dom" aria-selected="false">DOM Snapshot <span class="tab-badge" id="badge-dom"></span></button>
                    <button type="button" role="tab" id="tab-network" aria-selected="false">Network <span class="tab-badge" id="badge-network"></span></button>
                  </div>

                  <div class="tabpanels">
                    <div role="tabpanel" id="panel-api" aria-labelledby="tab-api" hidden>
                      <div class="panel-inner" id="api-content"></div>
                    </div>
                    <div role="tabpanel" id="panel-waterfall" aria-labelledby="tab-waterfall" hidden>
                      <div class="panel-inner" id="waterfall-content"></div>
                    </div>
                    <div role="tabpanel" id="panel-visual" aria-labelledby="tab-visual" tabindex="0">
                      <div class="panel-inner" id="visual-content"></div>
                    </div>
                    <div role="tabpanel" id="panel-dom" aria-labelledby="tab-dom" hidden>
                      <div class="panel-inner" id="dom-content"></div>
                    </div>
                    <div role="tabpanel" id="panel-network" aria-labelledby="tab-network" hidden>
                      <div class="panel-inner" id="network-content"></div>
                    </div>
                  </div>
                </div>
              </section>
            </main>
          </div>
          <div id="copy-toast" class="copy-toast" role="status" aria-live="polite" hidden></div>

          <dialog id="shot-lightbox" class="lightbox" aria-label="Screenshot zoom view">
            <div class="lightbox-head">
              <span id="lightbox-title" class="mono"></span>
              <button type="button" id="lightbox-close" class="tb-btn" aria-label="Close screenshot preview">Close</button>
            </div>
            <div class="lightbox-body">
              <img id="lightbox-img" alt="Zoomed step screenshot" />
            </div>
          </dialog>

          <script id="ceptra-report-data" type="application/json">\(safeJSON)</script>
          <script id="ceptra-report-app">
        \(jsSource)
          </script>
        </body>
        </html>
        """
    }

    /// Escapes characters that could prematurely terminate an HTML `<script>` element
    /// or break JS parsing across browsers.
    public static func escapeJSONForHTMLScript(_ json: String) -> String {
        var out = String()
        out.reserveCapacity(json.count + 64)
        for ch in json {
            switch ch {
            case "<": out.append("\\u003c")
            case ">": out.append("\\u003e")
            case "&": out.append("\\u0026")
            case "\u{2028}": out.append("\\u2028")
            case "\u{2029}": out.append("\\u2029")
            default: out.append(ch)
            }
        }
        return out
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Embedded CSS

    private static let cssSource: String = #"""
    :root {
      color-scheme: dark;
      --bg: #0c0e14;
      --surface: #131722;
      --surface-2: #191e2c;
      --surface-3: #202738;
      --border: #283044;
      --border-strong: #37435f;
      --text: #e6ebf5;
      --text-2: #a5b1c8;
      --muted: #76839e;
      --accent: #60a5fa;
      --accent-soft: rgba(96, 165, 250, 0.16);
      --cyan: #22d3ee;
      --cyan-soft: rgba(34, 211, 238, 0.15);
      --violet: #a78bfa;
      --violet-soft: rgba(167, 139, 250, 0.16);
      --pass: #34d399;
      --pass-soft: rgba(52, 211, 153, 0.14);
      --fail: #f87171;
      --fail-soft: rgba(248, 113, 113, 0.15);
      --warn: #fbbf24;
      --warn-soft: rgba(251, 191, 36, 0.15);
      --target: #f59e0b;
      --target-soft: rgba(245, 158, 11, 0.22);
      --radius: 10px;
      --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
      --sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", system-ui, sans-serif;
    }
    *, *::before, *::after { box-sizing: border-box; }
    html, body { margin: 0; height: 100%; background: var(--bg); color: var(--text); font-family: var(--sans); font-size: 13px; line-height: 1.45; }
    .sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0; }
    .mono { font-family: var(--mono); font-variant-numeric: tabular-nums; }
    :focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

    .app-shell { display: flex; flex-direction: column; min-height: 100vh; }

    .topbar { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px 20px; padding: 14px 20px; background: var(--surface); border-bottom: 1px solid var(--border); }
    .topbar-main { min-width: 0; flex: 1 1 320px; }
    .brand-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
    .brand-row h1 { margin: 0; font-size: 16px; font-weight: 700; letter-spacing: -0.01em; }
    .brand-row .sep { color: var(--muted); font-weight: 400; }
    .brand-row .run-label { color: var(--text-2); font-weight: 500; }
    .cmd-line { margin-top: 4px; color: var(--muted); font-size: 11.5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 680px; }
    .cmd-line code { font-family: var(--mono); }

    .status-pill { display: inline-flex; align-items: center; font-size: 10.5px; font-weight: 700; letter-spacing: 0.05em; padding: 3px 8px; border-radius: 999px; border: 1px solid transparent; }
    .status-pill.pass { background: var(--pass-soft); color: var(--pass); border-color: rgba(52, 211, 153, 0.35); }
    .status-pill.fail { background: var(--fail-soft); color: var(--fail); border-color: rgba(248, 113, 113, 0.4); }
    .status-pill.skip { background: var(--warn-soft); color: var(--warn); border-color: rgba(251, 191, 36, 0.35); }

    .mode-pill { display: inline-flex; align-items: center; font-family: var(--mono); font-size: 10px; font-weight: 700; letter-spacing: 0.06em; padding: 3px 8px; border-radius: 999px; border: 1px solid transparent; }
    .mode-pill.mode-api { background: var(--cyan-soft); color: var(--cyan); border-color: rgba(34, 211, 238, 0.38); }
    .mode-pill.mode-hybrid { background: var(--violet-soft); color: var(--violet); border-color: rgba(167, 139, 250, 0.38); }
    .mode-pill.mode-web { background: var(--accent-soft); color: var(--accent); border-color: rgba(96, 165, 250, 0.35); }

    .kpi-strip { display: flex; flex-wrap: wrap; gap: 8px; }
    .kpi { background: var(--surface-2); border: 1px solid var(--border); border-radius: 8px; padding: 6px 11px; min-width: 72px; }
    .kpi-label { display: block; font-size: 9.5px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); }
    .kpi-val { display: block; font-size: 16px; font-weight: 700; font-variant-numeric: tabular-nums; margin-top: 1px; }
    .kpi-val.pass { color: var(--pass); }
    .kpi-val.fail { color: var(--fail); }
    .kpi-val.skip { color: var(--warn); }
    .kpi-val.accent { color: var(--accent); }
    .kpi-val.cyan { color: var(--cyan); }

    .playback-bar { position: sticky; top: 0; z-index: 20; display: flex; flex-wrap: wrap; align-items: center; gap: 12px; padding: 9px 20px; background: rgba(19, 23, 34, 0.94); backdrop-filter: blur(12px); border-bottom: 1px solid var(--border); }
    .toolbar { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
    .tb-group { display: inline-flex; align-items: center; gap: 4px; flex-wrap: wrap; }
    .tb-sep { display: inline-block; width: 0; height: 20px; border-inline-start: 1px solid var(--border-strong); margin: 0 2px; }
    .tb-btn { min-inline-size: 30px; min-block-size: 28px; padding: 4px 10px; border-radius: 7px; border: 1px solid var(--border); background: var(--surface-2); color: var(--text); font-size: 12px; font-weight: 500; cursor: pointer; display: inline-flex; align-items: center; justify-content: center; gap: 5px; }
    @media (hover: hover) { .tb-btn:hover:not([aria-disabled="true"]) { background: var(--surface-3); border-color: var(--border-strong); } }
    .tb-btn[aria-pressed="true"] { background: var(--accent-soft); border-color: var(--accent); color: #dbeafe; }
    .tb-btn[aria-disabled="true"] { opacity: 0.42; cursor: not-allowed; }
    .tb-btn.primary { background: var(--cyan-soft); border-color: rgba(34, 211, 238, 0.45); color: #cffafe; }
    .tb-btn.fail-jump:not([aria-disabled="true"]) { background: var(--fail-soft); border-color: rgba(248, 113, 113, 0.45); color: #fecaca; }
    @media (prefers-reduced-motion: no-preference) { .tb-btn, .chip, .step-item { transition: background-color 120ms ease, border-color 120ms ease; } }

    .scrubber-wrap { flex: 1 1 220px; min-width: 160px; display: flex; flex-direction: column; gap: 3px; }
    .scrubber-ticks { display: flex; gap: 2px; height: 6px; width: 100%; }
    .scrubber-tick { flex: 1 1 0; border-radius: 2px; background: var(--border); cursor: pointer; min-width: 2px; }
    .scrubber-tick.pass { background: rgba(52, 211, 153, 0.55); }
    .scrubber-tick.fail { background: var(--fail); }
    .scrubber-tick.skip { background: var(--warn); }
    .scrubber-tick.api-tick { background: rgba(34, 211, 238, 0.65); }
    .scrubber-tick.api-tick.fail { background: var(--fail); }
    .scrubber-tick.active { outline: 1.5px solid #fff; transform: scaleY(1.35); }
    #step-scrubber { width: 100%; accent-color: var(--accent); margin: 0; cursor: pointer; }

    .playback-meta { display: flex; align-items: center; gap: 8px; }
    .counter { font-size: 12px; color: var(--text-2); min-width: 82px; text-align: right; }
    #playback-speed, .select-input { background: var(--surface-2); color: var(--text); border: 1px solid var(--border); border-radius: 6px; padding: 4px 8px; font-size: 11.5px; max-width: 100%; }

    .workbench { flex: 1; display: grid; grid-template-columns: minmax(300px, 390px) minmax(0, 1fr); min-height: 0; }
    @media (max-width: 920px) { .workbench { grid-template-columns: 1fr; } .timeline-pane { max-height: 320px; border-right: none; border-bottom: 1px solid var(--border); position: static; } }

    .timeline-pane { display: flex; flex-direction: column; border-right: 1px solid var(--border); background: var(--surface); min-height: 0; max-height: calc(100vh - 122px); position: sticky; top: 52px; }
    .pane-head { padding: 10px 12px; border-bottom: 1px solid var(--border); display: flex; flex-direction: column; gap: 8px; }
    .filter-row { display: flex; gap: 5px; flex-wrap: wrap; }
    .chip { min-block-size: 26px; padding: 3px 9px; border-radius: 999px; border: 1px solid var(--border); background: var(--surface-2); color: var(--text-2); font-size: 11.5px; cursor: pointer; }
    .chip[aria-pressed="true"] { background: var(--accent-soft); border-color: var(--accent); color: #fff; font-weight: 600; }
    .search-input { width: 100%; padding: 6px 10px; border-radius: 7px; border: 1px solid var(--border); background: var(--bg); color: var(--text); font-size: 12px; }

    .timeline-list { flex: 1; overflow-y: auto; padding: 8px; display: flex; flex-direction: column; gap: 4px; }
    .scenario-divider { padding: 8px 8px 4px; margin-top: 4px; border-bottom: 1px solid var(--border); display: flex; align-items: baseline; justify-content: space-between; gap: 8px; }
    .scenario-divider:first-child { margin-top: 0; }
    .sc-name { font-size: 11.5px; font-weight: 600; color: var(--text); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .sc-feat { font-size: 10px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; display: block; }

    .step-item { width: 100%; text-align: left; border: 1px solid transparent; border-left: 3px solid transparent; background: transparent; color: var(--text); border-radius: 7px; padding: 7px 9px; cursor: pointer; display: flex; flex-direction: column; gap: 4px; }
    @media (hover: hover) { .step-item:hover { background: var(--surface-2); } }
    .step-item[aria-selected="true"] { background: var(--surface-2); border-color: var(--border-strong); border-left-color: var(--accent); }
    .step-item.fail[aria-selected="true"] { border-left-color: var(--fail); }
    .step-row-top { display: flex; align-items: center; gap: 7px; min-width: 0; }
    .step-idx { font-size: 10.5px; color: var(--muted); min-width: 24px; }
    .step-dot { width: 8px; height: 8px; border-radius: 50%; flex: none; }
    .step-dot.pass { background: var(--pass); }
    .step-dot.fail { background: var(--fail); }
    .step-dot.skip { background: var(--warn); }
    .step-text { flex: 1; min-width: 0; font-family: var(--mono); font-size: 11.5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .step-item.fail .step-text { color: #fecaca; }
    .step-dur { font-size: 10.5px; color: var(--muted); flex: none; }
    .step-row-meta { display: flex; align-items: center; gap: 5px; padding-left: 31px; font-size: 10px; color: var(--muted); flex-wrap: wrap; }
    .dur-bar { flex: 1; min-width: 26px; max-width: 64px; height: 3px; background: var(--surface-3); border-radius: 2px; overflow: hidden; }
    .dur-fill { height: 100%; background: var(--accent); }
    .step-item.fail .dur-fill { background: var(--fail); }
    .mini-tag { padding: 1px 5px; border-radius: 4px; background: var(--surface-3); color: var(--text-2); font-family: var(--mono); font-size: 9.5px; }
    .mini-tag.err { background: var(--fail-soft); color: var(--fail); }
    .mini-tag.pass { background: var(--pass-soft); color: var(--pass); }
    .mini-tag.warn { background: var(--warn-soft); color: var(--warn); }
    .mini-tag.cyan { background: var(--cyan-soft); color: var(--cyan); }
    .mini-tag.violet { background: var(--violet-soft); color: var(--violet); }

    .inspector-pane { display: flex; flex-direction: column; min-width: 0; padding: 16px 20px 28px; gap: 14px; }
    .step-hero { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 14px 16px; display: flex; flex-direction: column; gap: 8px; }
    .hero-top { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
    .hero-breadcrumb { font-size: 11px; color: var(--muted); margin-bottom: 3px; }
    .hero-title { font-family: var(--mono); font-size: 14px; font-weight: 600; color: var(--text); word-break: break-word; }
    .hero-chips { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
    .meta-pill { font-size: 11px; padding: 2px 8px; border-radius: 6px; background: var(--surface-2); border: 1px solid var(--border); color: var(--text-2); max-width: 420px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .meta-pill.target { background: var(--target-soft); border-color: rgba(245, 158, 11, 0.45); color: #fde68a; }
    .error-banner { background: var(--fail-soft); border: 1px solid rgba(248, 113, 113, 0.42); border-radius: 8px; padding: 10px 12px; color: #fecaca; font-family: var(--mono); font-size: 11.5px; white-space: pre-wrap; overflow-x: auto; }

    .tabs-shell { display: flex; flex-direction: column; min-width: 0; }
    .tablist { display: flex; overflow-x: auto; border-bottom: 1px solid var(--border); gap: 2px; scrollbar-width: none; }
    .tablist [role="tab"] { position: relative; flex: none; min-block-size: 36px; padding: 8px 14px; border: none; background: transparent; color: var(--text-2); font-size: 12.5px; font-weight: 500; cursor: pointer; display: inline-flex; align-items: center; gap: 6px; }
    .tablist [role="tab"][hidden] { display: none; }
    .tablist [role="tab"][aria-selected="true"] { color: var(--text); }
    .tablist [role="tab"][aria-selected="true"]::after { content: ""; position: absolute; inset: auto 8px 0; border-block-end: 2.5px solid var(--accent); }
    .tab-badge { font-family: var(--mono); font-size: 10.5px; padding: 1px 6px; border-radius: 999px; background: var(--surface-2); color: var(--text-2); }
    .tab-badge:empty { display: none; }

    .tabpanels { display: block; }
    .tabpanels > [role="tabpanel"] { min-width: 0; }
    .tabpanels > [role="tabpanel"][hidden] { display: none !important; }
    .panel-inner { padding-top: 14px; display: flex; flex-direction: column; gap: 14px; min-width: 0; }

    .copy-toast { position: fixed; right: 20px; bottom: 20px; z-index: 60; padding: 8px 14px; border-radius: 8px; background: var(--surface-3); border: 1px solid var(--accent); color: var(--text); font-family: var(--mono); font-size: 11.5px; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.45); pointer-events: none; }
    .copy-toast[hidden] { display: none !important; }

    .card { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); overflow: hidden; }
    .card-head { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px; padding: 10px 14px; background: var(--surface-2); border-bottom: 1px solid var(--border); }
    .card-title { font-size: 11.5px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; color: var(--text-2); }
    .card-body { padding: 14px; }

    /* Method & Status Badges */
    .method-badge { font-family: var(--mono); font-size: 10.5px; font-weight: 700; padding: 2px 7px; border-radius: 5px; background: var(--surface-3); color: #bfdbfe; display: inline-block; }
    .method-badge.m-get { background: rgba(96, 165, 250, 0.18); color: #93c5fd; }
    .method-badge.m-post { background: rgba(52, 211, 153, 0.18); color: #6ee7b7; }
    .method-badge.m-put { background: rgba(251, 191, 36, 0.18); color: #fcd34d; }
    .method-badge.m-patch { background: rgba(167, 139, 250, 0.18); color: #c4b5fd; }
    .method-badge.m-delete { background: rgba(248, 113, 113, 0.18); color: #fca5a5; }
    .status-code { font-family: var(--mono); font-size: 11px; font-weight: 700; padding: 2px 7px; border-radius: 5px; display: inline-block; }
    .status-code.s2 { background: var(--pass-soft); color: var(--pass); }
    .status-code.s3 { background: var(--accent-soft); color: var(--accent); }
    .status-code.s4 { background: var(--warn-soft); color: var(--warn); }
    .status-code.s5, .status-code.serr { background: var(--fail-soft); color: var(--fail); }

    /* API Replay Stage */
    .exchange-strip { display: flex; gap: 6px; overflow-x: auto; padding-bottom: 2px; }
    .exchange-pill { flex: none; display: inline-flex; align-items: center; gap: 6px; padding: 6px 10px; border-radius: 8px; border: 1px solid var(--border); background: var(--surface-2); color: var(--text-2); cursor: pointer; font-family: var(--mono); font-size: 11px; }
    .exchange-pill.active { background: var(--accent-soft); border-color: var(--accent); color: var(--text); }

    .api-hero-bar { display: flex; flex-direction: column; gap: 10px; padding: 12px 14px; background: var(--surface-2); border-bottom: 1px solid var(--border); }
    .api-hero-url-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
    .api-url-text { font-family: var(--mono); font-size: 12.5px; font-weight: 600; color: var(--text); word-break: break-all; flex: 1 1 240px; }
    .api-hero-actions { display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap; }

    .api-split { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; }
    .api-split.single { grid-template-columns: minmax(0, 1fr); }
    @media (max-width: 1080px) { .api-split { grid-template-columns: minmax(0, 1fr); } }
    .api-pane { background: var(--bg); border: 1px solid var(--border); border-radius: 8px; display: flex; flex-direction: column; min-width: 0; overflow: hidden; }
    .api-pane-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 8px 12px; background: var(--surface-2); border-bottom: 1px solid var(--border); }
    .api-pane-body { padding: 12px; display: flex; flex-direction: column; gap: 12px; min-width: 0; }

    .sub-section { display: flex; flex-direction: column; gap: 6px; }
    .sub-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap; }
    .sub-title { font-size: 10.5px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); }
    .redacted-pill { display: inline-block; padding: 0 5px; border-radius: 4px; background: var(--warn-soft); color: var(--warn); font-size: 10px; font-weight: 700; }

    /* Interactive JSON Tree */
    .json-tree { font-family: var(--mono); font-size: 11.5px; background: var(--surface); border: 1px solid var(--border); border-radius: 7px; padding: 10px; max-height: 360px; overflow: auto; }
    .json-node { margin-left: 14px; }
    .json-node.root { margin-left: 0; }
    .json-line { display: flex; align-items: baseline; gap: 4px; padding: 1.5px 4px; border-radius: 4px; }
    @media (hover: hover) { .json-line:hover { background: rgba(96, 165, 250, 0.09); } }
    .json-key { color: #93c5fd; cursor: pointer; }
    .json-str { color: #86efac; word-break: break-word; }
    .json-num { color: #fcd34d; }
    .json-bool { color: #c4b5fd; font-weight: 600; }
    .json-null { color: var(--muted); font-style: italic; }
    .json-punct { color: var(--muted); }
    .json-meta { color: var(--muted); font-size: 10.5px; margin-left: 4px; }
    .json-hit { background: var(--target-soft); color: #fef3c7; border-radius: 3px; padding: 0 2px; }

    /* Timing Breakdown & Waterfall */
    .timing-bar-track { display: flex; height: 10px; border-radius: 999px; overflow: hidden; background: var(--surface-3); border: 1px solid var(--border); }
    .t-seg { height: 100%; min-width: 2px; }
    .t-dns { background: #2dd4bf; }
    .t-tcp { background: #60a5fa; }
    .t-tls { background: #a78bfa; }
    .t-ttfb { background: #fbbf24; }
    .t-dl { background: #34d399; }
    .timing-legend { display: flex; flex-wrap: wrap; gap: 10px; font-family: var(--mono); font-size: 10.5px; color: var(--text-2); margin-top: 6px; }
    .t-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 4px; vertical-align: middle; }

    .wf-list { display: flex; flex-direction: column; gap: 5px; }
    .wf-row { display: grid; grid-template-columns: 62px 52px minmax(140px, 240px) minmax(140px, 1fr) 64px; gap: 8px; align-items: center; padding: 6px 10px; border-radius: 7px; border: 1px solid var(--border); background: var(--bg); cursor: pointer; }
    @media (hover: hover) { .wf-row:hover { background: var(--surface-2); } }
    .wf-row.active { border-color: var(--cyan); background: rgba(34, 211, 238, 0.09); }
    .wf-path { font-family: var(--mono); font-size: 11px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--text); }
    .wf-track { position: relative; height: 14px; background: var(--surface-2); border-radius: 4px; overflow: hidden; }
    .wf-bar { position: absolute; top: 2px; bottom: 2px; border-radius: 3px; display: flex; overflow: hidden; min-width: 4px; }
    @media (max-width: 820px) { .wf-row { grid-template-columns: 56px 48px minmax(90px, 1fr) 56px; } .wf-track { display: none; } }

    /* Structural JSON Diff */
    .diff-controls { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr) auto; gap: 8px; align-items: center; margin-bottom: 10px; }
    @media (max-width: 820px) { .diff-controls { grid-template-columns: 1fr; } }
    .diff-table { width: 100%; border-collapse: collapse; font-family: var(--mono); font-size: 11px; }
    .diff-table th { text-align: left; padding: 6px 10px; font-size: 10px; text-transform: uppercase; letter-spacing: 0.05em; color: var(--muted); background: var(--surface-2); border-bottom: 1px solid var(--border); }
    .diff-table td { padding: 6px 10px; border-bottom: 1px solid var(--border); vertical-align: top; word-break: break-word; }
    .diff-row.added { background: rgba(52, 211, 153, 0.09); }
    .diff-row.removed { background: rgba(248, 113, 113, 0.09); }
    .diff-row.changed { background: rgba(251, 191, 36, 0.09); }

    /* Assertion Card & Live Replay Drawer */
    .assert-card { border-radius: 9px; padding: 12px 14px; border: 1px solid var(--border); display: flex; flex-direction: column; gap: 8px; }
    .assert-card.pass { background: rgba(52, 211, 153, 0.08); border-color: rgba(52, 211, 153, 0.35); }
    .assert-card.fail { background: rgba(248, 113, 113, 0.09); border-color: rgba(248, 113, 113, 0.42); }
    .replay-drawer { margin-top: 10px; padding: 12px; border-radius: 8px; border: 1px solid rgba(34, 211, 238, 0.38); background: rgba(34, 211, 238, 0.05); display: flex; flex-direction: column; gap: 10px; }
    .replay-textarea { width: 100%; min-height: 74px; padding: 8px 10px; border-radius: 6px; border: 1px solid var(--border); background: var(--bg); color: var(--text); font-family: var(--mono); font-size: 11.5px; resize: vertical; }

    /* Web Visual / DOM / Network */
    .visual-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 12px; }
    .shot-frame { background: #090b10; border: 1px solid var(--border); border-radius: 8px; overflow: hidden; display: flex; flex-direction: column; }
    .shot-label { padding: 6px 10px; font-size: 11px; color: var(--text-2); background: var(--surface-2); border-bottom: 1px solid var(--border); display: flex; justify-content: space-between; }
    .shot-stage { position: relative; display: flex; align-items: center; justify-content: center; background: #07090d; min-height: 180px; cursor: zoom-in; overflow: hidden; }
    .shot-stage img { display: block; width: 100%; height: auto; max-height: 440px; object-fit: contain; }
    .target-reticle { position: absolute; border: 2px solid var(--target); background: rgba(245, 158, 11, 0.18); box-shadow: 0 0 0 2px rgba(0, 0, 0, 0.55); pointer-events: none; border-radius: 3px; }

    .curtain-wrap { position: relative; overflow: hidden; border-radius: 8px; border: 1px solid var(--border); background: #07090d; }
    .curtain-base { display: block; width: 100%; max-height: 460px; object-fit: contain; }
    .curtain-top { position: absolute; inset: 0; overflow: hidden; }
    .curtain-top img { display: block; width: 100%; height: 100%; object-fit: contain; }
    .curtain-line { position: absolute; top: 0; bottom: 0; width: 2px; background: var(--accent); pointer-events: none; }
    .curtain-controls { display: flex; align-items: center; gap: 10px; padding: 8px 12px; background: var(--surface-2); border-top: 1px solid var(--border); font-size: 11.5px; color: var(--text-2); }
    .curtain-controls input { flex: 1; accent-color: var(--accent); }

    .console-list { display: flex; flex-direction: column; gap: 6px; max-height: 340px; overflow-y: auto; }
    .console-row { display: grid; grid-template-columns: 78px minmax(0, 1fr) auto; gap: 8px; align-items: baseline; padding: 7px 10px; border-radius: 6px; background: var(--bg); border: 1px solid var(--border); font-family: var(--mono); font-size: 11.5px; }
    .console-row.error, .console-row.pageerror { border-color: rgba(248, 113, 113, 0.4); background: rgba(248, 113, 113, 0.08); }
    .console-row.warn { border-color: rgba(251, 191, 36, 0.35); background: rgba(251, 191, 36, 0.07); }
    .lvl-badge { font-size: 10px; font-weight: 700; text-transform: uppercase; padding: 1px 6px; border-radius: 4px; text-align: center; background: var(--surface-3); color: var(--text-2); }
    .console-row.error .lvl-badge, .console-row.pageerror .lvl-badge { background: var(--fail-soft); color: var(--fail); }
    .console-row.warn .lvl-badge { background: var(--warn-soft); color: var(--warn); }
    .console-msg { white-space: pre-wrap; word-break: break-word; }
    .console-loc { color: var(--muted); font-size: 10.5px; }

    .dom-tree { font-family: var(--mono); font-size: 11.5px; max-height: 520px; overflow: auto; background: var(--bg); border: 1px solid var(--border); border-radius: 8px; padding: 10px; }
    .dom-node { margin-left: 14px; }
    .dom-node.root { margin-left: 0; }
    .dom-line { display: flex; align-items: baseline; gap: 4px; padding: 2px 6px; border-radius: 4px; white-space: pre-wrap; word-break: break-all; }
    .dom-line.target-hit { background: var(--target-soft); border: 1px solid rgba(245, 158, 11, 0.6); color: #fef3c7; }
    .dom-toggle { border: none; background: transparent; color: var(--muted); cursor: pointer; width: 16px; padding: 0; font-size: 10px; flex: none; }
    .dom-tag { color: #7dd3fc; }
    .dom-attr { color: #c4b5fd; }
    .dom-val { color: #86efac; }
    .dom-txt { color: var(--text-2); }
    .dom-target-callout { padding: 10px 12px; background: var(--target-soft); border: 1px solid rgba(245, 158, 11, 0.45); border-radius: 8px; font-family: var(--mono); font-size: 11.5px; color: #fef3c7; overflow-x: auto; margin-bottom: 10px; }
    .dom-raw { font-family: var(--mono); font-size: 11.5px; background: var(--bg); border: 1px solid var(--border); border-radius: 8px; padding: 12px; max-height: 520px; overflow: auto; white-space: pre-wrap; word-break: break-word; margin: 0; }
    .dom-raw mark { background: var(--target-soft); color: #fde68a; border-radius: 3px; padding: 0 2px; }
    .dom-iframe { width: 100%; height: 500px; border: 1px solid var(--border); border-radius: 8px; background: #fff; }

    .net-table-wrap { overflow-x: auto; border: 1px solid var(--border); border-radius: 8px; }
    .net-table { width: 100%; border-collapse: collapse; font-size: 12px; }
    .net-table th { text-align: left; padding: 8px 10px; font-size: 10.5px; text-transform: uppercase; letter-spacing: 0.05em; color: var(--muted); background: var(--surface-2); border-bottom: 1px solid var(--border); }
    .net-table td { padding: 8px 10px; border-bottom: 1px solid var(--border); vertical-align: middle; }
    .net-row { cursor: pointer; }
    @media (hover: hover) { .net-row:hover { background: var(--surface-2); } }
    .net-row.selected { background: var(--accent-soft); }
    .net-url { font-family: var(--mono); font-size: 11.5px; max-width: 420px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .net-detail { margin-top: 12px; background: var(--bg); border: 1px solid var(--border); border-radius: 8px; padding: 12px; display: flex; flex-direction: column; gap: 10px; }
    .kv-grid { display: grid; grid-template-columns: minmax(120px, 210px) minmax(0, 1fr); gap: 4px 12px; font-family: var(--mono); font-size: 11px; }
    .kv-k { color: #93c5fd; word-break: break-word; }
    .kv-v { color: var(--text-2); word-break: break-all; }
    .code-box { font-family: var(--mono); font-size: 11.5px; background: var(--surface); border: 1px solid var(--border); border-radius: 6px; padding: 10px; margin: 0; max-height: 300px; overflow: auto; white-space: pre-wrap; word-break: break-word; }

    .empty-state { padding: 24px 16px; text-align: center; color: var(--muted); border: 1px dashed var(--border); border-radius: 8px; font-size: 12.5px; }

    .lightbox { background: var(--surface); color: var(--text); border: 1px solid var(--border-strong); border-radius: 12px; max-width: 92vw; max-height: 90vh; padding: 0; }
    .lightbox::backdrop { background: rgba(5, 7, 12, 0.78); backdrop-filter: blur(4px); }
    .lightbox-head { display: flex; justify-content: space-between; align-items: center; padding: 10px 14px; border-bottom: 1px solid var(--border); }
    .lightbox-body { padding: 12px; max-height: calc(90vh - 56px); overflow: auto; }
    .lightbox-body img { display: block; max-width: 100%; height: auto; border-radius: 6px; }

    @media (forced-colors: active) {
      .tb-btn[aria-pressed="true"], .chip[aria-pressed="true"] { border: 2px solid Highlight; }
      .tablist [role="tab"][aria-selected="true"]::after { border-block-end-color: Highlight; }
    }
    """#

    // MARK: - Embedded Client JavaScript

    private static let jsSource: String = #"""
    (function () {
      'use strict';

      const dataEl = document.getElementById('ceptra-report-data');
      const REPORT = JSON.parse(dataEl ? dataEl.textContent : '{"meta":{},"scenarios":[],"steps":[],"assets":{}}');
      const META = REPORT.meta || {};
      const STEPS = Array.isArray(REPORT.steps) ? REPORT.steps : [];
      const ASSETS = REPORT.assets || {};
      const REPORT_MODE = META.reportMode || 'web';
      const API_SOURCES = new Set(['http', 'https', 'fetch', 'rest', 'graphql', 'playwright-api']);
      function isApiExchangeEntry(req) {
        if (!req) return false;
        if (req.source && API_SOURCES.has(String(req.source).toLowerCase())) return true;
        return String(req.resourceType || '').toLowerCase() === 'api';
      }

      // Build flat index of all HTTP exchanges across the run for assertion linking, waterfall, and diffing
      const ALL_EXCHANGES = [];
      const EXCHANGE_BY_ID = new Map();
      for (const step of STEPS) {
        const reqs = step.networkRequests || [];
        for (let i = 0; i < reqs.length; i++) {
          const req = reqs[i];
          const item = {
            req,
            stepIndex: step.globalIndex,
            scenarioIndex: step.scenarioIndex,
            featureTitle: step.featureTitle,
            scenarioTitle: step.scenarioTitle,
            stepOffsetMs: step.relativeOffsetMs || 0,
            indexInStep: i,
            ordinal: ALL_EXCHANGES.length + 1
          };
          ALL_EXCHANGES.push(item);
          if (req.id) EXCHANGE_BY_ID.set(req.id, item);
        }
      }

      const HAS_ANY_API = REPORT_MODE === 'api' || REPORT_MODE === 'hybrid';

      const state = {
        activeIndex: 0,
        lastScenarioIndex: -1,
        statusFilter: 'all',
        searchQuery: '',
        activeTab: REPORT_MODE === 'api' ? 'api' : 'visual',
        apiViewMode: 'split',
        apiReqBodyMode: 'tree',
        apiResBodyMode: 'tree',
        apiReqSearch: '',
        apiResSearch: '',
        selectedApiExId: null,
        liveReplayOpen: false,
        liveReplayResult: null,
        liveReplayBusy: false,
        wfScope: 'scenario',
        wfFilter: 'all',
        diffBaseId: null,
        diffTargetId: null,
        diffOnlyChanges: true,
        visualMode: 'side',
        showReticle: true,
        curtainPct: 50,
        consoleFilter: 'all',
        domMode: 'tree',
        domSearch: '',
        netFilter: 'all',
        netSearch: '',
        selectedNetId: null,
        playing: false,
        playTimer: null
      };

      const maxStepDur = Math.max(1, ...STEPS.map((s) => s.durationMs || 0));
      const failureIndices = STEPS.reduce((acc, s, idx) => {
        if (s.status === 'failed') acc.push(idx);
        return acc;
      }, []);

      const els = {
        liveStatus: document.getElementById('live-status'),
        btnFirst: document.getElementById('btn-first'),
        btnPrev: document.getElementById('btn-prev'),
        btnPlay: document.getElementById('btn-play'),
        btnNext: document.getElementById('btn-next'),
        btnLast: document.getElementById('btn-last'),
        btnFail: document.getElementById('btn-fail'),
        scrubber: document.getElementById('step-scrubber'),
        ticks: document.getElementById('scrubber-ticks'),
        counter: document.getElementById('step-counter'),
        speed: document.getElementById('playback-speed'),
        search: document.getElementById('timeline-search'),
        timelineList: document.getElementById('timeline-list'),
        stepHero: document.getElementById('step-hero'),
        tabs: Array.from(document.querySelectorAll('[role="tab"]')),
        panels: Array.from(document.querySelectorAll('[role="tabpanel"]')),
        tabApi: document.getElementById('tab-api'),
        tabWaterfall: document.getElementById('tab-waterfall'),
        tabVisual: document.getElementById('tab-visual'),
        tabDom: document.getElementById('tab-dom'),
        tabNetwork: document.getElementById('tab-network'),
        badgeApi: document.getElementById('badge-api'),
        badgeWaterfall: document.getElementById('badge-waterfall'),
        badgeVisual: document.getElementById('badge-visual'),
        badgeDom: document.getElementById('badge-dom'),
        badgeNetwork: document.getElementById('badge-network'),
        apiContent: document.getElementById('api-content'),
        waterfallContent: document.getElementById('waterfall-content'),
        visualContent: document.getElementById('visual-content'),
        domContent: document.getElementById('dom-content'),
        networkContent: document.getElementById('network-content'),
        lightbox: document.getElementById('shot-lightbox'),
        lightboxTitle: document.getElementById('lightbox-title'),
        lightboxImg: document.getElementById('lightbox-img'),
        lightboxClose: document.getElementById('lightbox-close')
      };

      // Adapt visible tabs cleanly to the run type
      if (!HAS_ANY_API) {
        if (els.tabApi) els.tabApi.hidden = true;
        if (els.tabWaterfall) els.tabWaterfall.hidden = true;
      }
      if (REPORT_MODE === 'api') {
        if (els.tabDom) els.tabDom.hidden = true;
        if (els.tabVisual) {
          els.tabVisual.firstChild.textContent = 'Console & Raw ';
        }
      }

      function announce(msg) {
        if (els.liveStatus) els.liveStatus.textContent = msg;
      }

      function fmtDur(ms) {
        if (ms == null) return '—';
        if (ms < 1000) return `${ms}ms`;
        const s = ms / 1000;
        return s < 60 ? `${s.toFixed(2)}s` : `${Math.floor(s / 60)}m ${(s % 60).toFixed(1)}s`;
      }

      function fmtBytes(n) {
        if (typeof n !== 'number' || !Number.isFinite(n) || n <= 0) return null;
        if (n < 1024) return `${n} B`;
        if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
        return `${(n / (1024 * 1024)).toFixed(2)} MB`;
      }

      function fmtOffset(ms) {
        if (ms == null) return '+0.00s';
        return `+${(ms / 1000).toFixed(2)}s`;
      }

      function fmtTime(iso) {
        if (!iso) return '';
        const d = new Date(iso);
        if (Number.isNaN(d.getTime())) return iso;
        return d.toISOString().slice(11, 23);
      }

      function statusCls(st) {
        if (st === 'passed') return 'pass';
        if (st === 'failed') return 'fail';
        return 'skip';
      }

      function methodCls(method) {
        const m = String(method || 'GET').toLowerCase();
        if (['get', 'post', 'put', 'patch', 'delete'].includes(m)) return `m-${m}`;
        return '';
      }

      function statusBucket(req) {
        if (!req || req.errorText || req.status == null) return 'serr';
        if (req.status >= 500) return 's5';
        if (req.status >= 400) return 's4';
        if (req.status >= 300) return 's3';
        return 's2';
      }

      function shortPath(rawUrl) {
        try {
          const u = new URL(rawUrl);
          return (u.pathname || '/') + (u.search || '');
        } catch {
          return rawUrl || '';
        }
      }

      function tryParseJSON(raw) {
        if (typeof raw !== 'string') return { ok: false, value: null };
        const trimmed = raw.trim();
        if (!trimmed || (trimmed[0] !== '{' && trimmed[0] !== '[')) return { ok: false, value: null };
        try {
          return { ok: true, value: JSON.parse(trimmed) };
        } catch {
          return { ok: false, value: null };
        }
      }

      function prettyBody(raw) {
        if (!raw) return '';
        try { return JSON.stringify(JSON.parse(raw), null, 2); } catch { return raw; }
      }

      function shellSingleQuote(str) {
        return `'${String(str).replace(/'/g, `'\\''`)}'`;
      }

      function buildCurlCommand(req) {
        const parts = ['curl'];
        const m = (req.method || 'GET').toUpperCase();
        if (m !== 'GET') parts.push(`-X ${m}`);
        parts.push(shellSingleQuote(req.url || ''));
        const hdrs = req.requestHeaders || {};
        for (const k of Object.keys(hdrs).sort()) {
          const kl = k.toLowerCase();
          if (kl === 'content-length' || kl === 'host') continue;
          const val = hdrs[k] === '[REDACTED]' ? `<${k.toUpperCase()}>` : hdrs[k];
          parts.push(`-H ${shellSingleQuote(`${k}: ${val}`)}`);
        }
        if (req.requestBody) {
          parts.push(`--data-raw ${shellSingleQuote(req.requestBody)}`);
        }
        return parts.join(' \\\n  ');
      }

      function buildFetchSnippet(req) {
        const opts = { method: (req.method || 'GET').toUpperCase() };
        const hdrs = {};
        for (const [k, v] of Object.entries(req.requestHeaders || {})) {
          const kl = k.toLowerCase();
          if (kl === 'content-length' || kl === 'host') continue;
          hdrs[k] = v === '[REDACTED]' ? `<${k.toUpperCase()}>` : v;
        }
        if (Object.keys(hdrs).length > 0) opts.headers = hdrs;
        if (req.requestBody) opts.body = req.requestBody;
        return `const res = await fetch(${JSON.stringify(req.url || '')}, ${JSON.stringify(opts, null, 2)});\nconst data = await res.json();`;
      }

      function buildCodeceptSnippet(req) {
        const m = (req.method || 'GET').toUpperCase();
        const fnMap = {
          GET: 'sendGetRequest',
          POST: 'sendPostRequest',
          PUT: 'sendPutRequest',
          PATCH: 'sendPatchRequest',
          DELETE: 'sendDeleteRequest'
        };
        const fn = fnMap[m] || 'sendGetRequest';
        const args = [JSON.stringify(req.url || '')];
        if (req.requestBody && m !== 'GET') {
          const parsed = tryParseJSON(req.requestBody);
          args.push(parsed.ok ? JSON.stringify(parsed.value, null, 2) : JSON.stringify(req.requestBody));
        }
        return `await I.${fn}(${args.join(', ')});`;
      }

      function buildPlaywrightSnippet(req) {
        const m = (req.method || 'GET').toLowerCase();
        const fn = ['get', 'post', 'put', 'patch', 'delete', 'head'].includes(m) ? m : 'fetch';
        const urlStr = JSON.stringify(req.url || '');
        if (req.requestBody && m !== 'get' && m !== 'head') {
          const parsed = tryParseJSON(req.requestBody);
          const payloadOpt = parsed.ok
            ? `{ data: ${JSON.stringify(parsed.value, null, 2)} }`
            : `{ data: ${JSON.stringify(req.requestBody)} }`;
          return `const res = await request.${fn}(${urlStr}, ${payloadOpt});\nawait expect(res).toBeOK();`;
        }
        return `const res = await request.${fn}(${urlStr});\nawait expect(res).toBeOK();`;
      }

      function formatAssertionLabel(method) {
        const m = String(method || 'assert').trim();
        if (/^(?:expect|not\.|to[A-Z])/.test(m)) {
          return m.startsWith('expect') ? m : `expect(…).${m}(…)`;
        }
        return `I.${m}(…)`;
      }

      function el(tag, attrs, children) {
        const node = document.createElement(tag);
        if (attrs) {
          for (const [k, v] of Object.entries(attrs)) {
            if (v == null || v === false) continue;
            if (k === 'class') node.className = v;
            else if (k === 'text') node.textContent = v;
            else if (k.startsWith('on') && typeof v === 'function') node.addEventListener(k.slice(2).toLowerCase(), v);
            else node.setAttribute(k, String(v));
          }
        }
        if (children) {
          for (const c of Array.isArray(children) ? children : [children]) {
            if (c == null) continue;
            node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
          }
        }
        return node;
      }

      let toastTimer = null;
      function showToast(msg) {
        const toast = document.getElementById('copy-toast');
        if (!toast) return;
        toast.textContent = msg;
        toast.hidden = false;
        if (toastTimer) clearTimeout(toastTimer);
        toastTimer = setTimeout(() => { toast.hidden = true; }, 1900);
      }

      async function copyText(text, label) {
        let ok = false;
        if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
          try {
            await navigator.clipboard.writeText(text);
            ok = true;
          } catch {}
        }
        if (!ok) {
          try {
            const ta = document.createElement('textarea');
            ta.value = String(text ?? '');
            ta.setAttribute('readonly', '');
            ta.style.cssText = 'position:fixed;left:-9999px;top:-9999px;opacity:0';
            document.body.appendChild(ta);
            ta.focus();
            ta.select();
            ok = document.execCommand('copy');
            document.body.removeChild(ta);
          } catch {}
        }
        const msg = ok ? `Copied ${label}` : `Copy failed for ${label}`;
        announce(msg);
        showToast(msg);
      }

      // Reusable interactive JSON tree renderer with JSONPath click-to-copy & live search
      function buildJsonTreeNode(keyName, value, jsonPath, depth, query) {
        const isArr = Array.isArray(value);
        const isObj = value !== null && typeof value === 'object';
        const q = (query || '').trim().toLowerCase();

        if (!isObj) {
          const keyStr = keyName != null ? String(keyName) : '';
          const valStr = value === null ? 'null' : (typeof value === 'string' ? JSON.stringify(value) : String(value));
          const selfMatch = !q || keyStr.toLowerCase().includes(q) || valStr.toLowerCase().includes(q);
          if (!selfMatch) return null;

          const line = el('div', { class: 'json-line' });
          line.appendChild(el('span', { class: 'dom-toggle', text: ' ' }));
          if (keyName != null) {
            const kEl = el('span', {
              class: `json-key${q && keyStr.toLowerCase().includes(q) ? ' json-hit' : ''}`,
              text: `"${keyStr}"`,
              title: `Click to copy JSONPath: ${jsonPath}`,
              onClick: () => copyText(jsonPath, `JSONPath ${jsonPath}`)
            });
            line.appendChild(kEl);
            line.appendChild(el('span', { class: 'json-punct', text: ': ' }));
          }
          const valCls = value === null
            ? 'json-null'
            : (typeof value === 'string' ? 'json-str' : (typeof value === 'number' ? 'json-num' : 'json-bool'));
          line.appendChild(el('span', {
            class: `${valCls}${q && valStr.toLowerCase().includes(q) ? ' json-hit' : ''}`,
            text: valStr.length > 260 ? valStr.slice(0, 260) + '…"' : valStr,
            title: `Click to copy value (${jsonPath})`,
            onClick: () => copyText(typeof value === 'string' ? value : valStr, jsonPath)
          }));
          return el('div', { class: `json-node${depth === 0 ? ' root' : ''}` }, [line]);
        }

        const entries = isArr ? value.map((v, i) => [i, v]) : Object.entries(value);
        const childNodes = [];
        for (const [k, v] of entries) {
          const childPath = isArr ? `${jsonPath}[${k}]` : (/^[A-Za-z_$][\w$]*$/.test(String(k)) ? `${jsonPath}.${k}` : `${jsonPath}[${JSON.stringify(k)}]`);
          const rendered = buildJsonTreeNode(isArr ? null : k, v, childPath, depth + 1, q);
          if (rendered) childNodes.push(rendered);
        }
        const keyStr = keyName != null ? String(keyName) : '';
        const selfMatch = !q || keyStr.toLowerCase().includes(q);
        if (q && !selfMatch && childNodes.length === 0) return null;

        const openDefault = depth < 2 || Boolean(q) || entries.length <= 4;
        const line = el('div', { class: 'json-line' });
        const childrenWrap = childNodes.length > 0 ? el('div', { style: openDefault ? '' : 'display:none' }, childNodes) : null;

        if (childrenWrap) {
          const toggle = el('button', {
            type: 'button',
            class: 'dom-toggle',
            'aria-expanded': openDefault ? 'true' : 'false',
            text: openDefault ? '▾' : '▸',
            onClick: () => {
              const open = toggle.getAttribute('aria-expanded') === 'true';
              toggle.setAttribute('aria-expanded', open ? 'false' : 'true');
              toggle.textContent = open ? '▸' : '▾';
              childrenWrap.style.display = open ? 'none' : '';
            }
          });
          line.appendChild(toggle);
        } else {
          line.appendChild(el('span', { class: 'dom-toggle', text: ' ' }));
        }

        if (keyName != null) {
          line.appendChild(el('span', {
            class: `json-key${q && keyStr.toLowerCase().includes(q) ? ' json-hit' : ''}`,
            text: `"${keyStr}"`,
            title: `Click to copy JSONPath: ${jsonPath}`,
            onClick: () => copyText(jsonPath, `JSONPath ${jsonPath}`)
          }));
          line.appendChild(el('span', { class: 'json-punct', text: ': ' }));
        }

        const openBracket = isArr ? '[' : '{';
        const closeBracket = isArr ? ']' : '}';
        const countLabel = isArr ? `${entries.length} item${entries.length === 1 ? '' : 's'}` : `${entries.length} key${entries.length === 1 ? '' : 's'}`;
        line.appendChild(el('span', { class: 'json-punct', text: entries.length === 0 ? `${openBracket}${closeBracket}` : openBracket }));
        if (entries.length > 0) {
          line.appendChild(el('span', { class: 'json-meta', text: `${countLabel} ${closeBracket}` }));
        }

        return el('div', { class: `json-node${depth === 0 ? ' root' : ''}` }, [line, childrenWrap]);
      }

      function buildPayloadViewer(rawBody, modeKey, searchKey, copyLabel, rerenderFn) {
        const container = el('div', { class: 'sub-section' });
        const parsed = tryParseJSON(rawBody);
        const mode = state[modeKey];
        const controls = el('div', { class: 'tb-group' });
        if (parsed.ok) {
          for (const [m, lbl] of [['tree', 'JSON Tree'], ['raw', 'Raw']]) {
            controls.appendChild(el('button', {
              type: 'button',
              class: 'chip',
              'aria-pressed': mode === m ? 'true' : 'false',
              onClick: () => { state[modeKey] = m; rerenderFn(); }
            }, lbl));
          }
        }
        controls.appendChild(el('button', {
          type: 'button',
          class: 'tb-btn',
          text: 'Copy',
          onClick: () => copyText(parsed.ok ? prettyBody(rawBody) : rawBody, copyLabel)
        }));

        container.appendChild(el('div', { class: 'sub-head' }, [
          el('span', { class: 'sub-title', text: `${copyLabel}${parsed.ok ? ' (JSON)' : ''}` }),
          controls
        ]));

        if (parsed.ok && mode === 'tree') {
          const treeHost = el('div', { class: 'json-tree' });
          const renderTree = () => {
            treeHost.replaceChildren();
            const rootNode = buildJsonTreeNode(null, parsed.value, '$', 0, state[searchKey]);
            if (rootNode) treeHost.appendChild(rootNode);
            else treeHost.appendChild(el('div', { class: 'empty-state', text: 'No JSON keys or values match your filter.' }));
          };
          container.appendChild(el('input', {
            type: 'search',
            class: 'search-input',
            value: state[searchKey] || '',
            placeholder: 'Search JSON keys or values… (click any key to copy $.path)',
            onInput: (e) => { state[searchKey] = e.target.value; renderTree(); }
          }));
          renderTree();
          container.appendChild(treeHost);
        } else {
          container.appendChild(el('pre', { class: 'code-box', text: parsed.ok ? prettyBody(rawBody) : rawBody }));
        }
        return container;
      }

      function buildQueryParamsSection(rawUrl) {
        try {
          const u = new URL(rawUrl);
          const pairs = Array.from(u.searchParams.entries());
          if (!pairs.length) return null;
          const grid = el('div', { class: 'kv-grid' });
          for (const [k, v] of pairs) {
            grid.appendChild(el('span', { class: 'kv-k', text: k }));
            grid.appendChild(el('span', { class: 'kv-v', text: v }));
          }
          return el('div', { class: 'sub-section' }, [
            el('span', { class: 'sub-title', text: `Query Parameters (${pairs.length})` }),
            grid
          ]);
        } catch {
          return null;
        }
      }

      function buildHeadersSection(title, hdrs) {
        const keys = Object.keys(hdrs || {}).sort();
        if (!keys.length) return null;
        const grid = el('div', { class: 'kv-grid' });
        for (const k of keys) {
          grid.appendChild(el('span', { class: 'kv-k', text: k }));
          if (hdrs[k] === '[REDACTED]') {
            grid.appendChild(el('span', { class: 'kv-v' }, [el('span', { class: 'redacted-pill', text: 'REDACTED' })]));
          } else {
            grid.appendChild(el('span', { class: 'kv-v', text: hdrs[k] }));
          }
        }
        return el('div', { class: 'sub-section' }, [
          el('span', { class: 'sub-title', text: `${title} (${keys.length})` }),
          grid
        ]);
      }

      function buildTimingBreakdown(req) {
        const t = req && req.timings;
        const total = (t && t.totalMs != null) ? t.totalMs : req.durationMs;
        if (!t || total == null || total <= 0) return null;
        const parts = [
          ['dns', 'DNS', t.dnsMs, 't-dns'],
          ['tcp', 'TCP', t.connectMs, 't-tcp'],
          ['tls', 'TLS', t.tlsMs, 't-tls'],
          ['ttfb', 'TTFB', t.ttfbMs, 't-ttfb'],
          ['dl', 'Download', t.downloadMs, 't-dl']
        ].filter((p) => typeof p[2] === 'number' && p[2] > 0);
        if (!parts.length) return null;

        const sum = Math.max(1, parts.reduce((a, p) => a + p[2], 0));
        const track = el('div', { class: 'timing-bar-track' });
        const legend = el('div', { class: 'timing-legend' });
        for (const [, lbl, ms, cls] of parts) {
          const pct = Math.max(2, (ms / sum) * 100);
          track.appendChild(el('div', { class: `t-seg ${cls}`, style: `width:${pct}%`, title: `${lbl}: ${ms}ms` }));
          legend.appendChild(el('span', null, [
            el('span', { class: `t-dot ${cls}` }),
            `${lbl} ${ms}ms`
          ]));
        }
        legend.appendChild(el('span', { style: 'margin-left:auto;color:var(--text)', text: `Total ${fmtDur(total)}` }));
        return el('div', { style: 'padding:10px 14px;border-bottom:1px solid var(--border);background:var(--bg)' }, [track, legend]);
      }

      // Compute structural JSON diff between two parsed JS values
      function computeStructuralDiff(a, b, basePath, out) {
        if (a === b) return;
        const aIsObj = a !== null && typeof a === 'object';
        const bIsObj = b !== null && typeof b === 'object';
        if (!aIsObj || !bIsObj || Array.isArray(a) !== Array.isArray(b)) {
          out.push({ path: basePath, kind: 'changed', before: a, after: b });
          return;
        }
        if (Array.isArray(a)) {
          const maxLen = Math.max(a.length, b.length);
          for (let i = 0; i < maxLen; i++) {
            const p = `${basePath}[${i}]`;
            if (i >= a.length) out.push({ path: p, kind: 'added', before: undefined, after: b[i] });
            else if (i >= b.length) out.push({ path: p, kind: 'removed', before: a[i], after: undefined });
            else computeStructuralDiff(a[i], b[i], p, out);
          }
          return;
        }
        const keys = Array.from(new Set([...Object.keys(a), ...Object.keys(b)])).sort();
        for (const k of keys) {
          const p = /^[A-Za-z_$][\w$]*$/.test(k) ? `${basePath}.${k}` : `${basePath}[${JSON.stringify(k)}]`;
          if (!(k in a)) out.push({ path: p, kind: 'added', before: undefined, after: b[k] });
          else if (!(k in b)) out.push({ path: p, kind: 'removed', before: a[k], after: undefined });
          else computeStructuralDiff(a[k], b[k], p, out);
        }
      }

      function fmtDiffVal(val) {
        if (val === undefined) return '—';
        try {
          const s = JSON.stringify(val);
          return s.length > 180 ? s.slice(0, 177) + '…' : s;
        } catch {
          return String(val);
        }
      }

      function parseCapturedHTML(rawHTML) {
        if (!rawHTML) return null;
        try { return new DOMParser().parseFromString(rawHTML, 'text/html'); } catch { return null; }
      }

      function filteredSteps() {
        const q = state.searchQuery.trim().toLowerCase();
        return STEPS.filter((s) => {
          if (state.statusFilter === 'api') {
            if (!(s.networkRequests && s.networkRequests.length > 0)) return false;
          } else if (state.statusFilter !== 'all' && s.status !== state.statusFilter) {
            return false;
          }
          if (!q) return true;
          if ((s.text || '').toLowerCase().includes(q)) return true;
          if ((s.scenarioTitle || '').toLowerCase().includes(q)) return true;
          if ((s.featureTitle || '').toLowerCase().includes(q)) return true;
          if ((s.targetSelector || '').toLowerCase().includes(q)) return true;
          if ((s.pageURL || '').toLowerCase().includes(q)) return true;
          for (const r of (s.networkRequests || [])) {
            if ((r.method || '').toLowerCase().includes(q)) return true;
            if ((r.url || '').toLowerCase().includes(q)) return true;
            if (r.status != null && String(r.status).includes(q)) return true;
            if ((r.responseBody || '').toLowerCase().includes(q)) return true;
            if ((r.requestBody || '').toLowerCase().includes(q)) return true;
          }
          return false;
        });
      }

      function renderTicks() {
        els.ticks.replaceChildren();
        STEPS.forEach((s, idx) => {
          const isApi = s.scenarioKind === 'api' || ((s.networkRequests || []).some(isApiExchangeEntry) && !s.beforeShotAssetId && !s.afterShotAssetId);
          const t = el('div', {
            class: `scrubber-tick ${statusCls(s.status)}${isApi ? ' api-tick' : ''}${idx === state.activeIndex ? ' active' : ''}`,
            title: `#${idx + 1} ${s.text}`,
            onClick: () => selectStep(idx)
          });
          els.ticks.appendChild(t);
        });
      }

      function renderTimeline() {
        const list = filteredSteps();
        els.timelineList.replaceChildren();
        if (list.length === 0) {
          els.timelineList.appendChild(el('div', { class: 'empty-state', text: 'No steps match the current filter.' }));
          return;
        }
        let lastScenarioIdx = -1;
        for (const step of list) {
          if (step.scenarioIndex !== lastScenarioIdx) {
            lastScenarioIdx = step.scenarioIndex;
            const kindPill = REPORT_MODE === 'hybrid'
              ? el('span', {
                  class: `mini-tag ${step.scenarioKind === 'api' ? 'cyan' : (step.scenarioKind === 'hybrid' ? 'violet' : '')}`,
                  text: step.scenarioKind === 'api' ? 'API' : (step.scenarioKind === 'hybrid' ? 'WEB+API' : 'WEB')
                })
              : null;
            const head = el('div', { class: 'scenario-divider' }, [
              el('div', { style: 'min-width:0;flex:1' }, [
                el('span', { class: 'sc-feat', text: step.featureTitle }),
                el('span', { class: 'sc-name', text: step.scenarioTitle })
              ]),
              el('div', { style: 'display:flex;align-items:center;gap:5px;flex:none' }, [
                kindPill,
                el('span', { class: `status-pill ${statusCls(step.scenarioStatus)}`, text: step.scenarioStatus.toUpperCase() })
              ])
            ]);
            els.timelineList.appendChild(head);
          }

          const isSelected = step.globalIndex === state.activeIndex;
          const durPct = Math.min(100, Math.max(4, Math.round(((step.durationMs || 0) / maxStepDur) * 100)));
          const errLogs = (step.consoleEntries || []).filter((c) => c.level === 'error' || c.level === 'pageerror').length;
          const reqs = step.networkRequests || [];
          const hasShot = Boolean(step.beforeShotAssetId || step.afterShotAssetId);
          const hasDom = Boolean(step.domAssetId);

          const metaRow = el('div', { class: 'step-row-meta' }, [
            el('span', { class: 'mono', text: fmtOffset(step.relativeOffsetMs) }),
            el('div', { class: 'dur-bar' }, [el('div', { class: 'dur-fill', style: `width:${durPct}%` })])
          ]);
          if (reqs.length > 0) {
            const first = reqs[0];
            const st = first.errorText ? 'ERR' : (first.status != null ? String(first.status) : '…');
            const stCls = first.errorText || (first.status != null && first.status >= 500)
              ? 'err'
              : (first.status != null && first.status >= 400 ? 'warn' : 'pass');
            metaRow.appendChild(el('span', { class: `mini-tag ${stCls}`, text: `${first.method || 'GET'} ${st}` }));
            if (reqs.length > 1) {
              metaRow.appendChild(el('span', { class: 'mini-tag cyan', text: `+${reqs.length - 1}` }));
            }
          }
          if (step.assertion) {
            metaRow.appendChild(el('span', {
              class: `mini-tag ${step.assertion.passed ? 'violet' : 'err'}`,
              text: step.assertion.passed ? 'ASSERT ✓' : 'ASSERT ✗'
            }));
          }
          if (errLogs > 0) metaRow.appendChild(el('span', { class: 'mini-tag err', text: `ERR ${errLogs}` }));
          if (hasShot) metaRow.appendChild(el('span', { class: 'mini-tag', text: 'IMG' }));
          if (hasDom) metaRow.appendChild(el('span', { class: 'mini-tag', text: 'DOM' }));

          const btn = el('button', {
            type: 'button',
            role: 'option',
            id: `timeline-step-${step.globalIndex}`,
            class: `step-item ${statusCls(step.status)}`,
            'aria-selected': isSelected ? 'true' : 'false',
            style: step.depth > 0 ? `padding-left:${9 + step.depth * 14}px` : null,
            onClick: () => selectStep(step.globalIndex)
          }, [
            el('div', { class: 'step-row-top' }, [
              el('span', { class: 'step-idx mono', text: `#${step.globalIndex + 1}` }),
              el('span', { class: `step-dot ${statusCls(step.status)}` }),
              el('span', { class: 'step-text', text: step.text, title: step.text }),
              el('span', { class: 'step-dur mono', text: fmtDur(step.durationMs) })
            ]),
            metaRow
          ]);
          els.timelineList.appendChild(btn);
        }
      }

      function renderHero(step) {
        els.stepHero.replaceChildren();
        if (!step) {
          els.stepHero.appendChild(el('div', { class: 'empty-state', text: 'No test steps were recorded for this run.' }));
          return;
        }
        const chips = el('div', { class: 'hero-chips' }, [
          el('span', { class: `status-pill ${statusCls(step.status)}`, text: step.status.toUpperCase() }),
          el('span', { class: 'meta-pill mono', text: `${fmtTime(step.startedAtISO)} (${fmtOffset(step.relativeOffsetMs)})` }),
          el('span', { class: 'meta-pill mono', text: fmtDur(step.durationMs) })
        ]);
        if (step.targetSelector) {
          chips.appendChild(el('span', { class: 'meta-pill target mono', text: `target: ${step.targetSelector}` }));
        }
        if (step.pageURL) {
          chips.appendChild(el('span', { class: 'meta-pill mono', text: step.pageURL, title: step.pageURL }));
        }

        els.stepHero.appendChild(el('div', { class: 'hero-top' }, [
          el('div', { style: 'min-width:0;flex:1' }, [
            el('div', { class: 'hero-breadcrumb', text: `${step.featureTitle} › ${step.scenarioTitle} · Step ${step.globalIndex + 1} of ${STEPS.length}` }),
            el('div', { class: 'hero-title', text: step.text })
          ]),
          chips
        ]));

        if (step.errorMessage || (step.status === 'failed' && step.scenarioErrorStack)) {
          const msg = step.scenarioErrorStack && step.status === 'failed'
            ? step.scenarioErrorStack
            : (step.errorMessage || step.scenarioErrorMessage);
          if (msg) {
            els.stepHero.appendChild(el('div', { class: 'error-banner', text: msg }));
          }
        }
      }

      // MARK: - API Exchange Inspector (Primary Stage for API Replay)

      function resolveStepExchanges(step) {
        if (!step) return { exchanges: [], linkedFromAssertion: false };
        const direct = (step.networkRequests || []).map((req, idx) => ({
          req,
          linked: false,
          label: `#${idx + 1}`
        }));
        if (direct.length > 0) return { exchanges: direct, linkedFromAssertion: false };
        if (step.assertion && step.assertion.relatedRequestId && EXCHANGE_BY_ID.has(step.assertion.relatedRequestId)) {
          const hit = EXCHANGE_BY_ID.get(step.assertion.relatedRequestId);
          return { exchanges: [{ req: hit.req, linked: true, linkedStepIndex: hit.stepIndex }], linkedFromAssertion: true };
        }
        return { exchanges: [], linkedFromAssertion: false };
      }

      function renderApiExchange(step) {
        els.apiContent.replaceChildren();
        if (!step) return;

        // 1. Assertion Card if this step is an assertion (I.expect*, I.seeResponse*)
        if (step.assertion) {
          const a = step.assertion;
          const aCard = el('div', { class: `assert-card ${a.passed ? 'pass' : 'fail'}` }, [
            el('div', { style: 'display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap' }, [
              el('div', { style: 'display:flex;align-items:center;gap:8px' }, [
                el('span', { class: `status-pill ${a.passed ? 'pass' : 'fail'}`, text: a.passed ? 'ASSERTION PASSED' : 'ASSERTION FAILED' }),
                el('span', { class: 'mono', style: 'font-weight:600', text: formatAssertionLabel(a.method) })
              ]),
              a.relatedRequestId && EXCHANGE_BY_ID.has(a.relatedRequestId)
                ? el('button', {
                    type: 'button',
                    class: 'tb-btn',
                    text: `Jump to API Step #${EXCHANGE_BY_ID.get(a.relatedRequestId).stepIndex + 1}`,
                    onClick: () => selectStep(EXCHANGE_BY_ID.get(a.relatedRequestId).stepIndex)
                  })
                : null
            ])
          ]);
          if (a.expected || a.actual) {
            const cols = el('div', { class: `api-split${a.expected && a.actual ? '' : ' single'}` });
            if (a.expected) {
              cols.appendChild(el('div', { class: 'sub-section' }, [
                el('span', { class: 'sub-title', text: 'Expected' }),
                el('pre', { class: 'code-box', text: a.expected })
              ]));
            }
            if (a.actual) {
              cols.appendChild(el('div', { class: 'sub-section' }, [
                el('span', { class: 'sub-title', text: 'Actual' }),
                el('pre', { class: 'code-box', text: a.actual })
              ]));
            }
            aCard.appendChild(cols);
          }
          if (a.message) {
            aCard.appendChild(el('div', { class: 'error-banner', text: a.message }));
          }
          els.apiContent.appendChild(aCard);
        }

        const { exchanges, linkedFromAssertion } = resolveStepExchanges(step);
        if (exchanges.length === 0) {
          els.apiContent.appendChild(el('div', { class: 'card' }, [
            el('div', { class: 'card-head' }, [el('span', { class: 'card-title', text: 'API Request & Response Replay' })]),
            el('div', { class: 'card-body' }, [
              el('div', {
                class: 'empty-state',
                text: 'No HTTP exchange was recorded on this step. Use Prev/Next (←/→) or the Waterfall tab to jump to an API request step.'
              })
            ])
          ]));
          return;
        }

        if (!exchanges.some((x) => x.req.id === state.selectedApiExId)) {
          state.selectedApiExId = exchanges[0].req.id;
          state.liveReplayResult = null;
        }
        const activeWrap = exchanges.find((x) => x.req.id === state.selectedApiExId) || exchanges[0];
        const req = activeWrap.req;

        // Exchange switcher strip if this step made multiple HTTP calls (e.g. paginated requests)
        if (exchanges.length > 1) {
          const strip = el('div', { class: 'exchange-strip', role: 'group', 'aria-label': 'HTTP calls in this step' });
          exchanges.forEach((wrap, i) => {
            const r = wrap.req;
            const st = r.errorText ? 'ERR' : (r.status != null ? String(r.status) : '…');
            strip.appendChild(el('button', {
              type: 'button',
              class: `exchange-pill${r.id === req.id ? ' active' : ''}`,
              onClick: () => { state.selectedApiExId = r.id; state.liveReplayResult = null; renderApiExchange(step); }
            }, [
              el('span', { class: `method-badge ${methodCls(r.method)}`, text: r.method || 'GET' }),
              el('span', { text: `${i + 1}. ${shortPath(r.url)}` }),
              el('span', { class: `status-code ${statusBucket(r)}`, text: st }),
              el('span', { style: 'color:var(--muted)', text: fmtDur(r.durationMs) })
            ]));
          });
          els.apiContent.appendChild(strip);
        }

        const statusText = req.errorText
          ? 'NETWORK ERROR'
          : (req.status != null ? `${req.status}${req.statusText ? ' ' + req.statusText : ''}` : 'PENDING');
        const reqSize = fmtBytes(req.requestSizeBytes);
        const resSize = fmtBytes(req.responseSizeBytes);
        const sizeLabel = [reqSize ? `↑ ${reqSize}` : null, resSize ? `↓ ${resSize}` : null].filter(Boolean).join('  ');

        const viewModes = el('div', { class: 'tb-group', role: 'group', 'aria-label': 'API inspector layout' });
        for (const [m, lbl] of [['split', 'Side-by-Side'], ['request', 'Request'], ['response', 'Response']]) {
          viewModes.appendChild(el('button', {
            type: 'button',
            class: 'chip',
            'aria-pressed': state.apiViewMode === m ? 'true' : 'false',
            onClick: () => { state.apiViewMode = m; renderApiExchange(step); }
          }, lbl));
        }

        const isPlaywrightApi = String(req.source || '').toLowerCase() === 'playwright-api';
        const actionBtns = el('div', { class: 'tb-group' }, [
          el('button', { type: 'button', class: 'tb-btn', text: 'Copy cURL', onClick: () => copyText(buildCurlCommand(req), 'cURL command') }),
          el('button', { type: 'button', class: 'tb-btn', text: 'Copy fetch()', onClick: () => copyText(buildFetchSnippet(req), 'fetch() snippet') }),
          isPlaywrightApi
            ? el('button', { type: 'button', class: 'tb-btn', text: 'Playwright', onClick: () => copyText(buildPlaywrightSnippet(req), 'Playwright snippet') })
            : el('button', { type: 'button', class: 'tb-btn', text: 'CodeceptJS', onClick: () => copyText(buildCodeceptSnippet(req), 'CodeceptJS snippet') }),
          el('button', {
            type: 'button',
            class: 'tb-btn primary',
            'aria-pressed': state.liveReplayOpen ? 'true' : 'false',
            text: state.liveReplayOpen ? 'Hide Live Replay' : 'Replay Live ▸',
            onClick: () => { state.liveReplayOpen = !state.liveReplayOpen; renderApiExchange(step); }
          })
        ]);

        const card = el('div', { class: 'card' });
        const heroBar = el('div', { class: 'api-hero-bar' }, [
          linkedFromAssertion
            ? el('div', { class: 'mono', style: 'font-size:11px;color:var(--cyan)' }, `Asserted against preceding HTTP exchange (Step #${(activeWrap.linkedStepIndex ?? 0) + 1}):`)
            : null,
          el('div', { class: 'api-hero-url-row' }, [
            el('span', { class: `method-badge ${methodCls(req.method)}`, text: req.method || 'GET' }),
            el('span', { class: 'api-url-text', text: req.url || '', title: req.url || '' }),
            el('span', { class: `status-code ${statusBucket(req)}`, text: statusText }),
            el('span', { class: 'meta-pill mono', text: fmtDur(req.durationMs) }),
            sizeLabel ? el('span', { class: 'meta-pill mono', text: sizeLabel }) : null,
            req.source ? el('span', { class: 'mini-tag cyan', text: req.source.toUpperCase() }) : null
          ]),
          el('div', { class: 'api-hero-actions' }, [viewModes, actionBtns])
        ]);
        card.appendChild(heroBar);

        const timingEl = buildTimingBreakdown(req);
        if (timingEl) card.appendChild(timingEl);

        const cardBody = el('div', { class: 'card-body' });
        if (req.errorText) {
          cardBody.appendChild(el('div', { class: 'error-banner', style: 'margin-bottom:12px', text: req.errorText }));
        }

        // Live Replay Drawer (optional in-browser fetch replayer)
        if (state.liveReplayOpen) {
          cardBody.appendChild(buildLiveReplayDrawer(req, () => renderApiExchange(step)));
        }

        const splitWrap = el('div', { class: `api-split${state.apiViewMode === 'split' ? '' : ' single'}` });

        if (state.apiViewMode === 'split' || state.apiViewMode === 'request') {
          const reqPaneBody = el('div', { class: 'api-pane-body' });
          const qp = buildQueryParamsSection(req.url);
          if (qp) reqPaneBody.appendChild(qp);
          const rh = buildHeadersSection('Request Headers', req.requestHeaders);
          if (rh) reqPaneBody.appendChild(rh);
          if (req.requestBody) {
            reqPaneBody.appendChild(buildPayloadViewer(req.requestBody, 'apiReqBodyMode', 'apiReqSearch', 'Request Body', () => renderApiExchange(step)));
          } else if (!qp && !rh) {
            reqPaneBody.appendChild(el('div', { class: 'empty-state', text: 'No query params, headers, or request body.' }));
          } else {
            reqPaneBody.appendChild(el('div', { class: 'sub-title', style: 'opacity:0.7', text: 'Request Body: (empty)' }));
          }
          splitWrap.appendChild(el('div', { class: 'api-pane' }, [
            el('div', { class: 'api-pane-head' }, [
              el('span', { class: 'card-title', text: 'Request' }),
              reqSize ? el('span', { class: 'mono', style: 'font-size:11px;color:var(--muted)', text: reqSize }) : null
            ]),
            reqPaneBody
          ]));
        }

        if (state.apiViewMode === 'split' || state.apiViewMode === 'response') {
          const resPaneBody = el('div', { class: 'api-pane-body' });
          const resh = buildHeadersSection('Response Headers', req.responseHeaders);
          if (resh) resPaneBody.appendChild(resh);
          if (req.responseBody) {
            resPaneBody.appendChild(buildPayloadViewer(req.responseBody, 'apiResBodyMode', 'apiResSearch', 'Response Body', () => renderApiExchange(step)));
          } else {
            resPaneBody.appendChild(el('div', { class: 'empty-state', text: req.errorText ? 'No response received due to network error.' : 'Empty response body (e.g. 204 No Content).' }));
          }
          splitWrap.appendChild(el('div', { class: 'api-pane' }, [
            el('div', { class: 'api-pane-head' }, [
              el('span', { class: 'card-title', text: 'Response' }),
              el('span', { class: `status-code ${statusBucket(req)}`, text: statusText })
            ]),
            resPaneBody
          ]));
        }

        cardBody.appendChild(splitWrap);
        card.appendChild(cardBody);
        els.apiContent.appendChild(card);
      }

      function buildLiveReplayDrawer(req, rerenderFn) {
        const defaultHeaders = {};
        for (const [k, v] of Object.entries(req.requestHeaders || {})) {
          const kl = k.toLowerCase();
          if (['host', 'content-length', 'connection', 'accept-encoding', 'user-agent'].includes(kl)) continue;
          if (v === '[REDACTED]') continue;
          defaultHeaders[k] = v;
        }
        const urlInput = el('input', { type: 'text', class: 'search-input mono', value: req.url || '' });
        const methodSelect = el('select', { class: 'select-input mono' }, ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'].map((m) =>
          el('option', { value: m, selected: m === (req.method || 'GET').toUpperCase() ? 'selected' : null, text: m })
        ));
        const headersArea = el('textarea', { class: 'replay-textarea', placeholder: '{"Accept": "application/json"}' });
        headersArea.value = JSON.stringify(defaultHeaders, null, 2);
        const bodyArea = el('textarea', { class: 'replay-textarea', placeholder: 'Optional request body…' });
        bodyArea.value = req.requestBody || '';

        const resultHost = el('div');
        if (state.liveReplayResult) {
          const res = state.liveReplayResult;
          if (res.error) {
            resultHost.appendChild(el('div', { class: 'error-banner', text: `${res.error}\n\nTip: Browsers enforce CORS when replaying cross-origin APIs from a local HTML file. Use "Copy cURL" above to replay directly in your terminal with full TLS/auth support.` }));
          } else {
            const parsed = tryParseJSON(res.body);
            resultHost.appendChild(el('div', { class: 'sub-section' }, [
              el('div', { class: 'sub-head' }, [
                el('span', { class: 'sub-title', text: 'Live Replay Result' }),
                el('div', { class: 'tb-group' }, [
                  el('span', { class: `status-code ${res.status >= 500 ? 's5' : res.status >= 400 ? 's4' : res.status >= 300 ? 's3' : 's2'}`, text: `${res.status} ${res.statusText || ''}` }),
                  el('span', { class: 'meta-pill mono', text: fmtDur(res.durationMs) })
                ])
              ]),
              el('pre', { class: 'code-box', text: parsed.ok ? prettyBody(res.body) : (res.body || '(empty body)') })
            ]));
          }
        }

        const sendBtn = el('button', {
          type: 'button',
          class: 'tb-btn primary',
          text: state.liveReplayBusy ? 'Sending…' : 'Send Live Request',
          onClick: async () => {
            if (state.liveReplayBusy) return;
            state.liveReplayBusy = true;
            state.liveReplayResult = null;
            rerenderFn();
            const t0 = performance.now();
            try {
              let parsedHeaders = {};
              const rawH = headersArea.value.trim();
              if (rawH) parsedHeaders = JSON.parse(rawH);
              const method = methodSelect.value;
              const init = { method, headers: parsedHeaders };
              if (method !== 'GET' && method !== 'HEAD' && bodyArea.value.length > 0) {
                init.body = bodyArea.value;
              }
              const resp = await fetch(urlInput.value.trim(), init);
              const txt = await resp.text();
              state.liveReplayResult = {
                status: resp.status,
                statusText: resp.statusText,
                durationMs: Math.round(performance.now() - t0),
                body: txt
              };
            } catch (err) {
              state.liveReplayResult = { error: err && err.message ? err.message : String(err) };
            }
            state.liveReplayBusy = false;
            rerenderFn();
          }
        });

        return el('div', { class: 'replay-drawer' }, [
          el('div', { class: 'sub-head' }, [
            el('span', { class: 'card-title', style: 'color:var(--cyan)', text: 'Live Replay Request (Browser Fetch)' }),
            sendBtn
          ]),
          el('div', { style: 'display:flex;gap:8px' }, [methodSelect, urlInput]),
          el('div', { class: 'api-split' }, [
            el('div', { class: 'sub-section' }, [el('span', { class: 'sub-title', text: 'Headers (JSON — redacted auth omitted)' }), headersArea]),
            el('div', { class: 'sub-section' }, [el('span', { class: 'sub-title', text: 'Body' }), bodyArea])
          ]),
          resultHost
        ]);
      }

      // MARK: - Waterfall Timeline & Structural JSON Diff

      function renderWaterfallAndDiff(step) {
        els.waterfallContent.replaceChildren();
        if (!step) return;

        // 1. Waterfall Card
        const scopeExchanges = state.wfScope === 'scenario'
          ? ALL_EXCHANGES.filter((x) => x.scenarioIndex === step.scenarioIndex)
          : ALL_EXCHANGES;

        const filteredExchanges = scopeExchanges.filter((x) => {
          const r = x.req;
          if (state.wfFilter === 'ok') return !r.errorText && r.status != null && r.status >= 200 && r.status < 300;
          if (state.wfFilter === 'err') return Boolean(r.errorText) || (r.status != null && r.status >= 400);
          if (state.wfFilter === 'slow') return (r.durationMs || 0) >= 300;
          return true;
        });

        const wfControls = el('div', { class: 'tb-group' });
        for (const [sc, lbl] of [['scenario', 'Current Scenario'], ['run', `Entire Run (${ALL_EXCHANGES.length})`]]) {
          wfControls.appendChild(el('button', {
            type: 'button',
            class: 'chip',
            'aria-pressed': state.wfScope === sc ? 'true' : 'false',
            onClick: () => { state.wfScope = sc; renderWaterfallAndDiff(step); }
          }, lbl));
        }
        wfControls.appendChild(el('span', { class: 'tb-sep' }));
        for (const [fk, lbl] of [['all', 'All'], ['ok', '2xx'], ['err', '4xx/5xx'], ['slow', '>300ms']]) {
          wfControls.appendChild(el('button', {
            type: 'button',
            class: 'chip',
            'aria-pressed': state.wfFilter === fk ? 'true' : 'false',
            onClick: () => { state.wfFilter = fk; renderWaterfallAndDiff(step); }
          }, lbl));
        }

        const wfBody = el('div', { class: 'card-body' });
        if (filteredExchanges.length === 0) {
          wfBody.appendChild(el('div', { class: 'empty-state', text: 'No HTTP requests match this waterfall scope/filter.' }));
        } else {
          const times = filteredExchanges.map((x) => {
            const t = x.req.startedAt ? Date.parse(x.req.startedAt) : NaN;
            return Number.isNaN(t) ? x.stepOffsetMs : t;
          });
          const minStart = Math.min(...times);
          const maxEnd = Math.max(...filteredExchanges.map((x, i) => times[i] + Math.max(1, x.req.durationMs || 1)));
          const totalSpan = Math.max(1, maxEnd - minStart);

          const wfList = el('div', { class: 'wf-list' });
          filteredExchanges.forEach((item, i) => {
            const r = item.req;
            const start = times[i];
            const dur = Math.max(1, r.durationMs || 1);
            const leftPct = Math.max(0, Math.min(96, ((start - minStart) / totalSpan) * 100));
            const widthPct = Math.max(2, Math.min(100 - leftPct, (dur / totalSpan) * 100));
            const isActiveStep = item.stepIndex === step.globalIndex;
            const stLabel = r.errorText ? 'ERR' : (r.status != null ? String(r.status) : '…');

            const bar = el('div', { class: 'wf-bar', style: `left:${leftPct}%;width:${widthPct}%` });
            const tm = r.timings;
            if (tm && tm.totalMs > 0) {
              const segs = [
                [tm.dnsMs, 't-dns'],
                [tm.connectMs, 't-tcp'],
                [tm.tlsMs, 't-tls'],
                [tm.ttfbMs, 't-ttfb'],
                [tm.downloadMs, 't-dl']
              ].filter((s) => typeof s[0] === 'number' && s[0] > 0);
              const sum = Math.max(1, segs.reduce((a, s) => a + s[0], 0));
              if (segs.length > 0) {
                for (const [ms, cls] of segs) {
                  bar.appendChild(el('div', { class: `t-seg ${cls}`, style: `width:${(ms / sum) * 100}%` }));
                }
              } else {
                bar.appendChild(el('div', { class: 't-seg t-ttfb', style: 'width:100%' }));
              }
            } else {
              bar.appendChild(el('div', { class: `t-seg ${r.errorText || (r.status || 0) >= 400 ? 't-tls' : 't-dl'}`, style: 'width:100%' }));
            }

            wfList.appendChild(el('div', {
              class: `wf-row${isActiveStep ? ' active' : ''}`,
              title: `${r.method} ${r.url} (${stLabel}, ${fmtDur(r.durationMs)}) — click to inspect in API Exchange (Step #${item.stepIndex + 1})`,
              onClick: () => {
                selectStep(item.stepIndex);
                state.selectedApiExId = r.id;
                renderApiExchange(STEPS[item.stepIndex]);
                selectTab('api');
              }
            }, [
              el('span', { class: `method-badge ${methodCls(r.method)}`, text: r.method || 'GET' }),
              el('span', { class: `status-code ${statusBucket(r)}`, text: stLabel }),
              el('span', { class: 'wf-path', text: shortPath(r.url) }),
              el('div', { class: 'wf-track' }, [bar]),
              el('span', { class: 'mono', style: 'text-align:right;font-size:11px;color:var(--text-2)', text: fmtDur(r.durationMs) })
            ]));
          });
          wfBody.appendChild(wfList);
        }

        els.waterfallContent.appendChild(el('div', { class: 'card' }, [
          el('div', { class: 'card-head' }, [
            el('span', { class: 'card-title', text: 'HTTP Request Waterfall' }),
            wfControls
          ]),
          wfBody
        ]));

        // 2. Structural JSON Response Diff Card
        const diffBody = el('div', { class: 'card-body' });
        if (ALL_EXCHANGES.length < 2) {
          diffBody.appendChild(el('div', { class: 'empty-state', text: 'Capture at least 2 API exchanges in a run to compare responses side-by-side.' }));
        } else {
          // Pick sensible defaults if unset
          const activeEx = ALL_EXCHANGES.find((x) => x.stepIndex === step.globalIndex) || ALL_EXCHANGES[ALL_EXCHANGES.length - 1];
          if (!state.diffTargetId || !EXCHANGE_BY_ID.has(state.diffTargetId)) {
            state.diffTargetId = activeEx.req.id;
          }
          if (!state.diffBaseId || !EXCHANGE_BY_ID.has(state.diffBaseId)) {
            const targetIdx = ALL_EXCHANGES.findIndex((x) => x.req.id === state.diffTargetId);
            const targetPath = shortPath(ALL_EXCHANGES[Math.max(0, targetIdx)].req.url).split('?')[0];
            let prevSame = null;
            for (let i = targetIdx - 1; i >= 0; i--) {
              if (shortPath(ALL_EXCHANGES[i].req.url).split('?')[0] === targetPath) {
                prevSame = ALL_EXCHANGES[i];
                break;
              }
            }
            const fallback = targetIdx > 0 ? ALL_EXCHANGES[targetIdx - 1] : ALL_EXCHANGES[0];
            state.diffBaseId = (prevSame || fallback).req.id;
          }

          const makeOptionLabel = (x) => `#${x.ordinal} (Step ${x.stepIndex + 1}) ${x.req.method} ${shortPath(x.req.url)} [${x.req.status ?? 'ERR'}]`;
          const baseSel = el('select', {
            class: 'select-input mono',
            'aria-label': 'Baseline API exchange',
            onChange: (e) => { state.diffBaseId = e.target.value; renderWaterfallAndDiff(step); }
          }, ALL_EXCHANGES.map((x) => el('option', { value: x.req.id, selected: x.req.id === state.diffBaseId ? 'selected' : null, text: `Base: ${makeOptionLabel(x)}` })));

          const targetSel = el('select', {
            class: 'select-input mono',
            'aria-label': 'Target API exchange',
            onChange: (e) => { state.diffTargetId = e.target.value; renderWaterfallAndDiff(step); }
          }, ALL_EXCHANGES.map((x) => el('option', { value: x.req.id, selected: x.req.id === state.diffTargetId ? 'selected' : null, text: `Target: ${makeOptionLabel(x)}` })));

          const swapBtn = el('button', {
            type: 'button',
            class: 'tb-btn',
            text: '⇄ Swap',
            onClick: () => {
              const tmp = state.diffBaseId;
              state.diffBaseId = state.diffTargetId;
              state.diffTargetId = tmp;
              renderWaterfallAndDiff(step);
            }
          });

          diffBody.appendChild(el('div', { class: 'diff-controls' }, [baseSel, targetSel, swapBtn]));

          const baseItem = EXCHANGE_BY_ID.get(state.diffBaseId);
          const targetItem = EXCHANGE_BY_ID.get(state.diffTargetId);
          if (baseItem && targetItem) {
            const pA = tryParseJSON(baseItem.req.responseBody || '');
            const pB = tryParseJSON(targetItem.req.responseBody || '');
            if (pA.ok && pB.ok) {
              const diffs = [];
              computeStructuralDiff(pA.value, pB.value, '$', diffs);
              if (diffs.length === 0) {
                diffBody.appendChild(el('div', { class: 'empty-state', text: 'Identical JSON response payloads (0 differences).' }));
              } else {
                const added = diffs.filter((d) => d.kind === 'added').length;
                const removed = diffs.filter((d) => d.kind === 'removed').length;
                const changed = diffs.filter((d) => d.kind === 'changed').length;
                diffBody.appendChild(el('div', { class: 'hero-chips', style: 'margin-bottom:8px' }, [
                  el('span', { class: 'mini-tag pass', text: `+${added} added` }),
                  el('span', { class: 'mini-tag err', text: `-${removed} removed` }),
                  el('span', { class: 'mini-tag warn', text: `~${changed} changed` })
                ]));

                const tbody = el('tbody');
                for (const d of diffs.slice(0, 200)) {
                  const badgeCls = d.kind === 'added' ? 'pass' : (d.kind === 'removed' ? 'err' : 'warn');
                  const sym = d.kind === 'added' ? '+' : (d.kind === 'removed' ? '-' : '~');
                  tbody.appendChild(el('tr', { class: `diff-row ${d.kind}` }, [
                    el('td', null, el('span', { class: `mini-tag ${badgeCls}`, text: sym })),
                    el('td', { style: 'color:#93c5fd', text: d.path }),
                    el('td', { style: 'color:var(--text-2)', text: fmtDiffVal(d.before) }),
                    el('td', { style: 'color:var(--text)', text: fmtDiffVal(d.after) })
                  ]));
                }
                diffBody.appendChild(el('div', { class: 'net-table-wrap' }, [
                  el('table', { class: 'diff-table' }, [
                    el('thead', null, el('tr', null, [
                      el('th', { text: '' }),
                      el('th', { text: 'JSONPath' }),
                      el('th', { text: `Base (#${baseItem.ordinal})` }),
                      el('th', { text: `Target (#${targetItem.ordinal})` })
                    ])),
                    tbody
                  ])
                ]));
              }
            } else {
              diffBody.appendChild(el('div', { class: 'api-split' }, [
                el('div', { class: 'sub-section' }, [
                  el('span', { class: 'sub-title', text: `Base (#${baseItem.ordinal})` }),
                  el('pre', { class: 'code-box', text: baseItem.req.responseBody || '(empty)' })
                ]),
                el('div', { class: 'sub-section' }, [
                  el('span', { class: 'sub-title', text: `Target (#${targetItem.ordinal})` }),
                  el('pre', { class: 'code-box', text: targetItem.req.responseBody || '(empty)' })
                ])
              ]));
            }
          }
        }

        els.waterfallContent.appendChild(el('div', { class: 'card' }, [
          el('div', { class: 'card-head' }, [
            el('span', { class: 'card-title', text: 'Response Diff & Comparison' })
          ]),
          diffBody
        ]));
      }

      // MARK: - Web Visual, DOM & Network Inspectors

      function buildShotStage(uri, label, box) {
        const stage = el('div', {
          class: 'shot-stage',
          onClick: () => {
            if (!els.lightbox || !uri) return;
            els.lightboxTitle.textContent = label;
            els.lightboxImg.src = uri;
            els.lightbox.showModal();
          }
        }, [el('img', { src: uri, alt: label })]);

        if (state.showReticle && box && box.viewportWidth > 0 && box.viewportHeight > 0) {
          const left = Math.max(0, Math.min(100, (box.x / box.viewportWidth) * 100));
          const top = Math.max(0, Math.min(100, (box.y / box.viewportHeight) * 100));
          const width = Math.max(1.5, Math.min(100 - left, (box.width / box.viewportWidth) * 100));
          const height = Math.max(1.5, Math.min(100 - top, (box.height / box.viewportHeight) * 100));
          stage.appendChild(el('div', {
            class: 'target-reticle',
            style: `left:${left}%;top:${top}%;width:${width}%;height:${height}%`,
            title: 'Target element'
          }));
        }
        return stage;
      }

      function renderVisualAndConsole(step) {
        els.visualContent.replaceChildren();
        if (!step) return;

        const beforeURI = step.beforeShotAssetId ? ASSETS[step.beforeShotAssetId] : null;
        const afterURI = step.afterShotAssetId ? ASSETS[step.afterShotAssetId] : null;
        const hasBoth = Boolean(beforeURI && afterURI);

        // 1. Visual Diff Card (omitted on API-only runs or pure API scenarios when no screenshots exist)
        const isApiOnlyStep = REPORT_MODE === 'api' || step.scenarioKind === 'api';
        if (!isApiOnlyStep || beforeURI || afterURI) {
          const modeGroup = el('div', { class: 'tb-group', role: 'group', 'aria-label': 'Screenshot view mode' });
          for (const [m, lbl] of [['side', 'Side-by-Side'], ['before', 'Before'], ['after', 'After'], ['curtain', 'Curtain Diff']]) {
            modeGroup.appendChild(el('button', {
              type: 'button',
              class: 'chip',
              'aria-pressed': state.visualMode === m ? 'true' : 'false',
              onClick: () => { state.visualMode = m; renderVisualAndConsole(step); }
            }, lbl));
          }
          if (step.targetBoundingBox) {
            modeGroup.appendChild(el('button', {
              type: 'button',
              class: 'chip',
              'aria-pressed': state.showReticle ? 'true' : 'false',
              onClick: () => { state.showReticle = !state.showReticle; renderVisualAndConsole(step); }
            }, 'Target Overlay'));
          }

          const shotBody = el('div', { class: 'card-body' });
          if (!beforeURI && !afterURI) {
            shotBody.appendChild(el('div', {
              class: 'empty-state',
              text: 'No screenshots were captured for this step. Run browser-backed web tests with Time-Travel Trace enabled to capture before/after frames.'
            }));
          } else if (state.visualMode === 'curtain' && hasBoth) {
            const topLayer = el('div', { class: 'curtain-top', style: `clip-path: inset(0 ${100 - state.curtainPct}% 0 0)` }, [
              el('img', { src: beforeURI, alt: 'Before step screenshot' })
            ]);
            const divider = el('div', { class: 'curtain-line', style: `left:${state.curtainPct}%` });
            const slider = el('input', {
              type: 'range',
              min: '0',
              max: '100',
              value: String(state.curtainPct),
              'aria-label': 'Before and after comparison slider',
              onInput: (e) => {
                state.curtainPct = Number(e.target.value);
                topLayer.style.clipPath = `inset(0 ${100 - state.curtainPct}% 0 0)`;
                divider.style.left = `${state.curtainPct}%`;
              }
            });
            shotBody.appendChild(el('div', { class: 'curtain-wrap' }, [
              el('img', { class: 'curtain-base', src: afterURI, alt: 'After step screenshot' }),
              topLayer,
              divider,
              el('div', { class: 'curtain-controls' }, [
                el('span', { text: 'Before' }),
                slider,
                el('span', { text: 'After' })
              ])
            ]));
          } else {
            const grid = el('div', { class: 'visual-grid' });
            if ((state.visualMode === 'side' || state.visualMode === 'before' || (state.visualMode === 'curtain' && !hasBoth)) && beforeURI) {
              grid.appendChild(el('div', { class: 'shot-frame' }, [
                el('div', { class: 'shot-label' }, [el('span', { text: 'Before Action' }), el('span', { class: 'mono', text: 'Click to zoom' })]),
                buildShotStage(beforeURI, `Step #${step.globalIndex + 1} — Before`, step.targetBoundingBox)
              ]));
            }
            if ((state.visualMode === 'side' || state.visualMode === 'after' || (state.visualMode === 'curtain' && !hasBoth)) && afterURI) {
              grid.appendChild(el('div', { class: 'shot-frame' }, [
                el('div', { class: 'shot-label' }, [el('span', { text: 'After Action' }), el('span', { class: 'mono', text: 'Click to zoom' })]),
                buildShotStage(afterURI, `Step #${step.globalIndex + 1} — After`, step.targetBoundingBox)
              ]));
            }
            if (!grid.childNodes.length) {
              grid.appendChild(el('div', { class: 'empty-state', text: 'Requested frame was not captured for this step.' }));
            }
            shotBody.appendChild(grid);
          }

          els.visualContent.appendChild(el('div', { class: 'card' }, [
            el('div', { class: 'card-head' }, [
              el('span', { class: 'card-title', text: 'Before / After Visual State' }),
              modeGroup
            ]),
            shotBody
          ]));
        }

        // 2. Browser Console & Uncaught Errors Card
        const entries = step.consoleEntries || [];
        const counts = {
          all: entries.length,
          errors: entries.filter((c) => c.level === 'error' || c.level === 'pageerror').length,
          warnings: entries.filter((c) => c.level === 'warn').length,
          logs: entries.filter((c) => c.level === 'log' || c.level === 'info' || c.level === 'debug').length
        };

        const consoleFilters = el('div', { class: 'tb-group', role: 'group', 'aria-label': 'Filter console logs' });
        for (const [key, lbl] of [['all', `All (${counts.all})`], ['errors', `Errors (${counts.errors})`], ['warnings', `Warnings (${counts.warnings})`], ['logs', `Logs (${counts.logs})`]]) {
          consoleFilters.appendChild(el('button', {
            type: 'button',
            class: 'chip',
            'aria-pressed': state.consoleFilter === key ? 'true' : 'false',
            onClick: () => { state.consoleFilter = key; renderVisualAndConsole(step); }
          }, lbl));
        }

        const filteredConsole = entries.filter((c) => {
          if (state.consoleFilter === 'errors') return c.level === 'error' || c.level === 'pageerror';
          if (state.consoleFilter === 'warnings') return c.level === 'warn';
          if (state.consoleFilter === 'logs') return c.level === 'log' || c.level === 'info' || c.level === 'debug';
          return true;
        });

        const consoleBody = el('div', { class: 'card-body' });
        if (filteredConsole.length === 0) {
          consoleBody.appendChild(el('div', { class: 'empty-state', text: entries.length === 0 ? 'No browser console logs, warnings, or uncaught errors during this step.' : 'No console entries match this severity filter.' }));
        } else {
          const list = el('div', { class: 'console-list' });
          for (const entry of filteredConsole) {
            const loc = entry.sourceURL ? `${entry.sourceURL.split('/').pop()}${entry.lineNumber != null ? ':' + entry.lineNumber : ''}` : '';
            list.appendChild(el('div', { class: `console-row ${entry.level}` }, [
              el('span', { class: 'lvl-badge', text: entry.level }),
              el('span', { class: 'console-msg', text: entry.message }),
              el('span', { class: 'console-loc', text: loc || fmtTime(entry.timestamp) })
            ]));
          }
          consoleBody.appendChild(list);
        }

        els.visualContent.appendChild(el('div', { class: 'card' }, [
          el('div', { class: 'card-head' }, [
            el('span', { class: 'card-title', text: 'Browser Console & Uncaught Errors' }),
            consoleFilters
          ]),
          consoleBody
        ]));

        // 3. On API runs, also surface the raw CLI run output cleanly here
        if (REPORT_MODE === 'api' && META.rawOutput) {
          els.visualContent.appendChild(el('div', { class: 'card' }, [
            el('div', { class: 'card-head' }, [
              el('span', { class: 'card-title', text: 'Raw Runner Output' }),
              el('button', { type: 'button', class: 'tb-btn', text: 'Copy Output', onClick: () => copyText(META.rawOutput, 'Raw output') })
            ]),
            el('div', { class: 'card-body' }, [
              el('pre', { class: 'code-box', style: 'max-height:420px', text: META.rawOutput })
            ])
          ]));
        }
      }

      function buildDomTreeElement(node, depth, query, targetNodes, isRoot) {
        if (!node) return null;
        if (node.nodeType === 3) {
          const txt = (node.textContent || '').trim();
          if (!txt) return null;
          if (query && !txt.toLowerCase().includes(query)) return null;
          return el('div', { class: 'dom-node' }, [
            el('div', { class: 'dom-line' }, [el('span', { class: 'dom-txt', text: txt.length > 180 ? txt.slice(0, 180) + '…' : txt })])
          ]);
        }
        if (node.nodeType !== 1) return null;

        const tag = node.tagName.toLowerCase();
        const isTarget = targetNodes.has(node) || node.getAttribute('data-ceptra-target') === 'true';
        const childNodes = Array.from(node.childNodes);
        const childEls = [];
        for (const ch of childNodes) {
          const rendered = buildDomTreeElement(ch, depth + 1, query, targetNodes, false);
          if (rendered) childEls.push(rendered);
        }

        const attrsText = Array.from(node.attributes || [])
          .filter((a) => a.name !== 'data-ceptra-target')
          .map((a) => `${a.name}="${a.value}"`).join(' ');
        const selfMatches = !query || tag.includes(query) || attrsText.toLowerCase().includes(query);
        if (query && !selfMatches && childEls.length === 0) return null;

        const containsTarget = isTarget || childEls.some((c) => c.dataset && c.dataset.hasTarget === '1');
        const expandedByDefault = depth < 3 || containsTarget || Boolean(query);

        const line = el('div', { class: `dom-line${isTarget ? ' target-hit' : ''}` });
        const childrenWrap = childEls.length > 0 ? el('div', { style: expandedByDefault ? '' : 'display:none' }, childEls) : null;

        if (childrenWrap) {
          const toggle = el('button', {
            type: 'button',
            class: 'dom-toggle',
            'aria-expanded': expandedByDefault ? 'true' : 'false',
            text: expandedByDefault ? '▾' : '▸',
            onClick: () => {
              const open = toggle.getAttribute('aria-expanded') === 'true';
              toggle.setAttribute('aria-expanded', open ? 'false' : 'true');
              toggle.textContent = open ? '▸' : '▾';
              childrenWrap.style.display = open ? 'none' : '';
            }
          });
          line.appendChild(toggle);
        } else {
          line.appendChild(el('span', { class: 'dom-toggle', text: ' ' }));
        }

        line.appendChild(el('span', { class: 'dom-tag', text: `<${tag}` }));
        for (const attr of Array.from(node.attributes || [])) {
          if (attr.name === 'data-ceptra-target') continue;
          line.appendChild(document.createTextNode(' '));
          line.appendChild(el('span', { class: 'dom-attr', text: attr.name }));
          line.appendChild(document.createTextNode('='));
          line.appendChild(el('span', { class: 'dom-val', text: `"${attr.value.length > 80 ? attr.value.slice(0, 80) + '…' : attr.value}"` }));
        }
        line.appendChild(el('span', { class: 'dom-tag', text: '>' }));
        if (isTarget) {
          line.appendChild(el('span', { class: 'mini-tag', style: 'margin-left:8px;background:rgba(245,158,11,0.35);color:#fef3c7', text: 'TARGET' }));
        }

        const wrapper = el('div', { class: `dom-node${isRoot ? ' root' : ''}` }, [line, childrenWrap]);
        if (containsTarget) wrapper.dataset.hasTarget = '1';
        if (isTarget) wrapper.dataset.isTarget = '1';
        return wrapper;
      }

      function renderDOM(step) {
        els.domContent.replaceChildren();
        if (!step) return;

        const rawHTML = step.domAssetId ? ASSETS[step.domAssetId] : null;
        const controls = el('div', { class: 'tb-group', role: 'group', 'aria-label': 'DOM snapshot view mode' });
        for (const [m, lbl] of [['tree', 'Interactive Tree'], ['raw', 'HTML Source'], ['preview', 'Sandboxed Preview']]) {
          controls.appendChild(el('button', {
            type: 'button',
            class: 'chip',
            'aria-pressed': state.domMode === m ? 'true' : 'false',
            onClick: () => { state.domMode = m; renderDOM(step); }
          }, lbl));
        }
        if (rawHTML) {
          controls.appendChild(el('button', {
            type: 'button',
            class: 'tb-btn',
            text: 'Copy HTML',
            onClick: () => copyText(rawHTML, 'DOM HTML')
          }));
        }

        const body = el('div', { class: 'card-body' });
        if (!rawHTML) {
          body.appendChild(el('div', {
            class: 'empty-state',
            text: 'No DOM snapshot captured for this step. Browser-backed steps automatically snapshot HTML and highlight targeted elements.'
          }));
        } else {
          if (step.targetSelector || step.targetOuterHTML) {
            const callout = el('div', { class: 'dom-target-callout' }, [
              el('div', { style: 'font-weight:700;margin-bottom:4px', text: `Target Element${step.targetSelector ? ` (${step.targetSelector})` : ''}${step.matchedCount ? ` · ${step.matchedCount} matched` : ''}` }),
              step.targetOuterHTML ? el('div', { text: step.targetOuterHTML }) : null
            ]);
            body.appendChild(callout);
          }

          if (state.domMode === 'tree') {
            const treeHost = el('div', { class: 'dom-tree' });
            const searchBar = el('div', { style: 'display:flex;gap:8px;margin-bottom:10px' }, [
              el('input', {
                type: 'search',
                class: 'search-input',
                value: state.domSearch,
                placeholder: 'Search DOM tags, attributes, or text…',
                'aria-label': 'Search DOM tree',
                onInput: (e) => { state.domSearch = e.target.value; renderDOMTreeOnly(treeHost, rawHTML, step); }
              }),
              el('button', {
                type: 'button',
                class: 'tb-btn',
                text: 'Jump to Target',
                onClick: () => {
                  const hit = treeHost.querySelector('[data-is-target="1"]');
                  if (hit) {
                    hit.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    announce('Scrolled to target DOM element');
                  } else {
                    announce('No highlighted target element in snapshot');
                  }
                }
              })
            ]);
            renderDOMTreeOnly(treeHost, rawHTML, step);
            body.appendChild(searchBar);
            body.appendChild(treeHost);
          } else if (state.domMode === 'raw') {
            const pre = el('pre', { class: 'dom-raw' });
            if (step.targetOuterHTML && rawHTML.includes(step.targetOuterHTML)) {
              const idx = rawHTML.indexOf(step.targetOuterHTML);
              pre.appendChild(document.createTextNode(rawHTML.slice(0, idx)));
              pre.appendChild(el('mark', { text: step.targetOuterHTML }));
              pre.appendChild(document.createTextNode(rawHTML.slice(idx + step.targetOuterHTML.length)));
            } else {
              pre.textContent = rawHTML;
            }
            body.appendChild(pre);
          } else {
            // Strictly sandboxed iframe (`sandbox=""` disables scripts, forms, popups, and same-origin access)
            const highlightStyle = '<style>[data-ceptra-target="true"]{outline:3px solid #f59e0b !important;outline-offset:2px !important;background:rgba(245,158,11,0.18) !important;}</style>';
            const safeDoc = parseCapturedHTML(rawHTML);
            let sanitizedSrcdoc = rawHTML;
            if (safeDoc && safeDoc.documentElement) {
              safeDoc.querySelectorAll('script, iframe, object, embed').forEach((n) => n.remove());
              if (step.targetSelector && !safeDoc.querySelector('[data-ceptra-target="true"]')) {
                try {
                  safeDoc.querySelectorAll(step.targetSelector).forEach((n) => n.setAttribute('data-ceptra-target', 'true'));
                } catch {}
              }
              sanitizedSrcdoc = '<!doctype html>' + highlightStyle + safeDoc.documentElement.outerHTML;
            }
            body.appendChild(el('iframe', {
              class: 'dom-iframe',
              sandbox: '',
              title: 'Sandboxed DOM Snapshot Preview',
              srcdoc: sanitizedSrcdoc
            }));
          }
        }

        els.domContent.appendChild(el('div', { class: 'card' }, [
          el('div', { class: 'card-head' }, [
            el('span', { class: 'card-title', text: `DOM / HTML Snapshot${step.domTitle ? ` — ${step.domTitle}` : ''}` }),
            controls
          ]),
          body
        ]));
      }

      function renderDOMTreeOnly(treeHost, rawHTML, step) {
        treeHost.replaceChildren();
        const doc = parseCapturedHTML(rawHTML);
        if (!doc || !doc.documentElement) {
          treeHost.appendChild(el('div', { class: 'empty-state', text: 'Unable to parse HTML snapshot.' }));
          return;
        }
        const targetNodes = new Set(Array.from(doc.querySelectorAll('[data-ceptra-target="true"]')));
        if (targetNodes.size === 0 && step.targetSelector) {
          try {
            doc.querySelectorAll(step.targetSelector).forEach((n) => targetNodes.add(n));
          } catch {}
        }
        const tree = buildDomTreeElement(doc.documentElement, 0, state.domSearch.trim().toLowerCase(), targetNodes, true);
        if (tree) treeHost.appendChild(tree);
        else treeHost.appendChild(el('div', { class: 'empty-state', text: 'No DOM nodes match your search.' }));
      }

      function renderNetwork(step) {
        els.networkContent.replaceChildren();
        if (!step) return;

        const allReqs = step.networkRequests || [];
        const filters = el('div', { class: 'tb-group', role: 'group', 'aria-label': 'Filter network requests' });
        for (const [k, lbl] of [['all', `All (${allReqs.length})`], ['xhr', 'API / XHR / Fetch'], ['errors', 'Errors (4xx/5xx)']]) {
          filters.appendChild(el('button', {
            type: 'button',
            class: 'chip',
            'aria-pressed': state.netFilter === k ? 'true' : 'false',
            onClick: () => { state.netFilter = k; renderNetwork(step); }
          }, lbl));
        }

        const body = el('div', { class: 'card-body' });
        if (allReqs.length === 0) {
          body.appendChild(el('div', { class: 'empty-state', text: 'No HTTP/XHR network traffic was triggered during this step.' }));
        } else {
          const resultsHost = el('div');
          const renderNetworkResults = () => {
            resultsHost.replaceChildren();
            const filtered = allReqs.filter((r) => {
              if (state.netFilter === 'xhr' && r.resourceType !== 'fetch' && r.resourceType !== 'xhr' && r.resourceType !== 'api') return false;
              if (state.netFilter === 'errors' && !r.errorText && (r.status == null || r.status < 400)) return false;
              const q = state.netSearch.trim().toLowerCase();
              if (q && !(r.url || '').toLowerCase().includes(q) && !(r.method || '').toLowerCase().includes(q)) return false;
              return true;
            });

            if (filtered.length === 0) {
              resultsHost.appendChild(el('div', { class: 'empty-state', text: 'No requests match this filter.' }));
              return;
            }
            if (!filtered.some((r) => r.id === state.selectedNetId)) {
              state.selectedNetId = filtered[0].id;
            }
            const tbody = el('tbody');
            for (const req of filtered) {
              const sel = req.id === state.selectedNetId;
              const statusLabel = req.errorText ? 'FAILED' : (req.status != null ? String(req.status) : '…');
              tbody.appendChild(el('tr', {
                class: `net-row${sel ? ' selected' : ''}`,
                onClick: () => { state.selectedNetId = req.id; renderNetworkResults(); }
              }, [
                el('td', null, el('span', { class: `method-badge ${methodCls(req.method)}`, text: req.method || 'GET' })),
                el('td', null, el('span', { class: `status-code ${statusBucket(req)}`, text: statusLabel })),
                el('td', { class: 'net-url', text: req.url, title: req.url }),
                el('td', { class: 'mono', text: req.source || req.resourceType || '—' }),
                el('td', { class: 'mono', text: fmtDur(req.durationMs) })
              ]));
            }

            resultsHost.appendChild(el('div', { class: 'net-table-wrap' }, [
              el('table', { class: 'net-table' }, [
                el('thead', null, el('tr', null, [
                  el('th', { text: 'Method' }),
                  el('th', { text: 'Status' }),
                  el('th', { text: 'URL' }),
                  el('th', { text: 'Type' }),
                  el('th', { text: 'Time' })
                ])),
                tbody
              ])
            ]));

            const chosen = filtered.find((r) => r.id === state.selectedNetId);
            if (chosen) {
              const detail = el('div', { class: 'net-detail' });
              detail.appendChild(el('div', { style: 'display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap' }, [
                el('span', { class: 'mono', style: 'font-weight:600;word-break:break-all', text: `${chosen.method} ${chosen.url}` }),
                el('div', { class: 'tb-group' }, [
                  el('button', { type: 'button', class: 'tb-btn', text: 'Copy cURL', onClick: () => copyText(buildCurlCommand(chosen), 'cURL command') }),
                  el('button', { type: 'button', class: 'tb-btn', text: 'Copy URL', onClick: () => copyText(chosen.url, 'Request URL') })
                ])
              ]));
              const tb = buildTimingBreakdown(chosen);
              if (tb) detail.appendChild(tb);
              if (chosen.errorText) {
                detail.appendChild(el('div', { class: 'error-banner', text: chosen.errorText }));
              }
              const qp = buildQueryParamsSection(chosen.url);
              const reqH = buildHeadersSection('Request Headers', chosen.requestHeaders);
              const resH = buildHeadersSection('Response Headers', chosen.responseHeaders);
              if (qp) detail.appendChild(qp);
              if (reqH) detail.appendChild(reqH);
              if (resH) detail.appendChild(resH);
              if (chosen.requestBody) {
                detail.appendChild(buildPayloadViewer(chosen.requestBody, 'apiReqBodyMode', 'apiReqSearch', 'Request Payload', renderNetworkResults));
              }
              if (chosen.responseBody) {
                detail.appendChild(buildPayloadViewer(chosen.responseBody, 'apiResBodyMode', 'apiResSearch', 'Response Payload', renderNetworkResults));
              }
              resultsHost.appendChild(detail);
            }
          };

          body.appendChild(el('input', {
            type: 'search',
            class: 'search-input',
            style: 'margin-bottom:10px',
            value: state.netSearch,
            placeholder: 'Filter requests by URL or method…',
            'aria-label': 'Filter network requests',
            onInput: (e) => { state.netSearch = e.target.value; renderNetworkResults(); }
          }));
          renderNetworkResults();
          body.appendChild(resultsHost);
        }

        els.networkContent.appendChild(el('div', { class: 'card' }, [
          el('div', { class: 'card-head' }, [
            el('span', { class: 'card-title', text: 'HTTP / XHR Network Traffic' }),
            filters
          ]),
          body
        ]));
      }

      function updateToolbarState() {
        const total = STEPS.length;
        const atStart = total === 0 || state.activeIndex <= 0;
        const atEnd = total === 0 || state.activeIndex >= total - 1;
        els.btnFirst.setAttribute('aria-disabled', atStart ? 'true' : 'false');
        els.btnPrev.setAttribute('aria-disabled', atStart ? 'true' : 'false');
        els.btnNext.setAttribute('aria-disabled', atEnd ? 'true' : 'false');
        els.btnLast.setAttribute('aria-disabled', atEnd ? 'true' : 'false');
        els.btnPlay.setAttribute('aria-disabled', total <= 1 ? 'true' : 'false');
        els.btnFail.setAttribute('aria-disabled', failureIndices.length === 0 ? 'true' : 'false');
        if (els.scrubber) els.scrubber.value = String(state.activeIndex);
        if (els.counter) els.counter.textContent = total === 0 ? 'Step 0 / 0' : `Step ${state.activeIndex + 1} / ${total}`;
      }

      function selectTab(tabKey) {
        const map = { api: 'tab-api', waterfall: 'tab-waterfall', visual: 'tab-visual', dom: 'tab-dom', network: 'tab-network' };
        const panelMap = { api: 'panel-api', waterfall: 'panel-waterfall', visual: 'panel-visual', dom: 'panel-dom', network: 'panel-network' };
        const targetTab = document.getElementById(map[tabKey]);
        if (!targetTab || targetTab.hidden) return;
        state.activeTab = tabKey;

        for (const tab of els.tabs) {
          const active = tab.id === map[tabKey];
          tab.setAttribute('aria-selected', active ? 'true' : 'false');
          tab.toggleAttribute('focusgroupstart', active);
          if (!('focusGroup' in HTMLElement.prototype)) {
            tab.tabIndex = active ? 0 : -1;
          }
        }
        for (const panel of els.panels) {
          const active = panel.id === panelMap[tabKey];
          panel.hidden = !active;
          if (active) {
            panel.tabIndex = 0;
          } else {
            panel.removeAttribute('tabindex');
          }
        }
      }

      function selectStep(index, scrollIntoView = true) {
        if (STEPS.length === 0) {
          renderTimeline();
          renderHero(null);
          updateToolbarState();
          return;
        }
        const clamped = Math.max(0, Math.min(STEPS.length - 1, index));
        state.activeIndex = clamped;
        state.selectedNetId = null;
        state.selectedApiExId = null;
        state.liveReplayResult = null;
        const step = STEPS[clamped];

        // In hybrid (mixed Web + API) reports, automatically adapt the active tab when switching scenarios
        if (REPORT_MODE === 'hybrid' && step.scenarioIndex !== state.lastScenarioIndex) {
          state.lastScenarioIndex = step.scenarioIndex;
          if (step.scenarioKind === 'api' && (state.activeTab === 'visual' || state.activeTab === 'dom')) {
            selectTab('api');
          } else if (step.scenarioKind === 'web' && (state.activeTab === 'api' || state.activeTab === 'waterfall')) {
            selectTab('visual');
          }
        } else {
          state.lastScenarioIndex = step.scenarioIndex;
        }

        renderTicks();
        renderTimeline();
        renderHero(step);
        if (HAS_ANY_API) {
          renderApiExchange(step);
          renderWaterfallAndDiff(step);
        }
        renderVisualAndConsole(step);
        renderDOM(step);
        renderNetwork(step);
        updateToolbarState();

        const consoleCount = (step.consoleEntries || []).length;
        const netCount = (step.networkRequests || []).length;
        const { exchanges } = resolveStepExchanges(step);
        if (els.badgeApi) els.badgeApi.textContent = exchanges.length > 0 ? String(exchanges.length) : (step.assertion ? '✓' : '');
        if (els.badgeWaterfall) els.badgeWaterfall.textContent = ALL_EXCHANGES.length > 0 ? String(ALL_EXCHANGES.length) : '';
        els.badgeVisual.textContent = consoleCount > 0 ? String(consoleCount) : '';
        els.badgeDom.textContent = step.domAssetId ? (step.matchedCount ? `${step.matchedCount}` : '1') : '';
        els.badgeNetwork.textContent = netCount > 0 ? String(netCount) : '';

        if (scrollIntoView) {
          const itemEl = document.getElementById(`timeline-step-${clamped}`);
          if (itemEl) itemEl.scrollIntoView({ block: 'nearest', inline: 'nearest' });
        }
      }

      function stopPlayback() {
        state.playing = false;
        if (state.playTimer) {
          clearInterval(state.playTimer);
          state.playTimer = null;
        }
        els.btnPlay.setAttribute('aria-pressed', 'false');
        els.btnPlay.textContent = '▶ Play';
      }

      function togglePlayback() {
        if (STEPS.length <= 1) return;
        if (state.playing) {
          stopPlayback();
          return;
        }
        if (state.activeIndex >= STEPS.length - 1) selectStep(0);
        state.playing = true;
        els.btnPlay.setAttribute('aria-pressed', 'true');
        els.btnPlay.textContent = '⏸ Pause';
        const delay = Number(els.speed ? els.speed.value : 700) || 700;
        state.playTimer = setInterval(() => {
          if (state.activeIndex >= STEPS.length - 1) {
            stopPlayback();
          } else {
            selectStep(state.activeIndex + 1);
          }
        }, delay);
      }

      function jumpToFailure() {
        if (!failureIndices.length) return;
        stopPlayback();
        const next = failureIndices.find((idx) => idx > state.activeIndex);
        const target = next != null ? next : failureIndices[0];
        selectStep(target);
        announce(`Jumped to failed step ${target + 1}`);
      }

      const guard = (btn, fn) => btn.addEventListener('click', () => {
        if (btn.getAttribute('aria-disabled') === 'true') return;
        fn();
      });
      guard(els.btnFirst, () => { stopPlayback(); selectStep(0); });
      guard(els.btnPrev, () => { stopPlayback(); selectStep(state.activeIndex - 1); });
      guard(els.btnPlay, () => togglePlayback());
      guard(els.btnNext, () => { stopPlayback(); selectStep(state.activeIndex + 1); });
      guard(els.btnLast, () => { stopPlayback(); selectStep(STEPS.length - 1); });
      guard(els.btnFail, () => jumpToFailure());

      if (els.scrubber) {
        els.scrubber.addEventListener('input', (e) => {
          stopPlayback();
          selectStep(Number(e.target.value));
        });
      }
      if (els.speed) {
        els.speed.addEventListener('change', () => {
          if (state.playing) {
            stopPlayback();
            togglePlayback();
          }
        });
      }

      document.querySelectorAll('.timeline-pane [data-filter]').forEach((chip) => {
        chip.addEventListener('click', () => {
          state.statusFilter = chip.getAttribute('data-filter') || 'all';
          document.querySelectorAll('.timeline-pane [data-filter]').forEach((c) => {
            c.setAttribute('aria-pressed', c === chip ? 'true' : 'false');
          });
          renderTimeline();
        });
      });
      if (els.search) {
        els.search.addEventListener('input', (e) => {
          state.searchQuery = e.target.value || '';
          renderTimeline();
        });
      }

      const tabKeys = {
        'tab-api': 'api',
        'tab-waterfall': 'waterfall',
        'tab-visual': 'visual',
        'tab-dom': 'dom',
        'tab-network': 'network'
      };
      const panelKeys = {
        'panel-api': 'api',
        'panel-waterfall': 'waterfall',
        'panel-visual': 'visual',
        'panel-dom': 'dom',
        'panel-network': 'network'
      };
      els.tabs.forEach((tab) => {
        tab.addEventListener('click', () => selectTab(tabKeys[tab.id]));
        tab.addEventListener('focus', () => selectTab(tabKeys[tab.id]));
      });
      els.panels.forEach((panel) => {
        panel.addEventListener('beforematch', () => selectTab(panelKeys[panel.id]));
      });

      if (!('focusGroup' in HTMLElement.prototype)) {
        const wireRoving = (container, selector, wrap) => {
          if (!container) return;
          const items = Array.from(container.querySelectorAll(selector)).filter((b) => !b.hidden);
          if (!items.length) return;
          items.forEach((b, i) => { b.tabIndex = i === 0 ? 0 : -1; });
          container.addEventListener('focusin', ({ target }) => {
            if (items.includes(target)) items.forEach((b) => { b.tabIndex = b === target ? 0 : -1; });
          });
          container.addEventListener('keydown', (e) => {
            const idx = items.indexOf(document.activeElement);
            if (idx === -1) return;
            const rtl = getComputedStyle(container).direction === 'rtl';
            const delta = e.key === 'ArrowRight' ? (rtl ? -1 : 1) : e.key === 'ArrowLeft' ? (rtl ? 1 : -1) : 0;
            let nextIdx = -1;
            if (delta !== 0) {
              nextIdx = wrap ? (idx + delta + items.length) % items.length : Math.max(0, Math.min(items.length - 1, idx + delta));
            } else if (e.key === 'Home') {
              nextIdx = 0;
            } else if (e.key === 'End') {
              nextIdx = items.length - 1;
            }
            if (nextIdx >= 0 && nextIdx !== idx) {
              e.preventDefault();
              items[nextIdx].focus();
            }
          });
        };
        wireRoving(document.querySelector('[role="toolbar"]'), 'button', true);
        wireRoving(document.querySelector('[role="tablist"]'), '[role="tab"]', true);
      }

      document.addEventListener('keydown', (e) => {
        const tag = (e.target && e.target.tagName) ? e.target.tagName.toLowerCase() : '';
        if (tag === 'input' || tag === 'textarea' || tag === 'select' || (e.target && e.target.isContentEditable)) return;
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        const inToolbarOrTabs = e.target && e.target.closest && (e.target.closest('[role="toolbar"]') || e.target.closest('[role="tablist"]'));

        if ((e.key === 'ArrowLeft' && !inToolbarOrTabs) || e.key === 'ArrowUp') {
          e.preventDefault();
          stopPlayback();
          selectStep(state.activeIndex - 1);
        } else if ((e.key === 'ArrowRight' && !inToolbarOrTabs) || e.key === 'ArrowDown') {
          e.preventDefault();
          stopPlayback();
          selectStep(state.activeIndex + 1);
        } else if (e.key === 'Home' && !inToolbarOrTabs) {
          e.preventDefault();
          stopPlayback();
          selectStep(0);
        } else if (e.key === 'End' && !inToolbarOrTabs) {
          e.preventDefault();
          stopPlayback();
          selectStep(STEPS.length - 1);
        } else if (e.key === 'f' || e.key === 'F') {
          if (failureIndices.length) {
            e.preventDefault();
            jumpToFailure();
          }
        } else if (e.key === ' ' && !inToolbarOrTabs && tag !== 'button') {
          e.preventDefault();
          togglePlayback();
        } else if (['1', '2', '3', '4', '5'].includes(e.key)) {
          const visibleTabs = els.tabs.filter((t) => !t.hidden);
          const pick = visibleTabs[Number(e.key) - 1];
          if (pick) selectTab(tabKeys[pick.id]);
        }
      });

      if (els.lightboxClose && els.lightbox) {
        els.lightboxClose.addEventListener('click', () => els.lightbox.close());
        els.lightbox.addEventListener('click', (e) => {
          if (e.target === els.lightbox) els.lightbox.close();
        });
      }

      // Initial render: pick the right tab for the initial step's scenario kind
      const firstApiStepIdx = ALL_EXCHANGES.length > 0 ? ALL_EXCHANGES[0].stepIndex : 0;
      const initialIdx = failureIndices.length > 0
        ? failureIndices[0]
        : (REPORT_MODE === 'api' ? firstApiStepIdx : 0);
      const initialStep = STEPS[initialIdx];
      const initialTab = (REPORT_MODE === 'api' || (REPORT_MODE === 'hybrid' && initialStep && initialStep.scenarioKind === 'api'))
        ? 'api'
        : 'visual';
      selectTab(initialTab);
      selectStep(initialIdx, false);
    })();
    """#
}
