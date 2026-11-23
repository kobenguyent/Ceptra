import AppKit
import CeptraCore
import SwiftUI

struct ReplayInspectorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedScenarioIndex: Int = 0
    @State private var selectedStepIndex: Int = 0
    @State private var detailTab: ReplayDetailTab = .visual
    @State private var isPlaying: Bool = false
    @State private var playTask: Task<Void, Never>? = nil

    enum ReplayDetailTab: String, CaseIterable, Identifiable {
        case visual = "Visual"
        case dom = "DOM"
        case network = "Network"
        case console = "Console"
        var id: String { rawValue }
    }

    private var scenarios: [ExecutedScenarioRecord] {
        if let bundle = appState.activeReplayTraceBundle, !bundle.scenarios.isEmpty {
            return bundle.scenarios
        }
        if let report = appState.selectedReport, !report.scenarios.isEmpty {
            return report.scenarios
        }
        if !appState.liveReplaySteps.isEmpty {
            return [
                ExecutedScenarioRecord(
                    featureTitle: appState.activeRunLabel.isEmpty ? "Live Run" : appState.activeRunLabel,
                    scenarioTitle: appState.isRunning ? "Streaming Steps…" : "Latest Run",
                    status: appState.isRunning ? .running : .passed,
                    steps: appState.liveReplaySteps
                )
            ]
        }
        return []
    }

    private var activeScenario: ExecutedScenarioRecord? {
        guard !scenarios.isEmpty else { return nil }
        let idx = min(max(0, selectedScenarioIndex), scenarios.count - 1)
        return scenarios[idx]
    }

    private var activeSteps: [ExecutedStepRecord] {
        if appState.isRunning && !appState.liveReplaySteps.isEmpty {
            return appState.liveReplaySteps
        }
        return activeScenario?.steps ?? []
    }

    private var selectedStep: ExecutedStepRecord? {
        guard !activeSteps.isEmpty else { return nil }
        let idx = min(max(0, selectedStepIndex), activeSteps.count - 1)
        return activeSteps[idx]
    }

    private var firstFailingStepIndex: Int? {
        activeSteps.firstIndex(where: { $0.status == .failed || $0.errorMessage != nil })
    }

    private func isApiOnlyScenario(_ scenario: ExecutedScenarioRecord?) -> Bool {
        guard let scenario else { return false }
        let steps = scenario.steps
        let hasVisuals = steps.contains { $0.diagnostics?.hasWebVisuals == true }
        let hasApi = steps.contains { $0.diagnostics?.hasApiTraffic == true }
        let hasWebSignal = hasVisuals || steps.contains { step in
            if step.diagnostics?.networkRequests.contains(where: { !$0.isApiExchange }) == true { return true }
            if let assertion = step.diagnostics?.assertion, !assertion.isApiAssertion { return true }
            let t = step.text
            return t.hasPrefix("page.") || t.hasPrefix("locator(") || t.hasPrefix("getBy") ||
                t == "Navigate" || t.hasPrefix("Navigate ") ||
                t == "Click" || t.hasPrefix("Click ") ||
                t == "Fill" || t.hasPrefix("Fill ") ||
                t.hasPrefix("I amOnPage") || t.hasPrefix("I click") ||
                t.hasPrefix("I fillField") || t.hasPrefix("I see ")
        }
        return hasApi && !hasWebSignal
    }

    private var isActiveScenarioApiOnly: Bool {
        isApiOnlyScenario(activeScenario)
    }

    private func preferredInitialStepIndex(in steps: [ExecutedStepRecord]) -> Int {
        if let failIdx = steps.firstIndex(where: { $0.status == .failed || $0.errorMessage != nil }) {
            return failIdx
        }
        if isActiveScenarioApiOnly, let apiIdx = steps.firstIndex(where: { $0.diagnostics?.networkRequests.isEmpty == false }) {
            return apiIdx
        }
        return 0
    }

    private func syncDetailTabForActiveScenario() {
        if isActiveScenarioApiOnly {
            if detailTab == .visual || detailTab == .dom {
                detailTab = .network
            }
        } else if detailTab == .network {
            detailTab = .visual
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if scenarios.isEmpty && !appState.isRunning {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if scenarios.count > 1 {
                            scenarioPicker
                        }

                        playbackControlsBar

                        stepTimelineList

                        if let step = selectedStep {
                            detailSubTabs(for: step)
                            detailContentCard(for: step)
                        }

                        if appState.selectedReport != nil {
                            exportActionsBar
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onAppear {
            syncDetailTabForActiveScenario()
            if !activeSteps.isEmpty && selectedStepIndex == 0 {
                selectedStepIndex = preferredInitialStepIndex(in: activeSteps)
            }
        }
        .onChange(of: appState.selectedReportID) { _, _ in
            stopPlayback()
            appState.refreshSelectedReplayTrace()
            selectedScenarioIndex = 0
            selectedStepIndex = preferredInitialStepIndex(in: activeSteps)
            syncDetailTabForActiveScenario()
        }
        .onChange(of: appState.activeReplayTraceBundle?.reportID) { _, _ in
            selectedStepIndex = preferredInitialStepIndex(in: activeSteps)
            syncDetailTabForActiveScenario()
        }
        .onChange(of: selectedScenarioIndex) { _, _ in
            syncDetailTabForActiveScenario()
        }
        .onChange(of: appState.liveReplaySteps.count) { _, newCount in
            if appState.isRunning && newCount > 0 {
                selectedStepIndex = newCount - 1
            }
        }
        .onDisappear {
            stopPlayback()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(CeptraTheme.textMuted)
            Text("No Replay Trace Yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CeptraTheme.textPrimary)
            Text("Click ▶ Run to capture live step-by-step Visual, DOM, Network, and Console snapshots automatically.")
                .font(.system(size: 11.5))
                .foregroundStyle(CeptraTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            Button {
                if appState.isActiveTabExecutableTestFile {
                    appState.runActiveFile()
                } else {
                    appState.run(mode: .runAll)
                }
            } label: {
                Label("Run & Capture Replay", systemImage: "play.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(CeptraTheme.success, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(CeptraTactilePressStyle())
            .disabled(appState.workspace == nil || appState.isRunning)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var scenarioPicker: some View {
        Menu {
            ForEach(Array(scenarios.enumerated()), id: \.element.id) { idx, sc in
                let kindTag = isApiOnlyScenario(sc) ? "API" : "WEB"
                Button {
                    stopPlayback()
                    selectedScenarioIndex = idx
                    selectedStepIndex = preferredInitialStepIndex(in: sc.steps)
                } label: {
                    Label("[\(kindTag)] \(sc.featureTitle) › \(sc.scenarioTitle)", systemImage: CeptraTheme.symbol(for: sc.status))
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let sc = activeScenario {
                    let isApi = isApiOnlyScenario(sc)
                    StatusDotView(status: sc.status, size: 7)
                    Text(isApi ? "API" : "WEB")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(isApi ? CeptraTheme.cyan : CeptraTheme.accent)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1.5)
                        .background(
                            (isApi ? CeptraTheme.cyan : CeptraTheme.accent).opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                    Text("\(sc.featureTitle) › \(sc.scenarioTitle)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(CeptraTheme.textPrimary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textMuted)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var playbackControlsBar: some View {
        HStack(spacing: 5) {
            controlButton(icon: "backward.frame.fill", disabled: selectedStepIndex <= 0) {
                stopPlayback()
                selectStep(max(0, selectedStepIndex - 1))
            }

            controlButton(
                icon: isPlaying ? "pause.fill" : "play.fill",
                tint: CeptraTheme.accent,
                disabled: activeSteps.isEmpty
            ) {
                togglePlayback()
            }

            controlButton(icon: "forward.frame.fill", disabled: selectedStepIndex >= activeSteps.count - 1) {
                stopPlayback()
                selectStep(min(activeSteps.count - 1, selectedStepIndex + 1))
            }

            if let failIdx = firstFailingStepIndex {
                Button {
                    stopPlayback()
                    selectStep(failIdx)
                } label: {
                    Text("Jump Fail")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(CeptraTheme.failure)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(CeptraTheme.failure.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(CeptraTactilePressStyle())
            }

            Spacer(minLength: 4)

            if appState.isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
            }

            Text(activeSteps.isEmpty ? "0 / 0" : "\(min(selectedStepIndex + 1, activeSteps.count)) / \(activeSteps.count)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(CeptraTheme.textMuted)
        }
    }

    private func controlButton(icon: String, tint: Color = CeptraTheme.textSecondary, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(disabled ? CeptraTheme.textMuted.opacity(0.45) : tint)
                .frame(width: 26, height: 22)
                .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
        }
        .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.94))
        .disabled(disabled)
    }

    private var stepTimelineList: some View {
        VStack(spacing: 0) {
            if activeSteps.isEmpty {
                Text(appState.isRunning ? "Waiting for test steps…" : "No steps recorded for this scenario.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                ForEach(Array(activeSteps.enumerated()), id: \.element.id) { idx, step in
                    let isSelected = idx == min(selectedStepIndex, activeSteps.count - 1)
                    let isFailed = step.status == .failed || step.errorMessage != nil
                    Button {
                        stopPlayback()
                        selectStep(idx)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isFailed ? "xmark" : "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(isFailed ? CeptraTheme.failure : CeptraTheme.success)
                                .frame(width: 12)

                            Text(step.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(isSelected ? CeptraTheme.textPrimary : CeptraTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            if let firstReq = step.diagnostics?.networkRequests.first {
                                let code = firstReq.status ?? 0
                                let reqErr = firstReq.errorText != nil || code >= 500
                                let reqWarn = !reqErr && code >= 400
                                let tint: Color = reqErr ? CeptraTheme.failure : (reqWarn ? CeptraTheme.warning : CeptraTheme.cyan)
                                Text(firstReq.errorText != nil ? "\(firstReq.method) ERR" : (code > 0 ? "\(firstReq.method) \(code)" : firstReq.method))
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(tint)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }

                            Spacer(minLength: 6)

                            if let ms = step.durationMs {
                                Text("\(ms)ms")
                                    .font(.system(size: 10, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(isFailed ? CeptraTheme.failure : CeptraTheme.textMuted)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(isSelected ? CeptraTheme.activeBG : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if idx < activeSteps.count - 1 {
                        Divider().overlay(CeptraTheme.subtleBorder)
                    }
                }
            }
        }
        .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
    }

    private func detailSubTabs(for step: ExecutedStepRecord) -> some View {
        let netCount = step.diagnostics?.networkRequests.count ?? 0
        let conCount = step.diagnostics?.consoleEntries.count ?? 0

        return HStack(spacing: 4) {
            ForEach(ReplayDetailTab.allCases) { tab in
                let isSelected = detailTab == tab
                let title: String = {
                    switch tab {
                    case .visual: return "Visual"
                    case .dom: return "DOM"
                    case .network: return "Network (\(netCount))"
                    case .console: return "Console (\(conCount))"
                    }
                }()
                Button {
                    withAnimation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion)) {
                        detailTab = tab
                    }
                } label: {
                    Text(title)
                        .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            isSelected ? CeptraTheme.activeBG : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func detailContentCard(for step: ExecutedStepRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let err = step.errorMessage, !err.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(CeptraTheme.failure)
                        .padding(.top, 1)
                    Text(err)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(CeptraTheme.failure)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button {
                        appState.triggerAIQuickAction(.debugReplayFailure, replayStep: step)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("Debug with AI")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(CeptraTheme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(CeptraTheme.accent.opacity(0.4), lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .help("Send this failing step's error, DOM snapshot, and network diagnostics to AI Assistant")
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CeptraTheme.failure.opacity(0.10))
                Divider().overlay(CeptraTheme.border)
            }

            switch detailTab {
            case .visual:
                visualTabBody(for: step)
            case .dom:
                domTabBody(for: step)
            case .network:
                networkTabBody(for: step)
            case .console:
                consoleTabBody(for: step)
            }
        }
        .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CeptraTheme.border, lineWidth: 1))
    }

    @ViewBuilder
    private func visualTabBody(for step: ExecutedStepRecord) -> some View {
        let diag = step.diagnostics
        VStack(alignment: .leading, spacing: 8) {
            if let pageURL = diag?.pageURL, !pageURL.isEmpty {
                HStack {
                    Text(pageURL)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("Before / After")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                Divider().overlay(CeptraTheme.subtleBorder)
            }

            let beforeImg = decodeDataURIImage(diag?.beforeScreenshotDataURI)
            let afterImg = decodeDataURIImage(diag?.afterScreenshotDataURI)

            if beforeImg != nil || afterImg != nil {
                HStack(spacing: 8) {
                    screenshotCard(title: "BEFORE", image: beforeImg, borderTint: CeptraTheme.border)
                    screenshotCard(
                        title: "AFTER",
                        image: afterImg,
                        borderTint: step.status == .failed ? CeptraTheme.failure : CeptraTheme.success
                    )
                }
                .padding(10)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.text)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    if let sel = step.targetSelector ?? diag?.domSnapshot?.targetSelector {
                        Text("Selector: \(sel)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(CeptraTheme.cyan)
                    }
                    Text("Enable Time-Travel Trace in Run Options to capture pixel-level Before/After screenshots.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .padding(.top, 2)
                }
                .padding(10)
            }
        }
    }

    private func screenshotCard(title: String, image: NSImage?, borderTint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(CeptraTheme.textMuted)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Text("No capture")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(CeptraTheme.elevatedBG, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(7)
        .background(CeptraTheme.sidebarBG, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(borderTint.opacity(0.65), lineWidth: 1))
    }

    @ViewBuilder
    private func domTabBody(for step: ExecutedStepRecord) -> some View {
        if let dom = step.diagnostics?.domSnapshot {
            VStack(alignment: .leading, spacing: 6) {
                if let sel = dom.targetSelector, !sel.isEmpty {
                    Text("Target: \(sel)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.accentWarm)
                }
                let snippet = dom.targetOuterHTML ?? String(dom.html.prefix(1200))
                Text(snippet)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
        } else {
            Text("No DOM snapshot captured for this step.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(CeptraTheme.textMuted)
                .padding(10)
        }
    }

    private func resolvedNetworkRequests(for step: ExecutedStepRecord) -> (requests: [TimeTravelNetworkEntry], linkedFromAssertion: Bool) {
        let direct = step.diagnostics?.networkRequests ?? []
        if !direct.isEmpty {
            return (direct, false)
        }
        if let relatedId = step.diagnostics?.assertion?.relatedRequestId {
            for candidate in activeSteps {
                if let match = candidate.diagnostics?.networkRequests.first(where: { $0.id == relatedId }) {
                    return ([match], true)
                }
            }
        }
        return ([], false)
    }

    private func prettyJSONString(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return raw
        }
        return pretty
    }

    @ViewBuilder
    private func networkTabBody(for step: ExecutedStepRecord) -> some View {
        let resolved = resolvedNetworkRequests(for: step)
        let requests = resolved.requests
        VStack(alignment: .leading, spacing: 8) {
            if let assertion = step.diagnostics?.assertion {
                let lowerMethod = assertion.method.lowercased()
                let assertionTitle = (lowerMethod.hasPrefix("to") || lowerMethod.hasPrefix("not.") || lowerMethod.hasPrefix("expect"))
                    ? (lowerMethod.hasPrefix("expect") ? assertion.method : "expect(…).\(assertion.method)(…)")
                    : "I.\(assertion.method)(…)"
                HStack(spacing: 6) {
                    Image(systemName: assertion.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(assertion.passed ? CeptraTheme.success : CeptraTheme.failure)
                    Text(assertionTitle)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    Spacer()
                    Text(assertion.passed ? "PASSED" : "FAILED")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(assertion.passed ? CeptraTheme.success : CeptraTheme.failure)
                }
                .padding(7)
                .background(
                    (assertion.passed ? CeptraTheme.success : CeptraTheme.failure).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            }

            if requests.isEmpty {
                Text("No network requests captured in this step.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
            } else {
                if resolved.linkedFromAssertion {
                    Text("Asserted against preceding HTTP exchange:")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(CeptraTheme.cyan)
                }
                ForEach(requests) { req in
                    let code = req.status ?? 0
                    let isErr = code >= 400 || req.errorText != nil
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(code > 0 ? "\(code)" : "ERR")
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(isErr ? CeptraTheme.failure : CeptraTheme.success)
                            Text(req.method)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textPrimary)
                            Text(req.url)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let ms = req.durationMs {
                                Text("\(ms)ms")
                                    .font(.system(size: 10, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(CeptraTheme.textMuted)
                            }
                        }
                        if let reqBody = req.requestBody, !reqBody.isEmpty {
                            Text("REQ: \(String(prettyJSONString(reqBody).prefix(320)))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textSecondary)
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(CeptraTheme.sidebarBG, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .textSelection(.enabled)
                        }
                        if let body = req.responseBody ?? req.errorText, !body.isEmpty {
                            Text(String(prettyJSONString(body).prefix(640)))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(isErr ? CeptraTheme.failure : CeptraTheme.textSecondary)
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(CeptraTheme.elevatedBG, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private func consoleTabBody(for step: ExecutedStepRecord) -> some View {
        let entries = step.diagnostics?.consoleEntries ?? []
        if entries.isEmpty {
            Text("No browser console entries recorded in this step.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(CeptraTheme.textMuted)
                .padding(10)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(entries) { entry in
                    let color: Color = {
                        switch entry.level {
                        case .error, .pageerror: return CeptraTheme.failure
                        case .warn: return CeptraTheme.warning
                        default: return CeptraTheme.textSecondary
                        }
                    }()
                    Text("[\(entry.level.rawValue.uppercased())] \(entry.message)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(color)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        }
    }

    private var exportActionsBar: some View {
        VStack(spacing: 6) {
            Button {
                appState.openSelectedTimeTravelReport()
            } label: {
                HStack(spacing: 6) {
                    Text("Open Standalone Replay HTML")
                        .font(.system(size: 11.5, weight: .semibold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(CeptraTheme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(CeptraTheme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CeptraTheme.accent.opacity(0.55), lineWidth: 1))
            }
            .buttonStyle(CeptraTactilePressStyle())

            Button {
                appState.showingReportsSheet = true
            } label: {
                Text("View All Run History & Artifacts…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CeptraTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func selectStep(_ index: Int) {
        selectedStepIndex = index
        // Best-effort editor line sync using parsed scenarios in active tab
        guard let step = selectedStep, let tab = appState.activeTab else { return }
        let lines = tab.content.components(separatedBy: .newlines)
        let cleaned = step.text.replacingOccurrences(of: "I ", with: "I.").trimmingCharacters(in: .whitespaces)
        if let actionWord = cleaned.split(separator: " ").first, actionWord.count > 2 {
            let needle = String(actionWord)
            if let lineIdx = lines.firstIndex(where: { $0.contains(needle) }) {
                appState.pendingJumpToLine = lineIdx + 1
            }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
            return
        }
        guard !activeSteps.isEmpty else { return }
        isPlaying = true
        if selectedStepIndex >= activeSteps.count - 1 {
            selectedStepIndex = 0
        }
        playTask = Task { @MainActor in
            while isPlaying && selectedStepIndex < activeSteps.count - 1 {
                try? await Task.sleep(nanoseconds: 850_000_000)
                if Task.isCancelled || !isPlaying { break }
                selectStep(selectedStepIndex + 1)
            }
            isPlaying = false
        }
    }

    private func stopPlayback() {
        isPlaying = false
        playTask?.cancel()
        playTask = nil
    }

    private func decodeDataURIImage(_ uri: String?) -> NSImage? {
        guard let uri, let commaIdx = uri.firstIndex(of: ",") else { return nil }
        let base64 = String(uri[uri.index(after: commaIdx)...])
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        return NSImage(data: data)
    }
}
