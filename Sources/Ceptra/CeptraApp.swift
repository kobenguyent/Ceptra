import AppKit
import CeptraCore
import SwiftUI

final class CeptraAppDelegate: NSObject, NSApplicationDelegate {
    static var onWillTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        if let icon = CeptraAppIconRenderer.makeNSImage(pixelSize: 512) {
            NSApplication.shared.applicationIconImage = icon
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.onWillTerminate?()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct CeptraApp: App {
    @NSApplicationDelegateAdaptor(CeptraAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    private var resolvedColorScheme: ColorScheme? {
        switch appState.settings.appearance {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    var body: some Scene {
        Window("Ceptra", id: "studio") {
            MainStudioView()
                .environmentObject(appState)
                .preferredColorScheme(resolvedColorScheme)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear {
                    CeptraAppDelegate.onWillTerminate = { [weak appState] in
                        Task { @MainActor in
                            appState?.stopCodeceptUIServer()
                            appState?.cancelAllAIBackgroundTasks()
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Test Workspace…") {
                    appState.openWorkspacePanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Menu("Create Sample Workspace") {
                    Button("Playwright Test Project (TypeScript)…") {
                        appState.createSamplePlaywrightWorkspacePanel()
                    }
                    Button("CodeceptJS 4.x Project…") {
                        appState.createSampleWorkspacePanel()
                    }
                }

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

                Button(appState.isRightSidebarVisible && appState.activeRightTab == .debug ? "Hide Debug Inspector" : "Show Debug Inspector") {
                    appState.toggleRightTab(.debug)
                }
                .keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(appState.workspace == nil)

                Button("Clear All Breakpoints") {
                    appState.clearAllBreakpoints()
                }
                .disabled(appState.breakpoints.isEmpty)
            }

            CommandMenu("Runner") {
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

                Button(appState.isPlaywrightWorkspace ? "List Tests (playwright test --list)" : "Dry Run (Discover & Validate)") {
                    appState.run(mode: .dryRun(relativePath: nil))
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(appState.workspace == nil || appState.isRunning)

                Button("Re-run Last Failed") {
                    appState.run(mode: .runLastFailed)
                }
                .disabled(appState.workspace == nil || appState.isRunning)

                Divider()

                Button(appState.isPlaywrightWorkspace ? "Run Workers (--workers)" : "Run Workers (run-workers)") {
                    appState.runWorkersWithCurrentOptions()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(appState.workspace == nil || appState.isRunning)

                Button("Configure Workers…") {
                    appState.presentParallelRunSheet(tab: .workers)
                }
                .disabled(appState.workspace == nil)

                Button(appState.isPlaywrightWorkspace ? "Run All Projects" : "Run Multiple — All Suites (run-multiple --all)") {
                    appState.run(mode: .runMultiple(suites: [], runAll: true))
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(appState.workspace == nil || appState.isRunning)

                Button(appState.isPlaywrightWorkspace ? "Configure Projects Run…" : "Configure Multiple Run…") {
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

                if appState.isPlaywrightWorkspace {
                    Button("Record with Playwright Codegen…") {
                        appState.launchPlaywrightCodegen()
                    }
                    .disabled(appState.workspace == nil || appState.isRunning)

                    Button("Open Playwright HTML Report") {
                        appState.openPlaywrightHTMLReport()
                    }
                    .disabled(appState.workspace == nil)

                    Button("Check Playwright Version") {
                        appState.run(mode: .checkEnvironment)
                    }
                    .disabled(appState.workspace == nil || appState.isRunning)
                } else {
                    Button("Check Environment (codeceptjs check)") {
                        appState.run(mode: .checkEnvironment)
                    }
                    .disabled(appState.workspace == nil || appState.isRunning)

                    Button("Generate Type Definitions (codeceptjs def)") {
                        appState.run(mode: .generateDefinitions)
                    }
                    .disabled(appState.workspace == nil || appState.isRunning)
                }

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
                    Button("Update @playwright/test (@latest)") {
                        appState.runDependencyAction(.upgradePlaywright)
                    }
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

                Button("Open Workspace in System Console") {
                    appState.openWorkspaceInSystemTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(appState.workspace == nil)

                Menu("JavaScript Runtime") {
                    ForEach(JSRuntimeKind.allCases) { rt in
                        Button {
                            appState.setJSRuntime(rt)
                        } label: {
                            if appState.settings.jsRuntime == rt {
                                Label(rt.displayName, systemImage: "checkmark")
                            } else {
                                Text(rt.displayName)
                            }
                        }
                    }
                }

                Menu("Console Target") {
                    Button {
                        appState.setConsoleExecutionMode(.builtIn)
                    } label: {
                        if !appState.isSystemConsoleMode {
                            Label("Built-in Console", systemImage: "checkmark")
                        } else {
                            Text("Built-in Console")
                        }
                    }
                    Button {
                        appState.setConsoleExecutionMode(.systemTerminal)
                    } label: {
                        if appState.isSystemConsoleMode {
                            Label("System Console (\(appState.activeTerminalDisplayName))", systemImage: "checkmark")
                        } else {
                            Text("System Console (\(appState.activeTerminalDisplayName))")
                        }
                    }
                }

                Divider()

                Button("Go to Declaration or Usages") {
                    appState.goToDefinitionTrigger += 1
                }
                .keyboardShortcut("b", modifiers: .control)
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

                Button("Screenshot Code Block…") {
                    appState.openCodeSnapshotStudio()
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(appState.activeTab == nil)

                Button("Quick Copy Code Screenshot") {
                    appState.quickCopyCodeSnapshot()
                }
                .keyboardShortcut("p", modifiers: [.command, .option, .shift])
                .disabled(appState.activeTab == nil)

                Divider()

                Button("Zoom In") {
                    appState.zoomIn()
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(!appState.canZoomIn)

                Button("Zoom Out") {
                    appState.zoomOut()
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!appState.canZoomOut)

                Button("Actual Size (100%)") {
                    appState.resetZoom()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(appState.isDefaultZoom)

                Divider()

                Button("Toggle Explorer Sidebar") {
                    appState.toggleLeftSidebar()
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Toggle Terminal & Logs") {
                    appState.toggleTerminal()
                }
                .keyboardShortcut("j", modifiers: .command)

                Button("Toggle Right Sidebar") {
                    appState.toggleRightSidebar()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])

                Divider()

                Button("Open Replay Inspector") {
                    appState.toggleRightTab(.replay)
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(appState.workspace == nil)

                Button(appState.isPlaywrightWorkspace ? "Open Playwright UI Live" : "Open CodeceptUI Live") {
                    appState.toggleRightTab(.codeceptUI)
                }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(appState.workspace == nil)

                Button("Open Flow Outline") {
                    appState.toggleRightTab(.outline)
                }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(appState.workspace == nil)

                Button("Open AI Assistant") {
                    appState.toggleRightTab(.ai)
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(appState.workspace == nil)

                Button("Configure AI Providers…") {
                    appState.showingAIProviderSettingsSheet = true
                }

                Divider()

                Button("Command Palette…") {
                    appState.showingCommandPalette.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(appState.workspace == nil)

                Button("Quick Open File…") {
                    appState.showingCommandPalette = true
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(appState.workspace == nil)
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
                .preferredColorScheme(resolvedColorScheme)
        }
    }
}
