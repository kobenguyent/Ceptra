import CeptraCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var customConfigDraft: String = ""

    private var detectedTerminals: [DetectedTerminalApp] {
        appState.detectedTerminalApps
    }

    var body: some View {
        TabView {
            generalAndToolchainTab
                .tabItem {
                    Label("Workspace & Runtime", systemImage: "slider.horizontal.3")
                }

            AIProviderSettingsView()
                .environmentObject(appState)
                .tabItem {
                    Label("AI Providers", systemImage: "sparkles")
                }
        }
        .frame(width: 740, height: 600)
        .onAppear {
            customConfigDraft = appState.activeWorkspaceCustomConfigSetting
        }
        .onChange(of: appState.workspace?.config.configFilePath) { _, _ in
            customConfigDraft = appState.activeWorkspaceCustomConfigSetting
        }
        .onDisappear {
            appState.saveSettings()
        }
    }

    private var generalAndToolchainTab: some View {
        Form {
            Section("Appearance & Workspace") {
                Picker("Theme", selection: $appState.settings.appearance) {
                    ForEach(WorkspaceAppearance.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Auto-open Replay on Run", isOn: $appState.settings.modulePreferences.autoOpenReplayOnRun)
                Toggle("Show Bottom Module & Status Strip", isOn: Binding(
                    get: { appState.isStatusBarVisible },
                    set: { appState.setStatusBarVisible($0) }
                ))
            }

            Section("Editor & Zoom") {
                HStack(spacing: 8) {
                    Text("Font Size")
                    Slider(value: $appState.settings.editorFontSize, in: AppSettings.minEditorFontSize...AppSettings.maxEditorFontSize, step: 0.5)
                    Text("\(String(format: "%.1f", appState.settings.editorFontSize)) pt (\(appState.editorZoomPercentage)%)")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(width: 88, alignment: .trailing)
                        .animation(CeptraMotion.resolve(CeptraMotion.micro, reduceMotion: reduceMotion), value: appState.settings.editorFontSize)
                    if !appState.isDefaultZoom {
                        Button("Reset") {
                            appState.resetZoom()
                        }
                        .controlSize(.small)
                    }
                }
                Text("Use ⌘+ / ⌘− / ⌘0, trackpad pinch, or ⌘ + scroll wheel anywhere in the editor to zoom smoothly.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            if let ws = appState.workspace {
                Section("Active Workspace Config (\(ws.config.projectName))") {
                    HStack(spacing: 8) {
                        TextField("Custom config path (relative or absolute, e.g. configs/e2e.conf.ts)", text: $customConfigDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                appState.setCustomConfigFile(path: customConfigDraft)
                            }
                        Button("Apply") {
                            appState.setCustomConfigFile(path: customConfigDraft)
                        }
                        Button("Browse…") {
                            appState.selectCustomConfigPanel()
                            customConfigDraft = appState.activeWorkspaceCustomConfigSetting
                        }
                        if ws.config.isCustomConfigOverride {
                            Button("Auto") {
                                customConfigDraft = ""
                                appState.setCustomConfigFile(path: nil)
                            }
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
                        }
                    }
                    .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: ws.config.isCustomConfigOverride)
                    Text("Resolved: \(ws.config.configFilePath ?? "None detected")")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Section("JavaScript Runtime & Test Framework Toolchain") {
                Picker("JavaScript Runtime", selection: $appState.settings.jsRuntime) {
                    ForEach(JSRuntimeKind.allCases) { rt in
                        Text(rt.displayName).tag(rt)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Custom Node Path (optional)", text: $appState.settings.customNodePath)
                    .textFieldStyle(.roundedBorder)
                TextField("Custom Bun Path (optional, e.g. ~/.bun/bin/bun)", text: $appState.settings.customBunPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Custom CodeceptJS Binary or bin/codecept.js (optional)", text: $appState.settings.customCodeceptPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Custom Playwright Binary or cli.js (optional)", text: $appState.settings.customPlaywrightPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Custom Python / Pytest Path (optional, e.g. .venv/bin/python)", text: $appState.settings.customPythonPath)
                    .textFieldStyle(.roundedBorder)

                if let tc = appState.resolvedToolchain {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Node: \(tc.nodePath ?? "Not found")  •  Bun: \(tc.bunPath ?? "Not found")  •  Python: \(tc.pythonPath ?? "Not found")")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tc.isActiveRuntimeAvailable ? Color.secondary : Color.orange)
                        let runtimeTag = tc.framework == .playwrightPython ? "Python" : tc.runtime.displayName
                        Text("Resolved (\(tc.framework.shortName) · \(runtimeTag)): \(tc.runnerExecutable) (\(tc.resolutionSource))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }

            Section("Console & System Terminal") {
                Picker("Run Commands In", selection: $appState.settings.consoleExecutionMode) {
                    ForEach(ConsoleExecutionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    Picker("System Terminal App", selection: $appState.settings.customTerminalAppPath) {
                        Text("System Default (\(appState.systemDefaultTerminalDisplayName))").tag("")
                        if !detectedTerminals.isEmpty {
                            Divider()
                            ForEach(detectedTerminals) { term in
                                Text(term.isSystemDefault ? "\(term.name) (System Default)" : term.name)
                                    .tag(term.path)
                            }
                        }
                        if !appState.settings.customTerminalAppPath.isEmpty,
                           !detectedTerminals.contains(where: { $0.path == appState.settings.customTerminalAppPath }) {
                            Divider()
                            Text(SystemTerminalLauncher.displayName(forAppAt: URL(fileURLWithPath: appState.settings.customTerminalAppPath)))
                                .tag(appState.settings.customTerminalAppPath)
                        }
                    }

                    Button("Choose App…") {
                        appState.selectCustomTerminalAppPanel()
                    }
                }

                HStack {
                    Text(
                        appState.isSystemConsoleMode
                            ? "Test runs, workers, and shell commands launch in \(appState.activeTerminalDisplayName) with full TTY colors and an interactive shell."
                            : "Test runs stream inside Ceptra's Console Drawer with live steps and Time-Travel reports."
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                    Spacer()

                    if appState.workspace != nil {
                        Button("Open Terminal") {
                            appState.openWorkspaceInSystemTerminal()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Auto-Update (GitHub Releases)") {
                TextField("GitHub Repository (owner/repo)", text: $appState.settings.gitHubRepository)
                    .textFieldStyle(.roundedBorder)
                Toggle("Check for updates automatically on launch", isOn: $appState.settings.autoCheckForUpdates)
                Toggle("Include pre-release tags", isOn: $appState.settings.includePrereleaseUpdates)
                HStack {
                    Button("Check for Updates Now") {
                        appState.showingUpdateSheet = true
                        Task { await appState.checkForUpdates(userInitiated: true) }
                    }
                    Spacer()
                    Text("Current: v\(AppMetadata.currentVersionString) (build \(AppMetadata.buildNumber))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .animation(CeptraMotion.resolve(CeptraMotion.snappy, reduceMotion: reduceMotion), value: appState.resolvedToolchain?.codeceptExecutable)
    }
}
