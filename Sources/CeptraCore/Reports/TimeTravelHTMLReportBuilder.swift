import CryptoKit
import Foundation

/// Builds a 100% self-contained, offline-capable interactive HTML test report with
/// step-by-step execution timeline, time-travel playback controls, keyboard navigation,
/// DOM snapshot inspector (with target highlighting and sandboxed preview),
/// per-step network traffic inspector, before/after visual diff, and browser console logs.
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
        let overallStatus: String
        let passRatePct: Int
        let passedCount: Int
        let failedCount: Int
        let skippedCount: Int
        let durationMs: Int
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
        let networkRequests: [TimeTravelNetworkEntry]
        let consoleEntries: [TimeTravelConsoleEntry]
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
                durationMs: sc.durationMs,
                tags: sc.tags,
                errorMessage: sc.errorMessage,
                errorStack: sc.errorStack,
                firstStepIndex: firstIdx,
                stepCount: max(1, sc.steps.count)
            ))
        }

        let passPct = Int((report.passRate * 100.0).rounded())
        let payload = EmbeddedPayload(
            meta: ReportMeta(
                projectName: report.projectName,
                label: report.label,
                commandLine: report.commandLine,
                overallStatus: report.overallStatus.rawValue,
                passRatePct: passPct,
                passedCount: report.passedCount,
                failedCount: report.failedCount,
                skippedCount: report.skippedCount,
                durationMs: report.durationMs,
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

        let failureStepCount = timelineSteps.filter { $0.status == "failed" }.count

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Ceptra Time-Travel Report — \(escapeHTML(report.projectName))</title>
        <style>
        \(cssSource)
        </style>
        </head>
        <body>
          <div class="app-shell">
            <header class="topbar">
              <div class="topbar-main">
                <div class="brand-row">
                  <span class="status-pill \(statusClass)">\(escapeHTML(report.overallStatus.rawValue.uppercased()))</span>
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
                  </div>
                  <input type="search" id="timeline-search" class="search-input" placeholder="Filter steps, scenarios, selectors…" aria-label="Filter execution timeline" />
                </div>
                <div id="timeline-list" class="timeline-list" role="listbox" aria-label="Test execution steps"></div>
              </aside>

              <section class="inspector-pane" aria-label="Per-step diagnostic inspector">
                <div id="step-hero" class="step-hero"></div>

                <div class="tabs-shell">
                  <div class="tablist" focusgroup="tablist nomemory" role="tablist" aria-label="Diagnostic inspection panels">
                    <button type="button" role="tab" id="tab-visual" aria-selected="true" focusgroupstart>Visual &amp; Console <span class="tab-badge" id="badge-visual"></span></button>
                    <button type="button" role="tab" id="tab-dom" aria-selected="false">DOM Snapshot <span class="tab-badge" id="badge-dom"></span></button>
                    <button type="button" role="tab" id="tab-network" aria-selected="false">Network <span class="tab-badge" id="badge-network"></span></button>
                  </div>

                  <div class="tabpanels">
                    <div role="tabpanel" id="panel-visual" aria-labelledby="tab-visual" tabindex="0">
                      <div class="panel-inner" id="visual-content"></div>
                    </div>
                    <div role="tabpanel" id="panel-dom" aria-labelledby="tab-dom" hidden="until-found">
                      <div class="panel-inner" id="dom-content"></div>
                    </div>
                    <div role="tabpanel" id="panel-network" aria-labelledby="tab-network" hidden="until-found">
                      <div class="panel-inner" id="network-content"></div>
                    </div>
                  </div>
                </div>
              </section>
            </main>
          </div>

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
    .brand-row { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
    .brand-row h1 { margin: 0; font-size: 16px; font-weight: 700; letter-spacing: -0.01em; }
    .brand-row .sep { color: var(--muted); font-weight: 400; }
    .brand-row .run-label { color: var(--text-2); font-weight: 500; }
    .cmd-line { margin-top: 4px; color: var(--muted); font-size: 11.5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 680px; }
    .cmd-line code { font-family: var(--mono); }

    .status-pill { display: inline-flex; align-items: center; font-size: 10.5px; font-weight: 700; letter-spacing: 0.05em; padding: 3px 8px; border-radius: 999px; border: 1px solid transparent; }
    .status-pill.pass { background: var(--pass-soft); color: var(--pass); border-color: rgba(52, 211, 153, 0.35); }
    .status-pill.fail { background: var(--fail-soft); color: var(--fail); border-color: rgba(248, 113, 113, 0.4); }
    .status-pill.skip { background: var(--warn-soft); color: var(--warn); border-color: rgba(251, 191, 36, 0.35); }

    .kpi-strip { display: flex; flex-wrap: wrap; gap: 8px; }
    .kpi { background: var(--surface-2); border: 1px solid var(--border); border-radius: 8px; padding: 6px 11px; min-width: 72px; }
    .kpi-label { display: block; font-size: 9.5px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); }
    .kpi-val { display: block; font-size: 16px; font-weight: 700; font-variant-numeric: tabular-nums; margin-top: 1px; }
    .kpi-val.pass { color: var(--pass); }
    .kpi-val.fail { color: var(--fail); }
    .kpi-val.skip { color: var(--warn); }
    .kpi-val.accent { color: var(--accent); }

    .playback-bar { position: sticky; top: 0; z-index: 20; display: flex; flex-wrap: wrap; align-items: center; gap: 12px; padding: 9px 20px; background: rgba(19, 23, 34, 0.94); backdrop-filter: blur(12px); border-bottom: 1px solid var(--border); }
    .toolbar { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
    .tb-group { display: inline-flex; align-items: center; gap: 4px; }
    .tb-sep { display: inline-block; width: 0; height: 20px; border-inline-start: 1px solid var(--border-strong); margin: 0 2px; }
    .tb-btn { min-inline-size: 30px; min-block-size: 28px; padding: 4px 10px; border-radius: 7px; border: 1px solid var(--border); background: var(--surface-2); color: var(--text); font-size: 12px; font-weight: 500; cursor: pointer; display: inline-flex; align-items: center; justify-content: center; gap: 5px; }
    @media (hover: hover) { .tb-btn:hover:not([aria-disabled="true"]) { background: var(--surface-3); border-color: var(--border-strong); } }
    .tb-btn[aria-pressed="true"] { background: var(--accent-soft); border-color: var(--accent); color: #dbeafe; }
    .tb-btn[aria-disabled="true"] { opacity: 0.42; cursor: not-allowed; }
    .tb-btn.fail-jump:not([aria-disabled="true"]) { background: var(--fail-soft); border-color: rgba(248, 113, 113, 0.45); color: #fecaca; }
    @media (prefers-reduced-motion: no-preference) { .tb-btn, .chip, .step-item { transition: background-color 120ms ease, border-color 120ms ease; } }

    .scrubber-wrap { flex: 1 1 220px; min-width: 160px; display: flex; flex-direction: column; gap: 3px; }
    .scrubber-ticks { display: flex; gap: 2px; height: 6px; width: 100%; }
    .scrubber-tick { flex: 1 1 0; border-radius: 2px; background: var(--border); cursor: pointer; min-width: 2px; }
    .scrubber-tick.pass { background: rgba(52, 211, 153, 0.55); }
    .scrubber-tick.fail { background: var(--fail); }
    .scrubber-tick.skip { background: var(--warn); }
    .scrubber-tick.active { outline: 1.5px solid #fff; transform: scaleY(1.35); }
    #step-scrubber { width: 100%; accent-color: var(--accent); margin: 0; cursor: pointer; }

    .playback-meta { display: flex; align-items: center; gap: 8px; }
    .counter { font-size: 12px; color: var(--text-2); min-width: 82px; text-align: right; }
    #playback-speed { background: var(--surface-2); color: var(--text); border: 1px solid var(--border); border-radius: 6px; padding: 3px 6px; font-size: 11.5px; }

    .workbench { flex: 1; display: grid; grid-template-columns: minmax(300px, 380px) minmax(0, 1fr); min-height: 0; }
    @media (max-width: 920px) { .workbench { grid-template-columns: 1fr; } .timeline-pane { max-height: 320px; border-right: none; border-bottom: 1px solid var(--border); } }

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
    .step-row-meta { display: flex; align-items: center; gap: 6px; padding-left: 31px; font-size: 10px; color: var(--muted); flex-wrap: wrap; }
    .dur-bar { flex: 1; min-width: 30px; max-width: 72px; height: 3px; background: var(--surface-3); border-radius: 2px; overflow: hidden; }
    .dur-fill { height: 100%; background: var(--accent); }
    .step-item.fail .dur-fill { background: var(--fail); }
    .mini-tag { padding: 1px 5px; border-radius: 4px; background: var(--surface-3); color: var(--text-2); font-family: var(--mono); font-size: 9.5px; }
    .mini-tag.err { background: var(--fail-soft); color: var(--fail); }

    .inspector-pane { display: flex; flex-direction: column; min-width: 0; padding: 16px 20px 28px; gap: 14px; }
    .step-hero { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 14px 16px; display: flex; flex-direction: column; gap: 8px; }
    .hero-top { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
    .hero-breadcrumb { font-size: 11px; color: var(--muted); margin-bottom: 3px; }
    .hero-title { font-family: var(--mono); font-size: 14px; font-weight: 600; color: var(--text); word-break: break-word; }
    .hero-chips { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
    .meta-pill { font-size: 11px; padding: 2px 8px; border-radius: 6px; background: var(--surface-2); border: 1px solid var(--border); color: var(--text-2); }
    .meta-pill.target { background: var(--target-soft); border-color: rgba(245, 158, 11, 0.45); color: #fde68a; }
    .error-banner { background: var(--fail-soft); border: 1px solid rgba(248, 113, 113, 0.42); border-radius: 8px; padding: 10px 12px; color: #fecaca; font-family: var(--mono); font-size: 11.5px; white-space: pre-wrap; overflow-x: auto; }

    .tabs-shell { display: flex; flex-direction: column; min-width: 0; }
    .tablist { display: flex; overflow-x: auto; border-bottom: 1px solid var(--border); gap: 2px; scrollbar-width: none; }
    .tablist [role="tab"] { position: relative; flex: none; min-block-size: 36px; padding: 8px 14px; border: none; background: transparent; color: var(--text-2); font-size: 12.5px; font-weight: 500; cursor: pointer; display: inline-flex; align-items: center; gap: 6px; }
    .tablist [role="tab"][aria-selected="true"] { color: var(--text); }
    .tablist [role="tab"][aria-selected="true"]::after { content: ""; position: absolute; inset: auto 8px 0; border-block-end: 2.5px solid var(--accent); }
    .tab-badge { font-family: var(--mono); font-size: 10.5px; padding: 1px 6px; border-radius: 999px; background: var(--surface-2); color: var(--text-2); }
    .tab-badge:empty { display: none; }

    .tabpanels { display: grid; }
    .tabpanels > [role="tabpanel"] { grid-area: 1 / 1; min-width: 0; }
    .panel-inner { padding-top: 14px; display: flex; flex-direction: column; gap: 14px; min-width: 0; }

    .card { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); overflow: hidden; }
    .card-head { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px; padding: 10px 14px; background: var(--surface-2); border-bottom: 1px solid var(--border); }
    .card-title { font-size: 11.5px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.06em; color: var(--text-2); }
    .card-body { padding: 14px; }

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
    .method-badge { font-family: var(--mono); font-size: 10.5px; font-weight: 700; padding: 2px 6px; border-radius: 4px; background: var(--surface-3); color: #bfdbfe; }
    .status-code { font-family: var(--mono); font-size: 11px; font-weight: 700; padding: 2px 6px; border-radius: 4px; }
    .status-code.s2 { background: var(--pass-soft); color: var(--pass); }
    .status-code.s3 { background: var(--accent-soft); color: var(--accent); }
    .status-code.s4 { background: var(--warn-soft); color: var(--warn); }
    .status-code.s5, .status-code.serr { background: var(--fail-soft); color: var(--fail); }
    .net-url { font-family: var(--mono); font-size: 11.5px; max-width: 420px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .net-detail { margin-top: 12px; background: var(--bg); border: 1px solid var(--border); border-radius: 8px; padding: 12px; display: flex; flex-direction: column; gap: 10px; }
    .kv-grid { display: grid; grid-template-columns: minmax(140px, 220px) minmax(0, 1fr); gap: 4px 12px; font-family: var(--mono); font-size: 11px; }
    .kv-k { color: #93c5fd; word-break: break-word; }
    .kv-v { color: var(--text-2); word-break: break-all; }
    .code-box { font-family: var(--mono); font-size: 11.5px; background: var(--surface); border: 1px solid var(--border); border-radius: 6px; padding: 10px; margin: 0; max-height: 280px; overflow: auto; white-space: pre-wrap; word-break: break-word; }

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
      const STEPS = Array.isArray(REPORT.steps) ? REPORT.steps : [];
      const ASSETS = REPORT.assets || {};

      const state = {
        activeIndex: 0,
        statusFilter: 'all',
        searchQuery: '',
        activeTab: 'visual',
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
        badgeVisual: document.getElementById('badge-visual'),
        badgeDom: document.getElementById('badge-dom'),
        badgeNetwork: document.getElementById('badge-network'),
        visualContent: document.getElementById('visual-content'),
        domContent: document.getElementById('dom-content'),
        networkContent: document.getElementById('network-content'),
        lightbox: document.getElementById('shot-lightbox'),
        lightboxTitle: document.getElementById('lightbox-title'),
        lightboxImg: document.getElementById('lightbox-img'),
        lightboxClose: document.getElementById('lightbox-close')
      };

      function announce(msg) {
        if (els.liveStatus) els.liveStatus.textContent = msg;
      }

      function fmtDur(ms) {
        if (ms == null) return '—';
        if (ms < 1000) return `${ms}ms`;
        const s = ms / 1000;
        return s < 60 ? `${s.toFixed(2)}s` : `${Math.floor(s / 60)}m ${(s % 60).toFixed(1)}s`;
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

      async function copyText(text, label) {
        try {
          await navigator.clipboard.writeText(text);
          announce(`${label} copied`);
        } catch {
          announce(`Copy failed for ${label}`);
        }
      }

      // Safely parse captured HTML into an inert offscreen document via DOMParser for attribute-complete
      // DOM tree inspection (never inserted into host DOM). Sandboxed preview strips unsafe scripts/handlers.
      function parseCapturedHTML(rawHTML) {
        if (!rawHTML) return null;
        try {
          return new DOMParser().parseFromString(rawHTML, 'text/html');
        } catch {
          return null;
        }
      }

      function filteredSteps() {
        const q = state.searchQuery.trim().toLowerCase();
        return STEPS.filter((s) => {
          if (state.statusFilter !== 'all' && s.status !== state.statusFilter) return false;
          if (!q) return true;
          return (
            (s.text || '').toLowerCase().includes(q) ||
            (s.scenarioTitle || '').toLowerCase().includes(q) ||
            (s.featureTitle || '').toLowerCase().includes(q) ||
            (s.targetSelector || '').toLowerCase().includes(q) ||
            (s.pageURL || '').toLowerCase().includes(q)
          );
        });
      }

      function renderTicks() {
        els.ticks.replaceChildren();
        STEPS.forEach((s, idx) => {
          const t = el('div', {
            class: `scrubber-tick ${statusCls(s.status)}${idx === state.activeIndex ? ' active' : ''}`,
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
            const head = el('div', { class: 'scenario-divider' }, [
              el('div', { style: 'min-width:0;flex:1' }, [
                el('span', { class: 'sc-feat', text: step.featureTitle }),
                el('span', { class: 'sc-name', text: step.scenarioTitle })
              ]),
              el('span', { class: `status-pill ${statusCls(step.scenarioStatus)}`, text: step.scenarioStatus.toUpperCase() })
            ]);
            els.timelineList.appendChild(head);
          }

          const isSelected = step.globalIndex === state.activeIndex;
          const durPct = Math.min(100, Math.max(4, Math.round(((step.durationMs || 0) / maxStepDur) * 100)));
          const errLogs = (step.consoleEntries || []).filter((c) => c.level === 'error' || c.level === 'pageerror').length;
          const netCount = (step.networkRequests || []).length;
          const hasShot = Boolean(step.beforeShotAssetId || step.afterShotAssetId);
          const hasDom = Boolean(step.domAssetId);

          const metaRow = el('div', { class: 'step-row-meta' }, [
            el('span', { class: 'mono', text: fmtOffset(step.relativeOffsetMs) }),
            el('div', { class: 'dur-bar' }, [el('div', { class: 'dur-fill', style: `width:${durPct}%` })])
          ]);
          if (netCount > 0) metaRow.appendChild(el('span', { class: 'mini-tag', text: `NET ${netCount}` }));
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

        // 1. Visual Diff Card
        const modeGroup = el('div', { class: 'tb-group', role: 'group', 'aria-label': 'Screenshot view mode' });
        const modes = [
          ['side', 'Side-by-Side'],
          ['before', 'Before'],
          ['after', 'After'],
          ['curtain', 'Curtain Diff']
        ];
        for (const [m, lbl] of modes) {
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

        // 2. Browser Console & Uncaught Errors Card
        const entries = step.consoleEntries || [];
        const counts = {
          all: entries.length,
          errors: entries.filter((c) => c.level === 'error' || c.level === 'pageerror').length,
          warnings: entries.filter((c) => c.level === 'warn').length,
          logs: entries.filter((c) => c.level === 'log' || c.level === 'info' || c.level === 'debug').length
        };

        const consoleFilters = el('div', { class: 'tb-group', role: 'group', 'aria-label': 'Filter browser console' });
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
            const treeHost = el('div', { class: 'dom-tree' });
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

      function prettyBody(raw) {
        if (!raw) return '';
        try { return JSON.stringify(JSON.parse(raw), null, 2); } catch { return raw; }
      }

      function statusBucket(req) {
        if (req.errorText || req.status == null) return 'serr';
        if (req.status >= 500) return 's5';
        if (req.status >= 400) return 's4';
        if (req.status >= 300) return 's3';
        return 's2';
      }

      function renderNetwork(step) {
        els.networkContent.replaceChildren();
        if (!step) return;

        const allReqs = step.networkRequests || [];
        const filters = el('div', { class: 'tb-group', role: 'group', 'aria-label': 'Filter network requests' });
        for (const [k, lbl] of [['all', `All (${allReqs.length})`], ['xhr', 'XHR / Fetch'], ['errors', 'Errors (4xx/5xx)']]) {
          filters.appendChild(el('button', {
            type: 'button',
            class: 'chip',
            'aria-pressed': state.netFilter === k ? 'true' : 'false',
            onClick: () => { state.netFilter = k; renderNetwork(step); }
          }, lbl));
        }

        const filtered = allReqs.filter((r) => {
          if (state.netFilter === 'xhr' && r.resourceType !== 'fetch' && r.resourceType !== 'xhr') return false;
          if (state.netFilter === 'errors' && !r.errorText && (r.status == null || r.status < 400)) return false;
          const q = state.netSearch.trim().toLowerCase();
          if (q && !(r.url || '').toLowerCase().includes(q) && !(r.method || '').toLowerCase().includes(q)) return false;
          return true;
        });

        const body = el('div', { class: 'card-body' });
        if (allReqs.length === 0) {
          body.appendChild(el('div', { class: 'empty-state', text: 'No HTTP/XHR network traffic was triggered during this step.' }));
        } else {
          body.appendChild(el('input', {
            type: 'search',
            class: 'search-input',
            style: 'margin-bottom:10px',
            value: state.netSearch,
            placeholder: 'Filter requests by URL or method…',
            'aria-label': 'Filter network requests',
            onInput: (e) => { state.netSearch = e.target.value; renderNetwork(step); }
          }));

          if (filtered.length === 0) {
            body.appendChild(el('div', { class: 'empty-state', text: 'No requests match this filter.' }));
          } else {
            if (!filtered.some((r) => r.id === state.selectedNetId)) {
              state.selectedNetId = filtered[0].id;
            }
            const tbody = el('tbody');
            for (const req of filtered) {
              const sel = req.id === state.selectedNetId;
              const statusLabel = req.errorText ? 'FAILED' : (req.status != null ? String(req.status) : '…');
              tbody.appendChild(el('tr', {
                class: `net-row${sel ? ' selected' : ''}`,
                onClick: () => { state.selectedNetId = req.id; renderNetwork(step); }
              }, [
                el('td', null, el('span', { class: 'method-badge', text: req.method || 'GET' })),
                el('td', null, el('span', { class: `status-code ${statusBucket(req)}`, text: statusLabel })),
                el('td', { class: 'net-url', text: req.url, title: req.url }),
                el('td', { class: 'mono', text: req.resourceType || '—' }),
                el('td', { class: 'mono', text: fmtDur(req.durationMs) })
              ]));
            }

            body.appendChild(el('div', { class: 'net-table-wrap' }, [
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
                el('button', {
                  type: 'button',
                  class: 'tb-btn',
                  text: 'Copy URL',
                  onClick: () => copyText(chosen.url, 'Request URL')
                })
              ]));
              if (chosen.errorText) {
                detail.appendChild(el('div', { class: 'error-banner', text: chosen.errorText }));
              }
              const renderHeaders = (title, hdrs) => {
                const keys = Object.keys(hdrs || {}).sort();
                if (!keys.length) return null;
                const grid = el('div', { class: 'kv-grid' });
                for (const k of keys) {
                  grid.appendChild(el('span', { class: 'kv-k', text: k }));
                  grid.appendChild(el('span', { class: 'kv-v', text: hdrs[k] }));
                }
                return el('div', null, [
                  el('div', { class: 'card-title', style: 'margin-bottom:6px', text: `${title} (${keys.length})` }),
                  grid
                ]);
              };
              const reqH = renderHeaders('Request Headers', chosen.requestHeaders);
              const resH = renderHeaders('Response Headers', chosen.responseHeaders);
              if (reqH) detail.appendChild(reqH);
              if (resH) detail.appendChild(resH);
              if (chosen.requestBody) {
                detail.appendChild(el('div', null, [
                  el('div', { class: 'card-title', style: 'margin-bottom:6px', text: 'Request Payload' }),
                  el('pre', { class: 'code-box', text: prettyBody(chosen.requestBody) })
                ]));
              }
              if (chosen.responseBody) {
                detail.appendChild(el('div', null, [
                  el('div', { style: 'display:flex;justify-content:space-between;align-items:center;margin-bottom:6px' }, [
                    el('span', { class: 'card-title', text: 'Response Payload' }),
                    el('button', { type: 'button', class: 'tb-btn', text: 'Copy Response', onClick: () => copyText(chosen.responseBody, 'Response payload') })
                  ]),
                  el('pre', { class: 'code-box', text: prettyBody(chosen.responseBody) })
                ]));
              }
              body.appendChild(detail);
            }
          }
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
        state.activeTab = tabKey;
        const map = { visual: 'tab-visual', dom: 'tab-dom', network: 'tab-network' };
        const panelMap = { visual: 'panel-visual', dom: 'panel-dom', network: 'panel-network' };
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
          if (active) {
            panel.removeAttribute('hidden');
            panel.tabIndex = 0;
          } else {
            panel.setAttribute('hidden', 'until-found');
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
        const step = STEPS[clamped];

        renderTicks();
        renderTimeline();
        renderHero(step);
        renderVisualAndConsole(step);
        renderDOM(step);
        renderNetwork(step);
        updateToolbarState();

        const consoleCount = (step.consoleEntries || []).length;
        const netCount = (step.networkRequests || []).length;
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

      // Wire playback controls (respecting aria-disabled="true")
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

      // Filter chips & search
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

      // Tabs + beforematch find-in-page reveal
      const tabKeys = { 'tab-visual': 'visual', 'tab-dom': 'dom', 'tab-network': 'network' };
      const panelKeys = { 'panel-visual': 'visual', 'panel-dom': 'dom', 'panel-network': 'network' };
      els.tabs.forEach((tab) => {
        tab.addEventListener('click', () => selectTab(tabKeys[tab.id]));
        tab.addEventListener('focus', () => selectTab(tabKeys[tab.id]));
      });
      els.panels.forEach((panel) => {
        panel.addEventListener('beforematch', () => selectTab(panelKeys[panel.id]));
      });

      // Fallback roving tabindex for toolbar & tablist ONLY when native focusgroup is unsupported
      if (!('focusGroup' in HTMLElement.prototype)) {
        const wireRoving = (container, selector, wrap) => {
          if (!container) return;
          const items = Array.from(container.querySelectorAll(selector));
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

      // Global time-travel keyboard navigation (ignored when typing or inside composite toolbar/tablist)
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
        } else if (e.key === '1') {
          selectTab('visual');
        } else if (e.key === '2') {
          selectTab('dom');
        } else if (e.key === '3') {
          selectTab('network');
        }
      });

      if (els.lightboxClose && els.lightbox) {
        els.lightboxClose.addEventListener('click', () => els.lightbox.close());
        els.lightbox.addEventListener('click', (e) => {
          if (e.target === els.lightbox) els.lightbox.close();
        });
      }

      // Initial render: focus first failed step if present, else step 0
      selectTab('visual');
      selectStep(failureIndices.length > 0 ? failureIndices[0] : 0, false);
    })();
    """#
}
