import CeptraCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var customConfigDraft: String = ""

    var body: some View {
        Form {
            Section("Editor") {
                HStack {
                    Text("Font Size")
                    Slider(value: $appState.settings.editorFontSize, in: 10...20, step: 0.5)
                    Text("\(String(format: "%.1f", appState.settings.editorFontSize)) pt")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 46, alignment: .trailing)
                }
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
                        }
                    }
                    Text("Resolved: \(ws.config.configFilePath ?? "None detected")")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Section("CodeceptJS Toolchain Overrides") {
                TextField("Custom Node Path (optional)", text: $appState.settings.customNodePath)
                    .textFieldStyle(.roundedBorder)
                TextField("Custom CodeceptJS Binary or bin/codecept.js (optional)", text: $appState.settings.customCodeceptPath)
                    .textFieldStyle(.roundedBorder)
                if let tc = appState.resolvedToolchain {
                    Text("Resolved: \(tc.codeceptExecutable) (\(tc.resolutionSource))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
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
        .frame(width: 560, height: 470)
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
}
