import CeptraCore
import SwiftUI

struct FlowVisualizerView: View {
    @EnvironmentObject var appState: AppState
    let file: WorkspaceFile?
    let features: [ParsedFeature]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !features.isEmpty {
                    ForEach(features) { feature in
                        FeatureFlowCard(feature: feature, file: file)
                    }
                } else if let workspace = appState.workspace {
                    ProjectArchitectureView(workspace: workspace)
                }
            }
            .padding(18)
        }
        .background(CeptraTheme.canvasBG)
    }
}

private struct FeatureFlowCard: View {
    @EnvironmentObject var appState: AppState
    let feature: ParsedFeature
    let file: WorkspaceFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Feature Header
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: file?.category == .gherkinFeature ? "doc.text.magnifyingglass" : "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CeptraTheme.accent)
                    .frame(width: 30, height: 30)
                    .background(CeptraTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text("FEATURE")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                    Text(feature.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(CeptraTheme.textPrimary)

                    if !feature.tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(feature.tags, id: \.self) { tag in
                                CeptraBadge(text: tag, color: CeptraTheme.violet)
                            }
                        }
                    }
                }

                Spacer()

                if let file {
                    Button {
                        appState.run(mode: .runFile(relativePath: file.relativePath))
                    } label: {
                        Label("Run Feature", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(CeptraTheme.success.opacity(0.9), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isRunning)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                appState.pendingJumpToLine = feature.lineNumber
            }

            // Lifecycle Hooks strip
            if !feature.hooks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LIFECYCLE HOOKS")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                    ForEach(feature.hooks) { hook in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                CeptraBadge(text: hook.kind, color: CeptraTheme.accentWarm, icon: "arrow.triangle.2.circlepath")
                                Text("Line \(hook.lineNumber)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(CeptraTheme.textMuted)
                                Spacer()
                            }
                            if !hook.steps.isEmpty {
                                StepPipelineView(steps: hook.steps)
                            }
                        }
                        .padding(10)
                        .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CeptraTheme.border, lineWidth: 0.75))
                        .onTapGesture {
                            appState.pendingJumpToLine = hook.lineNumber
                        }
                    }
                }
            }

            // Scenario Cards with Visual Step Pipeline
            VStack(alignment: .leading, spacing: 12) {
                ForEach(feature.scenarios) { scenario in
                    ScenarioFlowCard(scenario: scenario, file: file)
                }
            }
        }
        .padding(16)
        .background(CeptraTheme.sidebarBG.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(CeptraTheme.border, lineWidth: 1))
    }
}

private struct ScenarioFlowCard: View {
    @EnvironmentObject var appState: AppState
    let scenario: ParsedScenario
    let file: WorkspaceFile?

    var body: some View {
        let status = appState.statusForScenario(scenario)
        let durationMs = appState.durationForScenario(scenario)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDotView(status: status, size: 10)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(scenario.cleanTitle)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(scenario.modifier == .skip ? CeptraTheme.textMuted : CeptraTheme.textPrimary)
                            .strikethrough(scenario.modifier == .skip)

                        if scenario.modifier != .standard {
                            CeptraBadge(text: scenario.modifier.rawValue.uppercased(), color: CeptraTheme.warning)
                        }
                    }
                    HStack(spacing: 8) {
                        Text("L\(scenario.lineNumber)–\(scenario.endLineNumber) · \(scenario.steps.count) steps")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                        ForEach(scenario.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(CeptraTheme.violet)
                        }
                    }
                }

                Spacer()

                if let durationMs {
                    CeptraBadge(text: ReportExporter.formatDuration(ms: durationMs), color: CeptraTheme.color(for: status))
                }

                Button {
                    appState.pendingJumpToLine = scenario.lineNumber
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Jump to Line \(scenario.lineNumber)")

                Button {
                    appState.run(mode: .runScenario(relativePath: file?.relativePath, scenarioTitle: scenario.cleanTitle))
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(CeptraTheme.success)
                        .frame(width: 24, height: 24)
                        .background(CeptraTheme.success.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(appState.isRunning)
                .help("Run only this scenario")
            }

            if !scenario.steps.isEmpty {
                Divider().overlay(CeptraTheme.subtleBorder)
                StepPipelineView(steps: scenario.steps)
            }
        }
        .padding(12)
        .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(status == .failed ? CeptraTheme.failure.opacity(0.6) : (status == .passed ? CeptraTheme.success.opacity(0.35) : CeptraTheme.border), lineWidth: 1)
        )
    }
}

