import CeptraCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

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
        .frame(width: 520, height: 390)
        .onDisappear {
            appState.saveSettings()
        }
    }
}
