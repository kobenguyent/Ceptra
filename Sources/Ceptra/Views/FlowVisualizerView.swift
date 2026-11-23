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
            .padding(14)
        }
        .background(CeptraTheme.sidebarBG)
    }
}

private struct FeatureFlowCard: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHeaderHovered = false
    @State private var isRunFeatureHovered = false
    @State private var hoveredHookLine: Int? = nil

    let feature: ParsedFeature
    let file: WorkspaceFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Feature Header: Icon + Metadata + Run Feature on top row; Title + Tags span full width below
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Button {
                        appState.pendingJumpToLine = feature.lineNumber
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: file?.category == .gherkinFeature ? "doc.text.magnifyingglass" : "sparkles")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(CeptraTheme.accent)
                                .frame(width: 28, height: 28)
                                .background(CeptraTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                            Text("FEATURE")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(CeptraTheme.textMuted)
                                .lineLimit(1)
                        }
                        .padding(4)
                        .background(
                            isHeaderHovered ? CeptraTheme.glassHoverOverlay : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.99))
                    .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHeaderHovered)
                    .onHover { hovering in
                        isHeaderHovered = hovering
                    }

                    Spacer(minLength: 8)

                    if let file, file.isExecutableTestFile {
                        Button {
                            appState.run(mode: .runFile(relativePath: file.relativePath))
                        } label: {
                            Label("Run Feature", systemImage: "play.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    CeptraTheme.success.opacity(isRunFeatureHovered ? 1.0 : 0.88),
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().strokeBorder(Color.white.opacity(isRunFeatureHovered ? 0.28 : 0.14), lineWidth: 0.75)
                                )
                        }
                        .buttonStyle(CeptraTactilePressStyle())
                        .fixedSize()
                        .disabled(appState.isRunning)
                        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isRunFeatureHovered)
                        .onHover { hovering in
                            isRunFeatureHovered = hovering
                        }
                    }
                }

                Button {
                    appState.pendingJumpToLine = feature.lineNumber
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(feature.title)
                            .font(.system(size: 15.5, weight: .bold))
                            .foregroundStyle(CeptraTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)

                        if !feature.tags.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(feature.tags, id: \.self) { tag in
                                    CeptraBadge(text: tag, color: CeptraTheme.violet)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.995))
            }

            // Lifecycle Hooks strip
            if !feature.hooks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LIFECYCLE HOOKS")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                    ForEach(feature.hooks) { hook in
                        let isHookHovered = hoveredHookLine == hook.lineNumber
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
                        .padding(9)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isHookHovered ? CeptraTheme.hoverBG : CeptraTheme.canvasBG)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(CeptraTheme.border, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHookHovered)
                        .onHover { hovering in
                            hoveredHookLine = hovering ? hook.lineNumber : (hoveredHookLine == hook.lineNumber ? nil : hoveredHookLine)
                        }
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
        .padding(12)
        .background(CeptraTheme.canvasBG, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(CeptraTheme.border, lineWidth: 1)
        )
    }
}

