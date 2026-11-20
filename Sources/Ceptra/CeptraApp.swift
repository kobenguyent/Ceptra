import AppKit
import CeptraCore
import SwiftUI

final class CeptraAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        if let icon = CeptraAppIconRenderer.makeNSImage(pixelSize: 512) {
            NSApplication.shared.applicationIconImage = icon
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct CeptraApp: App {
    @NSApplicationDelegateAdaptor(CeptraAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("Ceptra", id: "studio") {
            MainStudioView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open CodeceptJS Workspace…") {
                    appState.openWorkspacePanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("New File from Template…") {
                    appState.showingNewFileSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(appState.workspace == nil)

                Divider()

                Button("Save") {
                    appState.saveActiveFile()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(appState.activeTab == nil)

                Button("Save All") {
                    appState.saveAllDirtyFiles()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(appState.openTabs.isEmpty)
            }

            CommandMenu("CodeceptJS") {
                Button("Run All Tests") {
                    appState.run(mode: .runAll)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.workspace == nil || appState.isRunning)

                Button("Run Current File") {
                    appState.runActiveFile()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(appState.workspace == nil || appState.isRunning)

                Button("Dry Run (Discover & Validate)") {
                    appState.run(mode: .dryRun(relativePath: nil))
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(appState.workspace == nil || appState.isRunning)

                Button("Re-run Last Failed") {
                    appState.run(mode: .runLastFailed)
                }
                .disabled(appState.workspace == nil || appState.isRunning)

                Button("Stop Execution") {
                    appState.stopActiveRun()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!appState.isRunning)

                Divider()

                Button("Check Environment (codeceptjs check)") {
                    appState.run(mode: .checkEnvironment)
                }
                .disabled(appState.workspace == nil || appState.isRunning)

                Button("Generate Type Definitions (codeceptjs def)") {
                    appState.run(mode: .generateDefinitions)
                }
                .disabled(appState.workspace == nil || appState.isRunning)

                Divider()

                Button("Toggle Sidebar") {
                    appState.isSidebarVisible.toggle()
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Toggle Console") {
                    appState.isConsoleVisible.toggle()
                }
                .keyboardShortcut("j", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appState.showingUpdateSheet = true
                    Task { await appState.checkForUpdates(userInitiated: true) }
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
    }
}
