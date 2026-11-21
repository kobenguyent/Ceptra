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

                Button("New File…") {
                    appState.presentNewFileSheet(inDirectory: appState.activeFileParentRelativeDirectory)
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(appState.workspace == nil)

                Button("New Folder…") {
                    appState.presentNewFolderSheet(inDirectory: appState.activeFileParentRelativeDirectory ?? "")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
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

                Divider()

                Button("Close Tab") {
                    if let path = appState.activeTabPath {
                        appState.closeTab(filePath: path)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appState.activeTabPath == nil)

                Button("Previous Tab") {
                    appState.selectAdjacentTab(offset: -1)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(appState.openTabs.count < 2)

                Button("Next Tab") {
                    appState.selectAdjacentTab(offset: 1)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(appState.openTabs.count < 2)
            }

            CommandMenu("Debug") {
                Button("Debug Current Test File") {
                    appState.debugActiveFile()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!appState.isActiveTabExecutableTestFile || appState.isRunning)

                Button("Debug All Tests") {
                    appState.debug(mode: .runAll)
                }
                .disabled(appState.workspace == nil || appState.isRunning)

                Divider()

                Button("Continue") {
                    appState.debugContinue()
                }
                .keyboardShortcut("y", modifiers: [.control, .command])
                .disabled(!appState.debugPhase.isPaused)

                Button("Pause") {
                    appState.debugPause()
                }
                .disabled(appState.debugPhase != .running)

                Button("Step Over") {
                    appState.debugStepOver()
                }
                .keyboardShortcut("'", modifiers: [.command, .shift])
                .disabled(!appState.debugPhase.isPaused)

                Button("Step Into") {
                    appState.debugStepInto()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!appState.debugPhase.isPaused)

                Button("Step Out") {
                    appState.debugStepOut()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!appState.debugPhase.isPaused)

                Divider()

                Button(appState.isDebugInspectorVisible ? "Hide Debug Inspector" : "Show Debug Inspector") {
                    appState.isDebugInspectorVisible.toggle()
                }
                .keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(appState.workspace == nil)

                Button("Clear All Breakpoints") {
                    appState.clearAllBreakpoints()
                }
                .disabled(appState.breakpoints.isEmpty)
            }

            CommandMenu("CodeceptJS") {
                Button("Run All Tests") {
                    appState.run(mode: .runAll)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.workspace == nil || appState.isRunning)

                Button("Run Current Test File") {
                    appState.runActiveFile()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!appState.isActiveTabExecutableTestFile || appState.isRunning)

                Button("Dry Run (Discover & Validate)") {
                    appState.run(mode: .dryRun(relativePath: nil))
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(appState.workspace == nil || appState.isRunning)

                Button("Re-run Last Failed") {
                    appState.run(mode: .runLastFailed)
                }
                .disabled(appState.workspace == nil || appState.isRunning)

                Divider()

                Button("Run Workers (run-workers)") {
                    appState.runWorkersWithCurrentOptions()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(appState.workspace == nil || appState.isRunning)

                Button("Configure Workers…") {
                    appState.presentParallelRunSheet(tab: .workers)
                }
                .disabled(appState.workspace == nil)

                Button("Run Multiple — All Suites (run-multiple --all)") {
                    appState.run(mode: .runMultiple(suites: [], runAll: true))
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(appState.workspace == nil || appState.isRunning)

                Button("Configure Multiple Run…") {
                    appState.presentParallelRunSheet(tab: .multiple)
                }
                .disabled(appState.workspace == nil)

                Divider()

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

                Button("Select Custom Config File…") {
                    appState.selectCustomConfigPanel()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(appState.workspace == nil)

                Menu("Dependencies & Commands") {
                    Button("Install Dependencies") {
                        appState.runDependencyAction(.install)
                    }
                    Button("Update Dependencies") {
                        appState.runDependencyAction(.update)
                    }
                    Button("Clean Install (Lockfile)") {
                        appState.runDependencyAction(.cleanInstall)
                    }
                    Button("Check Outdated Packages") {
                        appState.runDependencyAction(.outdated)
                    }
                    Divider()
                    Button("Update CodeceptJS (@latest)") {
                        appState.runDependencyAction(.upgradeCodeceptJS)
                    }
                    Button("Install Playwright Browsers") {
                        appState.runDependencyAction(.installPlaywrightBrowsers)
                    }
                }
                .disabled(appState.workspace == nil || appState.isRunning)

                Button("Run Shell Command…") {
                    appState.focusConsoleCommandPrompt()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(appState.workspace == nil)

                Divider()

                Button("Go to Import / Definition") {
                    appState.goToDefinitionTrigger += 1
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(appState.activeTab == nil)

                Button("Navigate Back") {
                    appState.navigateBack()
                }
                .keyboardShortcut("-", modifiers: .control)
                .disabled(!appState.canNavigateBack)

                Button("Navigate Forward") {
                    appState.navigateForward()
                }
                .keyboardShortcut("-", modifiers: [.control, .shift])
                .disabled(!appState.canNavigateForward)

                Divider()

                Menu("Code Folding") {
                    Button("Collapse Block") {
                        appState.triggerEditorFold(.collapseAtCaret)
                    }
                    .keyboardShortcut("[", modifiers: [.command, .option])

                    Button("Expand Block") {
                        appState.triggerEditorFold(.expandAtCaret)
                    }
                    .keyboardShortcut("]", modifiers: [.command, .option])

                    Divider()

                    Button("Collapse All Blocks") {
                        appState.triggerEditorFold(.collapseAll)
                    }
                    .keyboardShortcut("[", modifiers: [.command, .option, .shift])

                    Button("Expand All Blocks") {
                        appState.triggerEditorFold(.expandAll)
                    }
                    .keyboardShortcut("]", modifiers: [.command, .option, .shift])
                }
                .disabled(appState.activeTab == nil)

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