private struct ScenarioFlowCard: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCardHovered = false
    @State private var isHeaderHovered = false
    @State private var isJumpHovered = false
    @State private var isPlayHovered = false
    @State private var isDebugHovered = false

    let scenario: ParsedScenario
    let file: WorkspaceFile?

    var body: some View {
        let status = appState.statusForScenario(scenario)
        let durationMs = appState.durationForScenario(scenario)
        let accentBorder: Color? = status == .failed
            ? CeptraTheme.failure
            : (status == .passed ? CeptraTheme.success : nil)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    appState.pendingJumpToLine = scenario.lineNumber
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        StatusDotView(status: status, size: 10)
                            .padding(.top, 3)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(scenario.cleanTitle)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(scenario.modifier == .skip ? CeptraTheme.textMuted : CeptraTheme.textPrimary)
                                    .strikethrough(scenario.modifier == .skip)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)

                                if scenario.modifier != .standard {
                                    CeptraBadge(text: scenario.modifier.rawValue.uppercased(), color: CeptraTheme.warning)
                                }
                            }
                            HStack(spacing: 6) {
                                Text("L\(scenario.lineNumber)–\(scenario.endLineNumber) · \(scenario.steps.count) steps")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(CeptraTheme.textMuted)
                                    .lineLimit(1)
                                if let durationMs {
                                    CeptraBadge(text: ReportExporter.formatDuration(ms: durationMs), color: CeptraTheme.color(for: status))
                                }
                                ForEach(scenario.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(CeptraTheme.violet)
                                        .lineLimit(1)
                                }
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        isHeaderHovered ? CeptraTheme.glassHoverOverlay : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.99))
                .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHeaderHovered)
                .onHover { hovering in
                    isHeaderHovered = hovering
                }

                HStack(spacing: 6) {
                    Button {
                        appState.pendingJumpToLine = scenario.lineNumber
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10))
                            .foregroundStyle(isJumpHovered ? CeptraTheme.textPrimary : CeptraTheme.textMuted)
                            .frame(width: 22, height: 22)
                            .background(
                                isJumpHovered ? CeptraTheme.glassHoverOverlay : Color.clear,
                                in: Circle()
                            )
                    }
                    .buttonStyle(CeptraTactilePressStyle())
                    .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isJumpHovered)
                    .onHover { hovering in
                        isJumpHovered = hovering
                    }
                    .help("Jump to Line \(scenario.lineNumber)")

                    if file?.isExecutableTestFile == true {
                        Button {
                            appState.debug(mode: .runScenario(relativePath: file?.relativePath, scenarioTitle: scenario.cleanTitle))
                        } label: {
                            Image(systemName: "ladybug")
                                .font(.system(size: 10))
                                .foregroundStyle(CeptraTheme.accentWarm)
                                .frame(width: 24, height: 24)
                                .background(
                                    CeptraTheme.accentWarm.opacity(isDebugHovered ? 0.28 : 0.14),
                                    in: Circle()
                                )
                                .overlay(
                                    Circle().strokeBorder(CeptraTheme.accentWarm.opacity(isDebugHovered ? 0.55 : 0.22), lineWidth: 0.75)
                                )
                        }
                        .buttonStyle(CeptraTactilePressStyle())
                        .disabled(appState.isRunning)
                        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isDebugHovered)
                        .onHover { hovering in
                            isDebugHovered = hovering
                        }
                        .help("Debug Scenario")

                        Button {
                            appState.run(mode: .runScenario(relativePath: file?.relativePath, scenarioTitle: scenario.cleanTitle))
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(CeptraTheme.success)
                                .frame(width: 24, height: 24)
                                .background(
                                    CeptraTheme.success.opacity(isPlayHovered ? 0.28 : 0.14),
                                    in: Circle()
                                )
                                .overlay(
                                    Circle().strokeBorder(CeptraTheme.success.opacity(isPlayHovered ? 0.55 : 0.22), lineWidth: 0.75)
                                )
                        }
                        .buttonStyle(CeptraTactilePressStyle())
                        .disabled(appState.isRunning)
                        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isPlayHovered)
                        .onHover { hovering in
                            isPlayHovered = hovering
                        }
                        .help("Run only this scenario")
                    }
                }
                .fixedSize()
            }

            if !scenario.steps.isEmpty {
                Divider().overlay(CeptraTheme.subtleBorder)
                StepPipelineView(steps: scenario.steps)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCardHovered ? CeptraTheme.hoverBG : CeptraTheme.sidebarBG)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(accentBorder?.opacity(0.6) ?? CeptraTheme.border, lineWidth: 1)
        )
        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isCardHovered)
        .onHover { hovering in
            isCardHovered = hovering
        }
    }
}

