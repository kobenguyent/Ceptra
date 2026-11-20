import AppKit
import CeptraCore
import SwiftUI

struct ReportsDashboardView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedSection: ReportTab = .scenarios
    @State private var statusFilter: ExecutionStatus? = nil
    @State private var selectedArtifact: ReportArtifact? = nil
    @State private var hoveredRunID: UUID? = nil
    @State private var hoveredTrendRunID: UUID? = nil
    @State private var hoveredArtifactID: ReportArtifact.ID? = nil

    enum ReportTab: String, CaseIterable, Identifiable {
        case scenarios = "Scenarios & Steps"
        case artifacts = "Artifacts"
        case rawLog = "Raw Output"
        var id: Self { self }
    }

    var body: some View {
        HSplitView {
            // Left: Run History List
            historySidebar
                .frame(minWidth: 210, idealWidth: 240, maxWidth: 290)

            // Right: Report Details & Artifacts
            VStack(spacing: 0) {
                if let report = appState.selectedReport {
                    reportHeader(report)
                    Divider().overlay(CeptraTheme.border)

                    switch selectedSection {
                    case .scenarios:
                        scenariosDetail(report)
                    case .artifacts:
                        artifactsBrowser
                    case .rawLog:
                        rawOutputView(report)
                    }
                } else {
                    emptyReportsView
                }
            }
            .background(CeptraTheme.canvasBG)
        }
    }

    private var historySidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("RUN HISTORY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CeptraTheme.textMuted)
                    .tracking(0.7)
                Spacer()
                if !appState.runHistory.isEmpty {
                    Button("Clear") {
                        appState.clearRunHistory()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(CeptraTheme.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().overlay(CeptraTheme.border)

            // Pass-rate trend bar across last 12 runs
            if appState.runHistory.count >= 2 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RECENT PASS TREND")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(appState.runHistory.prefix(14).reversed()) { run in
                            let barHeight = max(6, CGFloat(run.passRate) * 32)
                            let isTrendHovered = hoveredTrendRunID == run.id
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(CeptraTheme.color(for: run.overallStatus))
                                .brightness(isTrendHovered ? 0.14 : 0)
                                .frame(maxWidth: .infinity)
                                .frame(height: barHeight)
                                .scaleEffect(y: isTrendHovered && !reduceMotion ? 1.08 : 1.0, anchor: .bottom)
                                .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isTrendHovered)
                                .onHover { hovering in
                                    hoveredTrendRunID = hovering ? run.id : (hoveredTrendRunID == run.id ? nil : hoveredTrendRunID)
                                }
                                .onTapGesture {
                                    withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                                        appState.selectedReportID = run.id
                                    }
                                }
                                .help("\(run.label): \(Int(run.passRate * 100))% passed")
                        }
                    }
                    .frame(height: 36, alignment: .bottom)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                Divider().overlay(CeptraTheme.border)
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(appState.runHistory) { report in
                        let selected = appState.selectedReport?.id == report.id
                        let isHovered = hoveredRunID == report.id
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                StatusDotView(status: report.overallStatus, size: 8)
                                Text(report.label)
                                    .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                                    .foregroundStyle(CeptraTheme.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            HStack {
                                Text("\(report.passedCount)✓ \(report.failedCount)✗ \(report.skippedCount)−")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(CeptraTheme.textSecondary)
                                Spacer()
                                Text(ReportExporter.formatDuration(ms: report.durationMs))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(CeptraTheme.textMuted)
                            }
                            Text(report.startedAt, style: .relative)
                                .font(.system(size: 9.5))
                                .foregroundStyle(CeptraTheme.textMuted)
                        }
                        .padding(9)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.clear)
                                    .ceptraGlassSurface(
                                        cornerRadius: 8,
                                        tint: CeptraTheme.elevatedBG,
                                        tintOpacity: 0.65,
                                        isHovered: isHovered,
                                        isActive: true
                                    )
                            } else if isHovered {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(CeptraTheme.glassHoverOverlay)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
                        .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: selected)
                        .onHover { hovering in
                            hoveredRunID = hovering ? report.id : (hoveredRunID == report.id ? nil : hoveredRunID)
                        }
                        .onTapGesture {
                            withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                                appState.selectedReportID = report.id
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
        .ceptraGlassBar(tint: CeptraTheme.sidebarBG, tintOpacity: 0.72)
    }

    private func reportHeader(_ report: TestRunReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        StatusDotView(status: report.overallStatus, size: 12)
                        Text(report.label)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(CeptraTheme.textPrimary)
                    }
                    Text(report.commandLine)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        appState.exportSelectedReport(asHTML: false)
                    } label: {
                        Label("Export MD", systemImage: "doc.plaintext")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        appState.exportSelectedReport(asHTML: true)
                    } label: {
                        Label("Export HTML", systemImage: "globe")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // KPI Cards
            HStack(spacing: 10) {
                ReportKPICard(title: "PASS RATE", value: "\(Int((report.passRate * 100).rounded()))%", color: CeptraTheme.color(for: report.overallStatus))
                ReportKPICard(title: "PASSED", value: "\(report.passedCount)", color: CeptraTheme.success)
                ReportKPICard(title: "FAILED", value: "\(report.failedCount)", color: CeptraTheme.failure)
                ReportKPICard(title: "SKIPPED", value: "\(report.skippedCount)", color: CeptraTheme.warning)
                ReportKPICard(title: "DURATION", value: ReportExporter.formatDuration(ms: report.durationMs), color: CeptraTheme.accent)
            }

            // Section Picker
            HStack {
                CeptraGlassSegmentedControl(
                    options: ReportTab.allCases,
                    selection: $selectedSection,
                    label: { $0.rawValue },
                    badgeCount: { tab in
                        tab == .artifacts ? appState.artifacts.count : nil
                    }
                )

                Spacer()

                if selectedSection == .artifacts {
                    Button {
                        appState.refreshArtifacts()
                    } label: {
                        Label("Rescan output/", systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(CeptraTactilePressStyle())
                    .foregroundStyle(CeptraTheme.textSecondary)
                }
            }
        }
        .padding(16)
        .ceptraGlassBar(tint: CeptraTheme.sidebarBG, tintOpacity: 0.62, bottomHairline: true)
    }

    private func scenariosDetail(_ report: TestRunReport) -> some View {
        let filtered = report.scenarios.filter { statusFilter == nil || $0.status == statusFilter }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                ReportFilterChip(label: "All (\(report.scenarios.count))", isActive: statusFilter == nil) {
                    withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                        statusFilter = nil
                    }
                }
                ReportFilterChip(label: "Passed (\(report.passedCount))", isActive: statusFilter == .passed) {
                    withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                        statusFilter = .passed
                    }
                }
                ReportFilterChip(label: "Failed (\(report.failedCount))", isActive: statusFilter == .failed) {
                    withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                        statusFilter = .failed
                    }
                }
                ReportFilterChip(label: "Skipped (\(report.skippedCount))", isActive: statusFilter == .skipped) {
                    withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                        statusFilter = .skipped
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if filtered.isEmpty {
                        Text("No scenario records captured for this filter. Enable the junitReporter plugin or --steps flag for full step timelines.")
                            .font(.system(size: 12))
                            .foregroundStyle(CeptraTheme.textMuted)
                            .padding(24)
                    } else {
                        ForEach(filtered) { sc in
                            ScenarioResultRow(record: sc)
                        }
                    }
                }
                .padding(16)
                .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: statusFilter)
            }
        }
    }

    private var artifactsBrowser: some View {
        HSplitView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if appState.artifacts.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.system(size: 24))
                                .foregroundStyle(CeptraTheme.textMuted)
                            Text("No artifacts in output/ yet")
                                .font(.system(size: 12))
                                .foregroundStyle(CeptraTheme.textSecondary)
                            Text("Enable screenshot, aiTrace, screencast, or junitReporter in Run Options.")
                                .font(.system(size: 11))
                                .foregroundStyle(CeptraTheme.textMuted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(24)
                    } else {
                        ForEach(appState.artifacts) { item in
                            let selected = selectedArtifact?.id == item.id
                            let isHovered = hoveredArtifactID == item.id
                            HStack(spacing: 8) {
                                Image(systemName: item.kind.symbolName)
                                    .font(.system(size: 12))
                                    .foregroundStyle(CeptraTheme.accent)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(CeptraTheme.textPrimary)
                                        .lineLimit(1)
                                    Text("\(item.kind.displayName) · \(item.formattedSize)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(CeptraTheme.textMuted)
                                }
                                Spacer()
                            }
                            .padding(8)
                            .ceptraGlassSurface(
                                cornerRadius: 8,
                                tint: selected ? CeptraTheme.elevatedBG : CeptraTheme.panelBG,
                                tintOpacity: selected ? 0.68 : 0.45,
                                accentBorder: selected ? CeptraTheme.accent : nil,
                                isHovered: isHovered,
                                isActive: selected
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
                            .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: selected)
                            .onHover { hovering in
                                hoveredArtifactID = hovering ? item.id : (hoveredArtifactID == item.id ? nil : hoveredArtifactID)
                            }
                            .onTapGesture {
                                withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                                    selectedArtifact = item
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
            .frame(minWidth: 220, idealWidth: 260)
            .ceptraGlassBar(tint: CeptraTheme.sidebarBG, tintOpacity: 0.55)

            artifactPreviewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var artifactPreviewPane: some View {
        if let item = selectedArtifact ?? appState.artifacts.first {
            VStack(spacing: 0) {
                HStack {
                    Text(item.relativePath)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    Spacer()
                    Button("Open") {
                        NSWorkspace.shared.open(item.url)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(10)
                .ceptraGlassBar(tint: CeptraTheme.sidebarBG, tintOpacity: 0.72, bottomHairline: true)

                Divider().overlay(CeptraTheme.border)

                if item.kind == .screenshot, let nsImg = NSImage(contentsOf: item.url) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: nsImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(16)
                    }
                } else if [.aiTrace, .subtitle, .junitXML, .snapshot].contains(item.kind),
                          let text = try? String(contentsOf: item.url, encoding: .utf8) {
                    ScrollView {
                        Text(text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: item.kind.symbolName)
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(CeptraTheme.accent)
                        Text(item.name)
                            .font(.system(size: 14, weight: .semibold))
                        Button("Open in Default App") {
                            NSWorkspace.shared.open(item.url)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(CeptraTheme.accent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            Text("Select an artifact to inspect")
                .font(.system(size: 12))
                .foregroundStyle(CeptraTheme.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func rawOutputView(_ report: TestRunReport) -> some View {
        ScrollView {
            Text(report.rawOutput.isEmpty ? "No output recorded." : report.rawOutput)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(CeptraTheme.textPrimary.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }

    private var emptyReportsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(CeptraTheme.textMuted)
            Text("No test runs recorded yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CeptraTheme.textPrimary)
            Text("Run your CodeceptJS 4.x suite to view pass trends, step timelines, screenshots, AI traces, and JUnit XML reports.")
                .font(.system(size: 12))
                .foregroundStyle(CeptraTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Run All Tests (⌘R)") {
                appState.run(mode: .runAll)
            }
            .buttonStyle(.borderedProminent)
            .tint(CeptraTheme.success)
            .disabled(appState.isRunning)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReportKPICard: View {
    let title: String
    let value: String
    let color: Color

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(CeptraTheme.textMuted)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(color)
                .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: value)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ceptraGlassSurface(
            cornerRadius: 10,
            tint: CeptraTheme.panelBG,
            tintOpacity: 0.56,
            isHovered: isHovered
        )
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct ReportFilterChip: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? .white : (isHovered ? CeptraTheme.textPrimary : CeptraTheme.textSecondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background {
                    if isActive {
                        Capsule()
                            .fill(CeptraTheme.accent.opacity(isHovered ? 1.0 : 0.92))
                            .overlay(
                                Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.75)
                            )
                    } else {
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Capsule().fill(CeptraTheme.panelBG.opacity(isHovered ? 0.72 : 0.56))
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    Color.white.opacity(isHovered ? 0.20 : 0.10),
                                    lineWidth: 0.75
                                )
                            )
                    }
                }
        }
        .buttonStyle(CeptraTactilePressStyle())
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: isActive)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct ScenarioResultRow: View {
    let record: ExecutedScenarioRecord
    @State private var isExpanded: Bool
    @State private var isHovered: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(record: ExecutedScenarioRecord) {
        self.record = record
        self._isExpanded = State(initialValue: record.status == .failed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDotView(status: record.status, size: 9)
                Text(record.featureTitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textMuted)
                Text("›")
                    .foregroundStyle(CeptraTheme.textMuted)
                Text(record.scenarioTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textPrimary)
                Spacer()
                Text(ReportExporter.formatDuration(ms: record.durationMs))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovered ? CeptraTheme.textSecondary : CeptraTheme.textMuted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !record.steps.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(record.steps) { step in
                                HStack(spacing: 6) {
                                    Image(systemName: step.status == .failed ? "xmark.circle.fill" : "checkmark.circle")
                                        .font(.system(size: 10))
                                        .foregroundStyle(step.status == .failed ? CeptraTheme.failure : CeptraTheme.success)
                                    Text(step.text)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(step.status == .failed ? CeptraTheme.failure : CeptraTheme.textSecondary)
                                    Spacer()
                                    if let ms = step.durationMs {
                                        Text("\(ms)ms")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(CeptraTheme.textMuted)
                                    }
                                }
                                .padding(.leading, CGFloat(step.depth * 14))
                            }
                        }
                        .padding(.top, 4)
                    }

                    if let err = record.errorMessage {
                        Text(record.errorStack ?? err)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(red: 0.99, green: 0.68, blue: 0.70))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(CeptraTheme.failure.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(CeptraTheme.failure.opacity(0.35), lineWidth: 0.75))
                    }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .ceptraGlassSurface(
            cornerRadius: 10,
            tint: CeptraTheme.panelBG,
            tintOpacity: 0.56,
            accentBorder: record.status == .failed ? CeptraTheme.failure : nil,
            isHovered: isHovered
        )
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
