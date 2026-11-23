import AppKit
import CeptraCore
import SwiftUI

struct ParallelRunSheetView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var customMultipleArgs: String = ""
    @State private var customWorkerRunsText: String = ""

    private var multipleSuites: [CodeceptMultipleSuiteInfo] {
        appState.workspace?.config.multipleSuites ?? []
    }

    private var effectiveWorkerMode: CodeceptRunMode {
        var selected = appState.runOptions.workerSelectedRuns
        let extra = customWorkerRunsText
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        for item in extra where !selected.contains(item) {
            selected.append(item)
        }
        let serial = appState.runOptions.workerSerialPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return .runWorkers(
            count: appState.runOptions.workerCount,
            strategy: appState.runOptions.workerStrategy,
            selectedRuns: selected,
            serialPattern: serial.isEmpty ? nil : serial,
            lastFailed: appState.runOptions.workerLastFailed
        )
    }

    private var effectiveMultipleMode: CodeceptRunMode {
        if appState.runOptions.multipleRunAll {
            return .runMultiple(suites: [], runAll: true)
        }
        var suites = appState.runOptions.multipleSelectedSuites
        let custom = customMultipleArgs
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        for item in custom where !suites.contains(item) {
            suites.append(item)
        }
        return .runMultiple(suites: suites, runAll: suites.isEmpty)
    }

    private var isPlaywright: Bool {
        appState.isPlaywrightWorkspace
    }

    private var commandPreview: String {
        guard let ws = appState.workspace, let tc = appState.resolvedToolchain else {
            return isPlaywright ? "playwright test" : "codeceptjs"
        }
        let mode = appState.parallelRunSheetTab == .workers ? effectiveWorkerMode : effectiveMultipleMode
        return CommandBuilder.build(
            mode: mode,
            options: appState.runOptions,
            workspaceRoot: ws.rootURL,
            configFilePath: ws.config.configFilePath,
            toolchain: tc,
            framework: ws.config.framework,
            colorOutput: appState.isSystemConsoleMode
        ).displayCommand
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header + Mode Switcher
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isPlaywright ? "Parallel Workers & Projects" : "Parallel & Multi-Suite Execution")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    Text(isPlaywright ? "Playwright Test --workers & --project launcher" : "CodeceptJS 4.x run-workers & run-multiple launcher")
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textMuted)
                }
                Spacer()
            }

            CeptraGlassSegmentedControl(
                options: ParallelRunTab.allCases,
                selection: $appState.parallelRunSheetTab,
                label: { tab in
                    if isPlaywright {
                        return tab == .workers ? "Workers (--workers)" : "Projects (--project)"
                    }
                    return tab.rawValue
                }
            )

            Divider().overlay(CeptraTheme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch appState.parallelRunSheetTab {
                    case .workers:
                        workersConfigurationBody
                    case .multiple:
                        multipleConfigurationBody
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 330)

            // Live CLI Preview
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("COMMAND PREVIEW")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)
                    Spacer()
                    CeptraBadge(
                        text: appState.settings.jsRuntime.displayName,
                        color: appState.settings.jsRuntime == .bun ? CeptraTheme.accentWarm : CeptraTheme.success,
                        icon: appState.settings.jsRuntime == .bun ? "bolt.fill" : "hexagon.fill"
                    )
                    CeptraBadge(
                        text: appState.isSystemConsoleMode ? appState.activeTerminalDisplayName : "Built-in",
                        color: appState.isSystemConsoleMode ? CeptraTheme.cyan : CeptraTheme.accent,
                        icon: appState.isSystemConsoleMode ? "terminal" : "rectangle.bottomthird.inset.filled"
                    )
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text("$ \(commandPreview)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(CeptraTheme.cyan)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
                .background(Color(red: 0.058, green: 0.064, blue: 0.080), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(CeptraTheme.border, lineWidth: 0.75))
            }

            HStack {
                Button("Close") {
                    appState.saveSettings()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    appState.saveSettings()
                    let mode = appState.parallelRunSheetTab == .workers ? effectiveWorkerMode : effectiveMultipleMode
                    dismiss()
                    appState.run(mode: mode)
                } label: {
                    Label(
                        appState.parallelRunSheetTab == .workers
                            ? "Run Workers"
                            : (isPlaywright ? "Run Projects" : "Run Multiple"),
                        systemImage: "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(CeptraTheme.success)
                .disabled(appState.isRunning || appState.workspace == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(CeptraTheme.sidebarBG.opacity(0.78))
            }
        }
    }

    // MARK: - Workers Tab

    private var workersConfigurationBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Worker Count
            HStack(spacing: 12) {
                Text("Workers")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textPrimary)
                    .frame(width: 90, alignment: .leading)

                Stepper("\(appState.runOptions.workerCount)", value: $appState.runOptions.workerCount, in: 1...16)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 92)

                HStack(spacing: 4) {
                    ForEach([2, 4, 6, 8], id: \.self) { count in
                        let selected = appState.runOptions.workerCount == count
                        Button("\(count)x") {
                            appState.runOptions.workerCount = count
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(selected ? .white : CeptraTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(selected ? CeptraTheme.accent : CeptraTheme.panelBG, in: Capsule())
                        .overlay(Capsule().stroke(CeptraTheme.border, lineWidth: 0.75))
                    }
                }
                Spacer()
            }

            // Distribution Strategy & Serial Pattern (CodeceptJS only)
            if !isPlaywright {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text("Strategy (--by)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CeptraTheme.textPrimary)
                            .frame(width: 90, alignment: .leading)

                        Picker("", selection: $appState.runOptions.workerStrategy) {
                            ForEach(WorkerStrategy.allCases, id: \.self) { strat in
                                Text(strat.rawValue).tag(strat)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                        Spacer()
                    }
                    Text(appState.runOptions.workerStrategy.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(CeptraTheme.textMuted)
                        .padding(.leading, 102)
                }

                // Serial Pattern & Last Failed
                HStack(spacing: 12) {
                    Text("Serial (--serial)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CeptraTheme.textPrimary)
                        .frame(width: 90, alignment: .leading)

                    TextField("Optional pattern run serially after workers (e.g. @serial)", text: $appState.runOptions.workerSerialPattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                }
            }

            HStack(spacing: 12) {
                Spacer().frame(width: 90)
                Toggle("Run only last failed tests (--last-failed)", isOn: $appState.runOptions.workerLastFailed)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }

            // Optional Project / Multiple Selected Runs filter
            VStack(alignment: .leading, spacing: 6) {
                Text(isPlaywright ? "Optional Projects Filter (--project=...)" : "Optional Multiple Runs Filter ([selectedRuns...])")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(CeptraTheme.textSecondary)

                if !multipleSuites.isEmpty {
                    let chipTargets: [String] = isPlaywright
                        ? multipleSuites.map(\.name)
                        : multipleSuites.flatMap { suite in [suite.name] + suite.browserTargets }
                    FlowChipStack(items: chipTargets) { target in
                        let isSelected = appState.runOptions.workerSelectedRuns.contains(target)
                        Button {
                            if isSelected {
                                appState.runOptions.workerSelectedRuns.removeAll { $0 == target }
                            } else {
                                appState.runOptions.workerSelectedRuns.append(target)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 9.5))
                                Text(target)
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .foregroundStyle(isSelected ? .white : CeptraTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isSelected ? CeptraTheme.accent : CeptraTheme.panelBG, in: Capsule())
                            .overlay(Capsule().stroke(CeptraTheme.border, lineWidth: 0.75))
                        }
                        .buttonStyle(.plain)
                    }
                }

                TextField(
                    isPlaywright
                        ? "Optional extra project names (space-separated, e.g. chromium webkit)"
                        : "Optional extra run names (space-separated, e.g. smoke:chromium)",
                    text: $customWorkerRunsText
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
            }
        }
    }

    // MARK: - Multiple / Projects Tab

    private var multipleConfigurationBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                isPlaywright ? "Run all configured projects" : "Run all configured multiple suites (--all)",
                isOn: $appState.runOptions.multipleRunAll
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 12.5, weight: .medium))

            if multipleSuites.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(CeptraTheme.accentWarm)
                        Text(
                            isPlaywright
                                ? "No static `projects: [ ... ]` array detected in the active Playwright config."
                                : "No static `multiple: { ... }` section detected in the active config."
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CeptraTheme.textPrimary)
                    }
                    Text(
                        isPlaywright
                            ? "Playwright Test runs browser/device projects defined in `projects` in `playwright.config.*`. You can still run all tests or enter project names below."
                            : "CodeceptJS `run-multiple` reads suite definitions from `multiple` in your config file. You can still run `--all` or enter custom suite names below if your config builds `multiple` dynamically."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(CeptraTheme.textSecondary)

                    HStack(spacing: 8) {
                        Button(isPlaywright ? "Copy Example projects Config" : "Copy Example multiple Config") {
                            let snippet: String
                            if isPlaywright {
                                snippet = """
                                projects: [
                                  { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
                                  { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
                                  { name: 'webkit', use: { ...devices['Desktop Safari'] } },
                                ],
                                """
                            } else {
                                snippet = """
                                multiple: {
                                  basic: {
                                    browsers: ['chromium', 'firefox'],
                                  },
                                  smoke: {
                                    grep: '@smoke',
                                    browsers: ['chromium'],
                                  },
                                },
                                """
                            }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(snippet, forType: .string)
                            appState.showBanner(isPlaywright ? "Copied projects config snippet" : "Copied multiple config snippet")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if appState.workspace?.config.configFilePath != nil {
                            Button("Open Active Config") {
                                dismiss()
                                appState.openActiveConfigFile()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(CeptraTheme.accentWarm.opacity(0.35), lineWidth: 0.75))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(isPlaywright ? "CONFIGURED PROJECTS (\(multipleSuites.count))" : "CONFIGURED SUITES (\(multipleSuites.count))")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(CeptraTheme.textMuted)

                    ForEach(multipleSuites) { suite in
                        let wholeSelected = appState.runOptions.multipleSelectedSuites.contains(suite.name)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Toggle(isOn: Binding(
                                    get: { wholeSelected },
                                    set: { checked in
                                        appState.runOptions.multipleRunAll = false
                                        if checked {
                                            if !appState.runOptions.multipleSelectedSuites.contains(suite.name) {
                                                appState.runOptions.multipleSelectedSuites.append(suite.name)
                                            }
                                        } else {
                                            appState.runOptions.multipleSelectedSuites.removeAll { $0 == suite.name }
                                        }
                                    }
                                )) {
                                    Text(suite.name)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(CeptraTheme.textPrimary)
                                }
                                .toggleStyle(.checkbox)

                                if let grep = suite.grep {
                                    CeptraBadge(text: grep, color: CeptraTheme.violet)
                                }
                                if let chunks = suite.chunks {
                                    CeptraBadge(text: "\(chunks) chunks", color: CeptraTheme.accentWarm)
                                }

                                Spacer()

                                Button("Run") {
                                    dismiss()
                                    appState.run(mode: .runMultiple(suites: [suite.name], runAll: false))
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(CeptraTheme.success)
                            }

                            if !suite.browsers.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(suite.browsers, id: \.self) { browser in
                                        let target = "\(suite.name):\(browser)"
                                        let isPicked = appState.runOptions.multipleSelectedSuites.contains(target)
                                        Button {
                                            appState.runOptions.multipleRunAll = false
                                            if isPicked {
                                                appState.runOptions.multipleSelectedSuites.removeAll { $0 == target }
                                            } else {
                                                appState.runOptions.multipleSelectedSuites.append(target)
                                            }
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: isPicked ? "checkmark.circle.fill" : "globe")
                                                    .font(.system(size: 9.5))
                                                Text(target)
                                                    .font(.system(size: 10.5, design: .monospaced))
                                            }
                                            .foregroundStyle(isPicked ? .white : CeptraTheme.cyan)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(isPicked ? CeptraTheme.accent : CeptraTheme.cyan.opacity(0.12), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.leading, 20)
                            }
                        }
                        .padding(10)
                        .background(CeptraTheme.panelBG, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CeptraTheme.border, lineWidth: 0.75))
                        .opacity(appState.runOptions.multipleRunAll ? 0.6 : 1.0)
                    }
                }
            }

            if !appState.runOptions.multipleRunAll {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Suite Arguments (space-separated, optional)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CeptraTheme.textSecondary)
                    TextField("e.g. smoke:chromium regression:firefox", text: $customMultipleArgs)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                }
            }
        }
    }
}

private struct FlowChipStack<Content: View>: View {
    let items: [String]
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}