private struct StepPipelineView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredStepIndex: Int? = nil

    let steps: [ParsedStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                let color = CeptraTheme.color(for: step.category)
                let isHovered = hoveredStepIndex == index
                Button {
                    appState.pendingJumpToLine = step.lineNumber
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        // Vertical connector node
                        VStack(spacing: 0) {
                            ZStack {
                                Circle()
                                    .fill(color.opacity(isHovered ? 0.28 : 0.18))
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
                                    .foregroundStyle(isHovered ? CeptraTheme.textPrimary.opacity(0.85) : CeptraTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(":\(step.lineNumber)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(isHovered ? CeptraTheme.textSecondary : CeptraTheme.textMuted)
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .background(
                            isHovered ? CeptraTheme.glassHoverOverlay : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(CeptraTactilePressStyle(pressedScale: 0.99))
                .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: isHovered)
                .onHover { hovering in
                    hoveredStepIndex = hovering ? index : (hoveredStepIndex == index ? nil : hoveredStepIndex)
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
        let isPW = workspace.config.framework == .playwright
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isPW ? "PLAYWRIGHT TEST ARCHITECTURE" : "CODECEPTJS 4.X ARCHITECTURE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.accent)
                    Text(workspace.config.projectName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    HStack(spacing: 8) {
                        Text(workspace.config.displayConfigPath(relativeTo: workspace.rootURL) ?? "No config file detected")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(CeptraTheme.textMuted)
                        Button("Change Config…") {
                            appState.selectCustomConfigPanel()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    if workspace.config.isTypeScript { CeptraBadge(text: "TypeScript", color: CeptraTheme.accent) }
                    if workspace.config.isESM { CeptraBadge(text: "ESM", color: CeptraTheme.success) }
                    if let v = workspace.config.packageCodeceptVersion {
                        CeptraBadge(text: isPW ? "@playwright/test \(v)" : "codeceptjs \(v)", color: CeptraTheme.accentWarm)
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
                            .ceptraGlassSurface(
                                cornerRadius: 8,
                                tint: CeptraTheme.elevatedBG,
                                tintOpacity: 0.48
                            )
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

            // Plugins / Reporters
            architectureCard(
                title: isPW ? "REPORTERS (\(workspace.config.plugins.count))" : "PLUGINS (\(workspace.config.plugins.count))",
                icon: "puzzlepiece.extension",
                color: CeptraTheme.violet
            ) {
                if workspace.config.plugins.isEmpty {
                    Text(isPW ? "Using Playwright Test default list reporter." : "Using CodeceptJS 4.x default plugins (screenshot on fail).")
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

            // Multiple Suites / Playwright Projects
            if !workspace.config.multipleSuites.isEmpty {
                architectureCard(
                    title: isPW ? "PROJECTS (\(workspace.config.multipleSuites.count))" : "MULTIPLE SUITES (\(workspace.config.multipleSuites.count))",
                    icon: "square.stack.3d.up",
                    color: CeptraTheme.success
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(isPW ? "Configured for `playwright test --project=<name>`" : "Configured for `codeceptjs run-multiple`")
                                .font(.system(size: 11))
                                .foregroundStyle(CeptraTheme.textMuted)
                            Spacer()
                            Button {
                                appState.run(mode: .runMultiple(suites: [], runAll: true))
                            } label: {
                                Label(isPW ? "Run All Projects" : "Run All (--all)", systemImage: "play.fill")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(CeptraTheme.success.opacity(0.9), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(appState.isRunning)
                        }

                        ForEach(workspace.config.multipleSuites) { suite in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(suite.name)
                                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(CeptraTheme.textPrimary)
                                    if let grep = suite.grep {
                                        CeptraBadge(text: grep, color: CeptraTheme.violet)
                                    }
                                    if let chunks = suite.chunks {
                                        CeptraBadge(text: "\(chunks) chunks", color: CeptraTheme.accentWarm)
                                    }
                                    Spacer()
                                    Button {
                                        appState.run(mode: .runMultiple(suites: [suite.name], runAll: false))
                                    } label: {
                                        Label("Run", systemImage: "play.fill")
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundStyle(CeptraTheme.success)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(appState.isRunning)
                                }

                                if !suite.browsers.isEmpty {
                                    HStack(spacing: 6) {
                                        ForEach(suite.browsers, id: \.self) { browser in
                                            Button {
                                                appState.run(mode: .runMultiple(suites: ["\(suite.name):\(browser)"], runAll: false))
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "play.fill")
                                                        .font(.system(size: 8))
                                                    Text("\(suite.name):\(browser)")
                                                        .font(.system(size: 10.5, design: .monospaced))
                                                }
                                                .foregroundStyle(CeptraTheme.cyan)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(CeptraTheme.cyan.opacity(0.14), in: Capsule())
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(appState.isRunning)
                                            .help("Run `codeceptjs run-multiple \(suite.name):\(browser)`")
                                        }
                                    }
                                }
                            }
                            .padding(10)
                            .ceptraGlassSurface(
                                cornerRadius: 8,
                                tint: CeptraTheme.elevatedBG,
                                tintOpacity: 0.48
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
        .ceptraGlassSurface(
            cornerRadius: 11,
            tint: CeptraTheme.panelBG,
            tintOpacity: 0.56
        )
    }
}