private struct StepPipelineView: View {
    @EnvironmentObject var appState: AppState
    let steps: [ParsedStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                let color = CeptraTheme.color(for: step.category)
                HStack(alignment: .top, spacing: 10) {
                    // Vertical connector node
                    VStack(spacing: 0) {
                        ZStack {
                            Circle()
                                .fill(color.opacity(0.18))
                                .frame(width: 22, height: 22)
                            Image(systemName: step.category.symbolName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(color)
                        }
                        if index < steps.count - 1 {
                            Rectangle()
                                .fill(CeptraTheme.border)
                                .frame(width: 1.5, height: 14)
                        }
                    }

                    // Step details
                    HStack(spacing: 6) {
                        Text(step.actor)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(color)
                        Text(step.action)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textPrimary)
                        if !step.argumentsSummary.isEmpty {
                            Text(step.argumentsSummary)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(":\(step.lineNumber)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                    }
                    .padding(.vertical, 3)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    appState.pendingJumpToLine = step.lineNumber
                }
            }
        }
    }
}

// MARK: - Project Architecture Overview (when viewing Config / Non-test files)

private struct ProjectArchitectureView: View {
    @EnvironmentObject var appState: AppState
    let workspace: CodeceptWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CODECEPTJS 4.X ARCHITECTURE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.accent)
                    Text(workspace.config.projectName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                }
                Spacer()
                HStack(spacing: 6) {
                    if workspace.config.isTypeScript { CeptraBadge(text: "TypeScript", color: CeptraTheme.accent) }
                    if workspace.config.isESM { CeptraBadge(text: "ESM", color: CeptraTheme.success) }
                    if let v = workspace.config.packageCodeceptVersion {
                        CeptraBadge(text: "codeceptjs \(v)", color: CeptraTheme.accentWarm)
                    }
                }
            }

            // Helpers
            architectureCard(title: "HELPERS (\(workspace.config.helpers.count))", icon: "wrench.and.screwdriver", color: CeptraTheme.cyan) {
                if workspace.config.helpers.isEmpty {
                    Text("No helpers detected in config.")
                        .font(.system(size: 12))
                        .foregroundStyle(CeptraTheme.textMuted)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                        ForEach(workspace.config.helpers) { helper in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(helper.name)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(CeptraTheme.textPrimary)
                                    Spacer()
                                    CeptraBadge(text: helper.isBuiltIn ? "Built-in" : "Custom", color: helper.isBuiltIn ? CeptraTheme.cyan : CeptraTheme.accentWarm)
                                }
                                if let summary = helper.summary {
                                    Text(summary)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(CeptraTheme.textSecondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(10)
                            .background(CeptraTheme.elevatedBG.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            // Includes (Actor & Page Objects)
            architectureCard(title: "ACTORS & PAGE OBJECTS (\(workspace.config.includes.count))", icon: "rectangle.stack", color: CeptraTheme.accent) {
                if workspace.config.includes.isEmpty {
                    Text("No include entries configured.")
                        .font(.system(size: 12))
                        .foregroundStyle(CeptraTheme.textMuted)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(workspace.config.includes) { inc in
                            HStack {
                                Text(inc.alias)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(CeptraTheme.success)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(CeptraTheme.textMuted)
                                Text(inc.relativePath)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(CeptraTheme.textSecondary)
                                Spacer()
                            }
                        }
                    }
                }
            }

            // Plugins
            architectureCard(title: "PLUGINS (\(workspace.config.plugins.count))", icon: "puzzlepiece.extension", color: CeptraTheme.violet) {
                if workspace.config.plugins.isEmpty {
                    Text("Using CodeceptJS 4.x default plugins (screenshot on fail).")
                        .font(.system(size: 12))
                        .foregroundStyle(CeptraTheme.textMuted)
                } else {
                    HStack(spacing: 8) {
                        ForEach(workspace.config.plugins) { plugin in
                            CeptraBadge(
                                text: plugin.name,
                                color: plugin.enabled ? CeptraTheme.success : CeptraTheme.textMuted,
                                icon: plugin.enabled ? "checkmark.circle.fill" : "pause.circle"
                            )
                        }
                    }
                }
            }
        }
    }

    private func architectureCard<Content: View>(
        title: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(CeptraTheme.textSecondary)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CeptraTheme.border, lineWidth: 0.75))
    }
}
