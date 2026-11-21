import AppKit
import CeptraCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum WorkspaceViewMode: String, CaseIterable, Identifiable {
    case code = "Code"
    case split = "Split"
    case visual = "Visual"
    case reports = "Reports"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .split: return "rectangle.split.2x1"
        case .visual: return "point.3.connected.trianglepath.dotted"
        case .reports: return "chart.bar.doc.horizontal"
        }
    }
}

struct OpenDocumentTab: Identifiable, Equatable {
    var id: String { filePath }
    let filePath: String
    let relativePath: String
    let name: String
    let language: String
    let category: WorkspaceFileCategory
    var content: String
    var savedContent: String

    var isDirty: Bool { content != savedContent }
    var isExecutableTestFile: Bool {
        category == .testSuite || category == .gherkinFeature
    }
}

struct NavigationHistoryEntry: Equatable {
    let filePath: String
    let lineNumber: Int
}

struct ConsoleLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let text: String
    let isError: Bool
    let isStep: Bool
    let isHighlight: Bool
}

enum ParallelRunTab: String, CaseIterable, Identifiable {
    case workers = "Workers (run-workers)"
    case multiple = "Multiple (run-multiple)"
    var id: String { rawValue }
}

enum EditorFoldAction: Equatable {
    case collapseAtCaret
    case expandAtCaret
    case collapseAll
    case expandAll
}

enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate(current: SemanticVersion, checkedAt: Date)
    case available(release: GitHubRelease, latestVersion: SemanticVersion, asset: GitHubReleaseAsset?)
    case downloading(release: GitHubRelease, asset: GitHubReleaseAsset, progress: Double)
    case readyToInstall(release: GitHubRelease, artifact: DownloadedUpdateArtifact)
    case installing(release: GitHubRelease)
    case failed(message: String)

    var hasActionableUpdate: Bool {
        switch self {
        case .available, .downloading, .readyToInstall:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    // Workspace & Navigation
    @Published var workspace: CodeceptWorkspace?
    @Published var workspaceMode: WorkspaceViewMode = .code
    @Published var sidebarFilterText: String = ""
    @Published var selectedTagFilter: String? = nil
    @Published var isSidebarVisible: Bool = true
    @Published var isConsoleVisible: Bool = false
    @Published var isRightSidebarVisible: Bool = false
    @Published var activeRightTab: RightInspectorTab = .replay
    @Published var isStatusBarVisible: Bool = true
    @Published var cursorLine: Int = 1
    @Published var cursorColumn: Int = 1

    // Editor Tabs, IntelliSense & Import Navigation History
    @Published var openTabs: [OpenDocumentTab] = []
    @Published var activeTabPath: String? = nil
    @Published var pendingJumpToLine: Int? = nil
    @Published var liveParsedFeaturesByPath: [String: [ParsedFeature]] = [:]
    @Published var completionIndex: WorkspaceCompletionIndex = WorkspaceCompletionIndex()
    @Published var goToDefinitionTrigger: Int = 0
    @Published var editorFoldActionTrigger: Int = 0
    @Published var pendingEditorFoldAction: EditorFoldAction? = nil
    @Published var navigationBackStack: [NavigationHistoryEntry] = []
    @Published var navigationForwardStack: [NavigationHistoryEntry] = []

    // Execution & Live Status
    @Published var runOptions: RunOptions
    @Published var isRunning: Bool = false
    @Published var activeRunLabel: String = ""
    @Published var lastCommandLine: String = ""
    @Published var consoleLogs: [ConsoleLogEntry] = []
    @Published var commandInputText: String = ""
    @Published var commandHistory: [String] = []
    @Published var focusCommandInputTrigger: Int = 0
    @Published var liveScenarioStatuses: [String: ExecutionStatus] = [:]
    @Published var liveScenarioDurations: [String: Int] = [:]
    @Published var activeRunningScenarioKey: String? = nil

    // Interactive Debug Mode State
    @Published var debugPhase: DebugSessionPhase = .idle
    @Published var isDebugInspectorVisible: Bool = false
    @Published var breakpoints: [DebugBreakpoint] = []
    @Published var debugCallFrames: [DebugCallFrame] = []
    @Published var selectedCallFrameID: String? = nil
    @Published var debugScopeVariables: [String: [DebugVariable]] = [:]
    @Published var debugWatchItems: [DebugWatchItem] = []
    @Published var debugConsoleEntries: [DebugConsoleEntry] = []
    @Published var debugJustMyCode: Bool = true
    @Published var isInteractivePauseShellActive: Bool = false
    @Published var lastDebugMode: CodeceptRunMode? = nil

    // Reports, Replay & CodeceptUI Live Server
    @Published var runHistory: [TestRunReport] = []
    @Published var selectedReportID: UUID? = nil
    @Published var artifacts: [ReportArtifact] = []
    @Published var activeReplayTraceBundle: TimeTravelTraceBundle? = nil
    @Published var liveReplaySteps: [ExecutedStepRecord] = []
    @Published var codeceptUIStatus: CodeceptUIServerStatus = .stopped
    @Published var codeceptUILogs: [String] = []

    // Sheets, Notifications, Settings & Updates
    @Published var settings: AppSettings
    @Published var showingNewFileSheet: Bool = false
    @Published var newFileInitialDirectory: String? = nil
    @Published var showingNewFolderSheet: Bool = false
    @Published var newFolderInitialDirectory: String? = nil
    @Published var pendingRevealTreePath: String? = nil
    @Published var showingParallelRunSheet: Bool = false
    @Published var parallelRunSheetTab: ParallelRunTab = .workers
    @Published var showingUpdateSheet: Bool = false
    @Published var showingRunOptionsPopover: Bool = false
    @Published var showingToolsPopover: Bool = false
    @Published var showingCommandPalette: Bool = false
    @Published var showingReportsSheet: Bool = false
    @Published var bannerMessage: String? = nil
    @Published var bannerIsError: Bool = false
    @Published var zoomHUDText: String? = nil
    @Published var updateState: AppUpdateState = .idle

    // Services
    private let settingsStore = AppSettingsStore()
    private let historyStore = RunHistoryStore()
    private let traceStore = TimeTravelTraceStore()
    let runnerService = TestRunnerService()
    let codeceptUIManager = CodeceptUIServerManager()
    private let updateService = UpdateService()
    let breakpointStore = BreakpointStore()
    var cdpClient: CDPInspectorClient? = nil
    var cdpEventTask: Task<Void, Never>? = nil
    var hasHandledInitialBreakOnStart: Bool = false
    private var zoomHUDDismissTask: Task<Void, Never>? = nil

    init() {
        let loadedSettings = settingsStore.load()
        self.settings = loadedSettings
        self.runOptions = loadedSettings.defaultRunOptions
        self.isSidebarVisible = loadedSettings.modulePreferences.showLeftSidebar
        self.isConsoleVisible = loadedSettings.modulePreferences.showTerminal
        self.isRightSidebarVisible = loadedSettings.modulePreferences.showRightSidebar
        self.isStatusBarVisible = loadedSettings.modulePreferences.showStatusBar
        self.activeRightTab = loadedSettings.modulePreferences.activeRightTab

        // Restore most recent existing workspace automatically if available
        if let firstPath = loadedSettings.recentProjectPaths.first,
           FileManager.default.fileExists(atPath: firstPath) {
            openWorkspace(at: URL(fileURLWithPath: firstPath))
        }

        if loadedSettings.autoCheckForUpdates {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await self?.checkForUpdates(userInitiated: false)
            }
        }
    }

    // MARK: - Computed Helpers

    var activeTab: OpenDocumentTab? {
        guard let activeTabPath else { return nil }
        return openTabs.first(where: { $0.filePath == activeTabPath })
    }

    var activeWorkspaceFile: WorkspaceFile? {
        guard let activeTabPath, let workspace else { return nil }
        return workspace.files.first(where: { $0.path == activeTabPath })
    }

    var isActiveTabExecutableTestFile: Bool {
        guard let tab = activeTab else { return false }
        if tab.category == .config || tab.category == .helper || tab.category == .pageObject || tab.category == .stepDefinition {
            return false
        }
        return !activeFeaturesForCurrentTab.isEmpty
    }

    var canNavigateBack: Bool { !navigationBackStack.isEmpty }
    var canNavigateForward: Bool { !navigationForwardStack.isEmpty }

    var editorZoomScale: Double { settings.editorZoomScale }
    var editorZoomPercentage: Int { settings.editorZoomPercentage }
    var isDefaultZoom: Bool { abs(settings.editorFontSize - AppSettings.defaultEditorFontSize) < 0.05 }
    var canZoomIn: Bool { settings.editorFontSize < AppSettings.maxEditorFontSize - 0.05 }
    var canZoomOut: Bool { settings.editorFontSize > AppSettings.minEditorFontSize + 0.05 }

    func zoomIn(step: Double = 1.0) {
        setEditorFontSize(settings.editorFontSize + step, showHUD: true)
    }

    func zoomOut(step: Double = 1.0) {
        setEditorFontSize(settings.editorFontSize - step, showHUD: true)
    }

    func resetZoom() {
        setEditorFontSize(AppSettings.defaultEditorFontSize, showHUD: true)
    }

    func applyZoomDelta(_ deltaPoints: Double) {
        guard abs(deltaPoints) >= 0.45 else { return }
        setEditorFontSize(settings.editorFontSize + deltaPoints, showHUD: true)
    }

    func setEditorFontSize(_ rawSize: Double, showHUD: Bool = true) {
        let next = AppSettings.clampedEditorFontSize(rawSize)
        let changed = abs(settings.editorFontSize - next) > 0.01
        if changed {
            settings.editorFontSize = next
            saveSettings()
        }
        if showHUD {
            let pct = settings.editorZoomPercentage
            let ptStr = next.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(next))"
                : String(format: "%.1f", next)
            zoomHUDText = "\(pct)% · \(ptStr)pt"
            zoomHUDDismissTask?.cancel()
            zoomHUDDismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_150_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.zoomHUDText = nil
                }
            }
        }
    }

    var activeFeaturesForCurrentTab: [ParsedFeature] {
        guard let activeTabPath else { return [] }
        if let live = liveParsedFeaturesByPath[activeTabPath] {
            return live
        }
        return activeWorkspaceFile?.features ?? []
    }

    var selectedReport: TestRunReport? {
        if let selectedReportID, let match = runHistory.first(where: { $0.id == selectedReportID }) {
            return match
        }
        return runHistory.first
    }

    var resolvedToolchain: ResolvedToolchain? {
        guard let root = workspace?.rootURL else { return nil }
        return NodeToolchainResolver.resolve(
            workspaceRoot: root,
            runtime: settings.jsRuntime,
            customNodePath: settings.customNodePath,
            customBunPath: settings.customBunPath,
            customCodeceptPath: settings.customCodeceptPath
        )
    }

    var isSystemConsoleMode: Bool {
        settings.consoleExecutionMode == .systemTerminal
    }

    var activeTerminalDisplayName: String {
        SystemTerminalLauncher.activeTerminalDisplayName(preferredAppPath: settings.customTerminalAppPath)
    }

    var systemDefaultTerminalDisplayName: String {
        SystemTerminalLauncher.systemDefaultTerminalDisplayName()
    }

    var detectedTerminalApps: [DetectedTerminalApp] {
        SystemTerminalLauncher.detectInstalledTerminalApps()
    }

    func setJSRuntime(_ runtime: JSRuntimeKind) {
        guard settings.jsRuntime != runtime else { return }
        settings.jsRuntime = runtime
        saveSettings()
        if let tc = resolvedToolchain {
            if let binPath = tc.activeRuntimePath {
                showBanner("Runtime switched to \(runtime.displayName) (\(binPath))")
            } else {
                showBanner("\(runtime.displayName) was not found in PATH — install \(runtime.executableName) or set Custom \(runtime.shortName) Path in Settings.", isError: true)
            }
        } else {
            showBanner("Runtime switched to \(runtime.displayName)")
        }
    }

    func setConsoleExecutionMode(_ mode: ConsoleExecutionMode) {
        guard settings.consoleExecutionMode != mode else { return }
        settings.consoleExecutionMode = mode
        saveSettings()
        switch mode {
        case .builtIn:
            showBanner("Console switched to Built-in Console")
        case .systemTerminal:
            showBanner("Console switched to System Console (\(activeTerminalDisplayName))")
        }
    }

    func openWorkspaceInSystemTerminal() {
        guard let workspace else {
            showBanner("Open a workspace first.", isError: true)
            return
        }
        do {
            let terminalName = try SystemTerminalLauncher.openWorkspaceDirectory(
                workspace.rootURL,
                preferredAppPath: settings.customTerminalAppPath
            )
            showBanner("Opened \(workspace.config.projectName) in \(terminalName)")
        } catch {
            showBanner(error.localizedDescription, isError: true)
        }
    }

    func selectCustomTerminalAppPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Select Terminal App"
        panel.message = "Choose a macOS terminal application (e.g. Terminal.app, iTerm.app, Ghostty.app, Warp.app)."
        if panel.runModal() == .OK, let url = panel.url {
            settings.customTerminalAppPath = url.path
            saveSettings()
            showBanner("System console set to \(SystemTerminalLauncher.displayName(forAppAt: url))")
        }
    }

    var workspaceRelativeDirectories: [String] {
        guard let workspace else { return [] }
        var dirs: [String] = []
        for node in workspace.rootTree {
            dirs.append(contentsOf: node.allDirectoryRelativePaths())
        }
        return Array(Set(dirs)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var activeFileParentRelativeDirectory: String? {
        guard let rel = activeTab?.relativePath, !rel.hasPrefix("/") else { return nil }
        let dir = (rel as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }

    // MARK: - Workspace Management

    func openWorkspacePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open CodeceptJS Workspace"
        panel.message = "Select a CodeceptJS project folder containing codecept.conf.* or test files."
        if panel.runModal() == .OK, let url = panel.url {
            openWorkspace(at: url)
        }
    }

    func createSampleWorkspacePanel() {
        let panel = NSSavePanel()
        panel.title = "Create Sample CodeceptJS 4.x Workspace"
        panel.prompt = "Create Workspace"
        panel.nameFieldStringValue = "my-codeceptjs-tests"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try ProjectScaffolder.createSampleWorkspace(at: url)
                openWorkspace(at: url)
                showBanner("Created starter CodeceptJS 4.x workspace at \(url.lastPathComponent)")
            } catch {
                showBanner("Could not scaffold workspace: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func openWorkspace(at rootURL: URL) {
        stopCodeceptUIServer()
        let savedConfigPath = settings.customConfigPath(forWorkspaceRoot: rootURL.path)
        let scanned = WorkspaceScanner.scan(rootURL: rootURL, customConfigPath: savedConfigPath)
        workspace = scanned
        completionIndex = IntelliSenseEngine.buildWorkspaceIndex(workspace: scanned)
        openTabs = []
        activeTabPath = nil
        navigationBackStack = []
        navigationForwardStack = []
        liveParsedFeaturesByPath = [:]
        liveScenarioStatuses = [:]
        liveScenarioDurations = [:]
        liveReplaySteps = []
        selectedTagFilter = nil

        settings.recordRecentProject(scanned.rootURL.path)
        settingsStore.save(settings)

        runHistory = historyStore.loadHistory(forProjectPath: scanned.rootURL.path)
        selectedReportID = runHistory.first?.id
        refreshSelectedReplayTrace()
        loadDebugStateForWorkspace(rootPath: scanned.rootURL.path)
        refreshArtifacts()

        // Auto-open first test file or config file for immediate productivity
        if let firstTest = scanned.testFiles.first {
            openFile(firstTest)
        } else if let configPath = scanned.config.configFilePath,
                  let configFile = scanned.files.first(where: { $0.path == configPath }) {
            openFile(configFile)
        }
    }

    func rescanWorkspace() {
        guard let root = workspace?.rootURL else { return }
        let savedConfigPath = settings.customConfigPath(forWorkspaceRoot: root.path)
        var scanned = WorkspaceScanner.scan(rootURL: root, customConfigPath: savedConfigPath)
        if !scanned.config.isCustomConfigOverride,
           let activeTabPath {
            let matched = scanned.resolvedConfig(forFilePath: activeTabPath)
            if matched.configFilePath != scanned.config.configFilePath {
                scanned = scanned.withActiveConfig(matched)
            }
        }
        workspace = scanned
        completionIndex = IntelliSenseEngine.buildWorkspaceIndex(workspace: scanned)
        refreshArtifacts()
    }

    private func syncAutoConfig(forFilePath filePath: String) {
        guard let workspace,
              !workspace.config.isCustomConfigOverride,
              workspace.discoveredConfigs.count > 1 else {
            return
        }
        let matched = workspace.resolvedConfig(forFilePath: filePath)
        guard matched.configFilePath != workspace.config.configFilePath else { return }
        let updated = workspace.withActiveConfig(matched)
        self.workspace = updated
        self.completionIndex = IntelliSenseEngine.buildWorkspaceIndex(workspace: updated)
        self.refreshArtifacts()
    }

    func effectiveConfig(for mode: CodeceptRunMode, in workspace: CodeceptWorkspace) -> CodeceptConfigSummary {
        guard let targetPath = mode.targetFilePath else {
            return workspace.config
        }
        return workspace.resolvedConfig(forFilePath: targetPath)
    }

    func selectCustomConfigPanel() {
        guard let root = workspace?.rootURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = "Use CodeceptJS Config"
        panel.message = "Select any CodeceptJS configuration file (.ts, .js, .cjs, .mjs, .json)."
        panel.allowedContentTypes = [
            .javaScript,
            .json,
            UTType(filenameExtension: "ts") ?? .sourceCode,
            UTType(filenameExtension: "cjs") ?? .sourceCode,
            UTType(filenameExtension: "mjs") ?? .sourceCode,
            UTType(filenameExtension: "mts") ?? .sourceCode,
            UTType(filenameExtension: "cts") ?? .sourceCode
        ]
        if panel.runModal() == .OK, let url = panel.url {
            setCustomConfigFile(path: url.path)
        }
    }

    func setCustomConfigFile(path: String?) {
        guard let root = workspace?.rootURL else { return }
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let resolved = ConfigParser.resolveConfigURL(customPath: path, relativeTo: root) else {
                showBanner("Config file not found: \(path)", isError: true)
                return
            }
            let storedValue: String
            let rootPrefix = root.standardizedFileURL.path.hasSuffix("/")
                ? root.standardizedFileURL.path
                : root.standardizedFileURL.path + "/"
            if resolved.path.hasPrefix(rootPrefix) {
                storedValue = String(resolved.path.dropFirst(rootPrefix.count))
            } else {
                storedValue = resolved.path
            }
            settings.setCustomConfigPath(storedValue, forWorkspaceRoot: root.path)
            settingsStore.save(settings)
            rescanWorkspace()
            showBanner("Active config: \(storedValue)")
        } else {
            settings.setCustomConfigPath(nil, forWorkspaceRoot: root.path)
            settingsStore.save(settings)
            rescanWorkspace()
            let detected = workspace?.config.displayConfigPath(relativeTo: root) ?? "none"
            showBanner("Reset config to auto-detect (\(detected))")
        }
    }

    func openActiveConfigFile() {
        guard let configPath = workspace?.config.configFilePath else { return }
        if let file = workspace?.files.first(where: { $0.path == configPath }) {
            openFile(file)
            return
        }
        let url = URL(fileURLWithPath: configPath).standardizedFileURL
        let file = WorkspaceFile(
            path: url.path,
            relativePath: url.path,
            name: url.lastPathComponent,
            fileExtension: url.pathExtension.lowercased(),
            category: .config
        )
        openFile(file)
    }

    var activeWorkspaceCustomConfigSetting: String {
        guard let root = workspace?.rootURL else { return "" }
        return settings.customConfigPath(forWorkspaceRoot: root.path) ?? ""
    }

    func refreshArtifacts() {
        guard let workspace else {
            artifacts = []
            return
        }
        let outputURL = workspace.config.resolvedOutputURL(rootURL: workspace.rootURL)
        artifacts = ArtifactScanner.scan(outputDirectoryURL: outputURL)
    }

    // MARK: - File & Editor Tabs

    func openFile(_ file: WorkspaceFile, jumpToLine: Int? = nil) {
        if file.isBinaryFile {
            NSWorkspace.shared.open(file.url)
            showBanner("Opened \(file.name) in default macOS app")
            return
        }
        if let existing = openTabs.first(where: { $0.filePath == file.path }) {
            activeTabPath = existing.filePath
            syncAutoConfig(forFilePath: existing.filePath)
            if let jumpToLine {
                pendingJumpToLine = jumpToLine
            }
            if workspaceMode == .reports {
                workspaceMode = .split
            }
            return
        }

        let content = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        let tab = OpenDocumentTab(
            filePath: file.path,
            relativePath: file.relativePath,
            name: file.name,
            language: file.languageHint,
            category: file.category,
            content: content,
            savedContent: content
        )
        openTabs.append(tab)
        activeTabPath = tab.filePath
        syncAutoConfig(forFilePath: tab.filePath)
        if file.isExecutableTestFile {
            liveParsedFeaturesByPath[file.path] = TestFileParser.parse(content: content, filePath: file.path)
        }
        if let jumpToLine {
            pendingJumpToLine = jumpToLine
        }
        if workspaceMode == .reports {
            workspaceMode = .split
        }
    }

    func switchTab(to filePath: String) {
        guard openTabs.contains(where: { $0.filePath == filePath }) else { return }
        if activeTabPath != filePath {
            activeTabPath = filePath
        }
        syncAutoConfig(forFilePath: filePath)
        if workspaceMode == .reports {
            workspaceMode = .split
        }
    }

    func selectAdjacentTab(offset: Int) {
        guard openTabs.count > 1,
              let activeTabPath,
              let idx = openTabs.firstIndex(where: { $0.filePath == activeTabPath }) else { return }
        let next = (idx + offset + openTabs.count) % openTabs.count
        switchTab(to: openTabs[next].filePath)
    }

    @discardableResult
    func moveTab(filePath: String, toIndex: Int) -> Bool {
        guard let fromIndex = openTabs.firstIndex(where: { $0.filePath == filePath }) else {
            return false
        }
        return TabReorderEngine.move(&openTabs, fromIndex: fromIndex, toIndex: toIndex)
    }

    func closeTab(filePath: String) {
        guard let idx = openTabs.firstIndex(where: { $0.filePath == filePath }) else { return }
        openTabs.remove(at: idx)
        if activeTabPath == filePath {
            activeTabPath = openTabs.isEmpty ? nil : openTabs[max(0, idx - 1)].filePath
            if let nextPath = activeTabPath {
                syncAutoConfig(forFilePath: nextPath)
            }
        }
    }

    func navigateToImportTarget(_ target: NavigationTarget, fromLine: Int) {
        if let currentPath = activeTabPath {
            navigationBackStack.append(NavigationHistoryEntry(filePath: currentPath, lineNumber: max(1, fromLine)))
            if navigationBackStack.count > 40 {
                navigationBackStack.removeFirst()
            }
            navigationForwardStack.removeAll()
        }
        openFileByURL(target.fileURL, jumpToLine: target.lineNumber)
        let symBadge = target.isSymlink ? " (via symlink)" : ""
        let formattedLabel: String
        if let line = target.lineNumber, !target.displayLabel.hasSuffix(":\(line)") {
            formattedLabel = "\(target.displayLabel):\(line)"
        } else {
            formattedLabel = target.displayLabel
        }
        let prefix = target.kind == .usage ? "Jumped to usage in" : "Opened"
        showBanner("\(prefix) \(formattedLabel)\(symBadge)")
    }

    func navigateBack() {
        guard let entry = navigationBackStack.popLast() else { return }
        if let currentPath = activeTabPath {
            navigationForwardStack.append(NavigationHistoryEntry(filePath: currentPath, lineNumber: max(1, cursorLine)))
        }
        openFileByURL(URL(fileURLWithPath: entry.filePath), jumpToLine: entry.lineNumber)
    }

    func navigateForward() {
        guard let entry = navigationForwardStack.popLast() else { return }
        if let currentPath = activeTabPath {
            navigationBackStack.append(NavigationHistoryEntry(filePath: currentPath, lineNumber: max(1, cursorLine)))
        }
        openFileByURL(URL(fileURLWithPath: entry.filePath), jumpToLine: entry.lineNumber)
    }

    func openFileByURL(_ fileURL: URL, jumpToLine: Int? = nil) {
        let stdURL = fileURL.standardizedFileURL
        if let existing = workspace?.files.first(where: { $0.path == stdURL.path }) {
            openFile(existing, jumpToLine: jumpToLine)
            return
        }
        let relPath: String
        if let root = workspace?.rootURL {
            let prefix = root.standardizedFileURL.path.hasSuffix("/")
                ? root.standardizedFileURL.path
                : root.standardizedFileURL.path + "/"
            relPath = stdURL.path.hasPrefix(prefix) ? String(stdURL.path.dropFirst(prefix.count)) : stdURL.path
        } else {
            relPath = stdURL.path
        }
        let ext = stdURL.pathExtension.lowercased()
        let content = (try? String(contentsOf: stdURL, encoding: .utf8)) ?? ""
        let parsedFeatures: [ParsedFeature]
        if ["js", "ts", "mjs", "cjs", "mts", "cts", "feature"].contains(ext) {
            parsedFeatures = TestFileParser.parse(content: content, filePath: stdURL.path)
        } else {
            parsedFeatures = []
        }
        let inferredCategory: WorkspaceFileCategory
        if !parsedFeatures.isEmpty {
            inferredCategory = (ext == "feature") ? .gherkinFeature : .testSuite
        } else {
            inferredCategory = .other
        }
        let synthetic = WorkspaceFile(
            path: stdURL.path,
            relativePath: relPath,
            name: stdURL.lastPathComponent,
            fileExtension: ext,
            category: inferredCategory,
            features: parsedFeatures
        )
        openFile(synthetic, jumpToLine: jumpToLine)
    }

    func updateTabContent(filePath: String, newText: String) {
        guard let idx = openTabs.firstIndex(where: { $0.filePath == filePath }) else { return }
        guard openTabs[idx].content != newText else { return }
        openTabs[idx].content = newText

        let cat = openTabs[idx].category
        if cat == .testSuite || cat == .gherkinFeature || cat == .other {
            let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
            if ["js", "ts", "mjs", "cjs", "mts", "cts", "feature"].contains(ext) {
                liveParsedFeaturesByPath[filePath] = TestFileParser.parse(content: newText, filePath: filePath)
            }
        }
    }

    func updateActiveTabContent(_ newText: String) {
        guard let activeTabPath else { return }
        updateTabContent(filePath: activeTabPath, newText: newText)
    }

    func insertSnippet(_ snippet: CodeSnippetItem) {
        guard let activeTabPath,
              let idx = openTabs.firstIndex(where: { $0.filePath == activeTabPath }) else { return }
        let separator = openTabs[idx].content.hasSuffix("\n") ? "\n" : "\n\n"
        let updated = openTabs[idx].content + separator + snippet.body + "\n"
        updateActiveTabContent(updated)
    }

    func saveActiveFile() {
        guard let activeTabPath,
              let idx = openTabs.firstIndex(where: { $0.filePath == activeTabPath }) else { return }
        saveTab(at: idx)
    }

    func triggerEditorFold(_ action: EditorFoldAction) {
        guard activeTab != nil else { return }
        pendingEditorFoldAction = action
        editorFoldActionTrigger += 1
    }

    func saveAllDirtyFiles() {
        for idx in openTabs.indices where openTabs[idx].isDirty {
            saveTab(at: idx)
        }
    }

    private func saveTab(at idx: Int) {
        let tab = openTabs[idx]
        do {
            try tab.content.write(toFile: tab.filePath, atomically: true, encoding: .utf8)
            openTabs[idx].savedContent = tab.content
            rescanWorkspace()
            showBanner("Saved \(tab.name)")
        } catch {
            showBanner("Failed to save \(tab.name): \(error.localizedDescription)", isError: true)
        }
    }

    func presentNewFileSheet(inDirectory relativeDirectory: String? = nil) {
        newFileInitialDirectory = relativeDirectory
        showingNewFileSheet = true
    }

    func presentNewFolderSheet(inDirectory relativeDirectory: String? = nil) {
        newFolderInitialDirectory = relativeDirectory
        showingNewFolderSheet = true
    }

    func presentParallelRunSheet(tab: ParallelRunTab) {
        parallelRunSheetTab = tab
        showingParallelRunSheet = true
    }

    @discardableResult
    func createNewFile(kind: ScaffoldTemplateKind, name: String, directory: String) -> String? {
        guard let root = workspace?.rootURL else { return "Open a workspace first." }
        do {
            let created = try ProjectScaffolder.createFile(
                workspaceRoot: root,
                relativeDirectory: directory,
                name: name,
                kind: kind
            )
            rescanWorkspace()
            pendingRevealTreePath = created.url.path
            if let newlyScanned = workspace?.files.first(where: { $0.path == created.url.path }) {
                openFile(newlyScanned)
            } else {
                openFileByURL(created.url)
            }
            showBanner("Created \(created.relativePath)")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @discardableResult
    func createNewFolder(name: String, directory: String) -> String? {
        guard let root = workspace?.rootURL else { return "Open a workspace first." }
        do {
            let created = try ProjectScaffolder.createFolder(
                workspaceRoot: root,
                relativeDirectory: directory,
                folderName: name
            )
            rescanWorkspace()
            pendingRevealTreePath = created.url.path
            showBanner("Created folder \(created.relativePath)/")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func runWorkersWithCurrentOptions() {
        run(mode: .runWorkers(
            count: runOptions.workerCount,
            strategy: runOptions.workerStrategy,
            selectedRuns: runOptions.workerSelectedRuns,
            serialPattern: runOptions.workerSerialPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : runOptions.workerSerialPattern,
            lastFailed: runOptions.workerLastFailed
        ))
    }

    func runMultipleWithCurrentOptions() {
        run(mode: .runMultiple(
            suites: runOptions.multipleSelectedSuites,
            runAll: runOptions.multipleRunAll
        ))
    }

    // MARK: - Execution Engine

    func run(mode: CodeceptRunMode, debugLaunch: DebugLaunchOptions? = nil) {
        guard let workspace, let toolchain = resolvedToolchain else {
            showBanner("Open a CodeceptJS workspace first.", isError: true)
            return
        }
        guard !isRunning else {
            showBanner("A CodeceptJS run is already in progress.", isError: true)
            return
        }

        let isDebugSession = (debugLaunch?.enabled == true) && mode.supportsInteractiveDebugging
        if debugLaunch?.enabled == true && !mode.supportsInteractiveDebugging {
            showBanner("Step-through debugging is supported for single-process runs (Run File / Scenario / All), not parallel workers.", isError: true)
            return
        }
        if isDebugSession && toolchain.runtime == .bun {
            showBanner("Interactive CDP step-through debugging requires Node.js. Switch runtime to Node in the toolbar or Settings.", isError: true)
            return
        }

        saveAllDirtyFiles()

        let currentWorkspace = self.workspace ?? workspace
        let runConfig = effectiveConfig(for: mode, in: currentWorkspace)
        let didAutoSelectDifferentConfig = runConfig.configFilePath != currentWorkspace.config.configFilePath
        if didAutoSelectDifferentConfig && !currentWorkspace.config.isCustomConfigOverride {
            let syncedWorkspace = currentWorkspace.withActiveConfig(runConfig)
            self.workspace = syncedWorkspace
            self.completionIndex = IntelliSenseEngine.buildWorkspaceIndex(workspace: syncedWorkspace)
            self.refreshArtifacts()
        }

        // Launch directly in the system's default (or chosen) terminal app when System Console mode is enabled
        if settings.consoleExecutionMode == .systemTerminal && !isDebugSession {
            let command = CommandBuilder.build(
                mode: mode,
                options: runOptions,
                workspaceRoot: currentWorkspace.rootURL,
                configFilePath: runConfig.configFilePath,
                toolchain: toolchain,
                debugOptions: nil,
                traceOutputDirectory: nil,
                colorOutput: true
            )
            lastCommandLine = command.displayCommand
            do {
                let terminalName = try SystemTerminalLauncher.launch(
                    command: command,
                    runtime: toolchain.runtime,
                    title: mode.displayLabel,
                    toolchain: toolchain,
                    preferredAppPath: settings.customTerminalAppPath
                )
                consoleLogs.append(ConsoleLogEntry(
                    timestamp: Date(),
                    text: "↗ [\(terminalName) · \(toolchain.runtime.displayName)] $ \(command.displayCommand)",
                    isError: false,
                    isStep: false,
                    isHighlight: true
                ))
                showBanner("Launched \(mode.displayLabel) in \(terminalName) (\(toolchain.runtime.shortName))")
            } catch {
                consoleLogs.append(ConsoleLogEntry(
                    timestamp: Date(),
                    text: "System console launch failed: \(error.localizedDescription)",
                    isError: true,
                    isStep: false,
                    isHighlight: false
                ))
                showBanner("Could not launch system console: \(error.localizedDescription)", isError: true)
            }
            return
        }

        if toolchain.runtime == .bun && !toolchain.isActiveRuntimeAvailable {
            let msg = "Bun executable was not found in PATH. Install Bun (https://bun.sh), set Custom Bun Path in Settings, or switch runtime to Node.js."
            isConsoleVisible = true
            consoleLogs.append(ConsoleLogEntry(
                timestamp: Date(),
                text: msg,
                isError: true,
                isStep: false,
                isHighlight: false
            ))
            showBanner("Bun executable not found. Configure Bun in Settings or switch to Node.js.", isError: true)
            return
        }

        let outputURL = runConfig.resolvedOutputURL(rootURL: currentWorkspace.rootURL)
        let projectPath = currentWorkspace.rootURL.path
        let projectName = runConfig.projectName

        let shouldRecordHistory: Bool
        switch mode {
        case .runAll, .runFile, .runScenario, .runTag, .runLastFailed, .runWorkers, .runMultiple:
            shouldRecordHistory = true
        case .dryRun, .checkEnvironment, .generateDefinitions, .listActions:
            shouldRecordHistory = false
        }

        let reportID = UUID()
        let runTraceDirectory: URL? = (shouldRecordHistory && runOptions.timeTravelTrace)
            ? outputURL.appendingPathComponent(".ceptra-traces/\(reportID.uuidString)", isDirectory: true)
            : nil
        if let runTraceDirectory {
            try? FileManager.default.createDirectory(at: runTraceDirectory, withIntermediateDirectories: true)
        }

        let command = CommandBuilder.build(
            mode: mode,
            options: runOptions,
            workspaceRoot: currentWorkspace.rootURL,
            configFilePath: runConfig.configFilePath,
            toolchain: toolchain,
            debugOptions: isDebugSession ? debugLaunch : nil,
            traceOutputDirectory: runTraceDirectory
        )

        isRunning = true
        isConsoleVisible = true
        isInteractivePauseShellActive = false
        liveReplaySteps = []
        if isDebugSession {
            lastDebugMode = mode
            debugPhase = .launching
            isDebugInspectorVisible = true
            isRightSidebarVisible = true
            activeRightTab = .debug
            debugCallFrames = []
            selectedCallFrameID = nil
            debugScopeVariables = [:]
            hasHandledInitialBreakOnStart = false
        } else if shouldRecordHistory && settings.modulePreferences.autoOpenReplayOnRun {
            isRightSidebarVisible = true
            activeRightTab = .replay
            persistModulePreferences()
        }
        activeRunLabel = isDebugSession ? "Debug: \(mode.displayLabel)" : mode.displayLabel
        lastCommandLine = command.displayCommand
        var initialLogs: [ConsoleLogEntry] = []
        if didAutoSelectDifferentConfig,
           let displayCfg = runConfig.displayConfigPath(relativeTo: currentWorkspace.rootURL) {
            initialLogs.append(ConsoleLogEntry(
                timestamp: Date(),
                text: "↳ Auto-selected owning config: \(displayCfg)",
                isError: false,
                isStep: false,
                isHighlight: false
            ))
        }
        initialLogs.append(ConsoleLogEntry(
            timestamp: Date(),
            text: "$ \(command.displayCommand)",
            isError: false,
            isStep: false,
            isHighlight: true
        ))
        consoleLogs = initialLogs
        activeRunningScenarioKey = nil

        switch mode {
        case .runAll, .runWorkers, .runMultiple:
            liveScenarioStatuses = [:]
            liveScenarioDurations = [:]
        default:
            break
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.runnerService.execute(command: command, attachStdin: true) { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleLiveEvent(event)
                    }
                }

                // Prefer rich CodeceptJS 4.x JUnit XML reports if freshly generated during this run
                // (merges multiple XML files produced by run-multiple browser forks)
                var finalScenarios = result.parsedScenarios
                let freshXMLs = ArtifactScanner.freshJUnitXMLs(in: outputURL, modifiedAfter: result.startedAt)
                if !freshXMLs.isEmpty {
                    let xmlRecords = freshXMLs.flatMap { JUnitReportParser.parse(fileURL: $0) }
                    if !xmlRecords.isEmpty {
                        finalScenarios = xmlRecords
                        for rec in xmlRecords {
                            let key = Self.scenarioStatusKey(feature: rec.featureTitle, scenario: rec.scenarioTitle)
                            self.liveScenarioStatuses[key] = rec.status
                            self.liveScenarioDurations[key] = rec.durationMs
                        }
                    }
                }

                // Ingest per-step time-travel telemetry captured by the Ceptra plugin
                let traceScenarios: [ExecutedScenarioRecord]
                if let runTraceDirectory {
                    traceScenarios = TimeTravelTraceMerger.loadWorkerTraces(from: runTraceDirectory)
                    try? FileManager.default.removeItem(at: runTraceDirectory)
                } else {
                    traceScenarios = []
                }

                finalScenarios = TimeTravelTraceMerger.merge(
                    primaryScenarios: finalScenarios,
                    traceScenarios: traceScenarios,
                    runStartedAt: result.startedAt
                )

                let passed = result.summaryPassed ?? finalScenarios.filter { $0.status == .passed }.count
                let failed = result.summaryFailed ?? finalScenarios.filter { $0.status == .failed }.count
                let skipped = result.summarySkipped ?? finalScenarios.filter { $0.status == .skipped }.count
                let totalMs = max(1, Int((result.finishedAt.timeIntervalSince(result.startedAt) * 1000.0).rounded()))

                if shouldRecordHistory {
                    let hasRichDiagnostics = finalScenarios.contains { sc in
                        sc.steps.contains { step in
                            step.diagnostics?.isEmpty == false
                        }
                    }
                    let bundle: TimeTravelTraceBundle? = hasRichDiagnostics
                        ? TimeTravelTraceBundle(reportID: reportID, scenarios: finalScenarios)
                        : nil
                    let savedTraceURL = bundle.flatMap { self.traceStore.save(bundle: $0) }

                    let autoHTMLURL = outputURL.appendingPathComponent("ceptra-time-travel-report.html")
                    let provisionalReport = TestRunReport(
                        id: reportID,
                        projectPath: projectPath,
                        projectName: projectName,
                        label: mode.displayLabel,
                        commandLine: command.displayCommand,
                        startedAt: result.startedAt,
                        finishedAt: result.finishedAt,
                        exitCode: result.exitCode,
                        wasCancelled: result.wasCancelled,
                        passedCount: passed,
                        failedCount: failed,
                        skippedCount: skipped,
                        durationMs: totalMs,
                        scenarios: finalScenarios,
                        rawOutput: result.rawOutput,
                        traceBundlePath: savedTraceURL?.path,
                        htmlReportPath: autoHTMLURL.path
                    )

                    try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
                    let interactiveHTML = ReportExporter.toHTML(provisionalReport, traceBundle: bundle)
                    let wroteHTML = (try? interactiveHTML.write(to: autoHTMLURL, atomically: true, encoding: .utf8)) != nil

                    let report = TestRunReport(
                        id: reportID,
                        projectPath: projectPath,
                        projectName: projectName,
                        label: mode.displayLabel,
                        commandLine: command.displayCommand,
                        startedAt: result.startedAt,
                        finishedAt: result.finishedAt,
                        exitCode: result.exitCode,
                        wasCancelled: result.wasCancelled,
                        passedCount: passed,
                        failedCount: failed,
                        skippedCount: skipped,
                        durationMs: totalMs,
                        scenarios: finalScenarios,
                        rawOutput: result.rawOutput,
                        traceBundlePath: savedTraceURL?.path,
                        htmlReportPath: wroteHTML ? autoHTMLURL.path : nil
                    )

                    self.runHistory = self.historyStore.append(report)
                    self.traceStore.prune(keepingReportIDs: Set(self.runHistory.map(\.id)))
                    self.selectedReportID = report.id
                    self.activeReplayTraceBundle = bundle
                }

                self.isRunning = false
                self.activeRunningScenarioKey = nil
                self.cleanupDebugSession()
                self.refreshArtifacts()

                if case .generateDefinitions = mode {
                    self.rescanWorkspace()
                }

                if result.wasCancelled {
                    self.showBanner("Execution cancelled.")
                } else if result.exitCode == 0 {
                    self.showBanner("\(mode.displayLabel) succeeded (\(passed) passed in \(ReportExporter.formatDuration(ms: totalMs))).")
                } else {
                    self.showBanner("\(mode.displayLabel) finished with exit code \(result.exitCode) (\(failed) failed).", isError: true)
                }
            } catch {
                self.isRunning = false
                self.activeRunningScenarioKey = nil
                self.cleanupDebugSession()
                self.consoleLogs.append(ConsoleLogEntry(
                    timestamp: Date(),
                    text: "Execution error: \(error.localizedDescription)",
                    isError: true,
                    isStep: false,
                    isHighlight: false
                ))
                self.showBanner("Could not start CodeceptJS: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func runActiveFile() {
        guard isActiveTabExecutableTestFile, let tab = activeTab else {
            showBanner("Select a CodeceptJS test file containing Feature() or Scenario() to run.", isError: true)
            return
        }
        let targetRel = activeWorkspaceFile?.relativePath ?? tab.relativePath
        run(mode: .runFile(relativePath: targetRel))
    }

    func runDependencyAction(_ action: DependencyAction) {
        guard let workspace, let toolchain = resolvedToolchain else {
            showBanner("Open a workspace first.", isError: true)
            return
        }
        guard !isRunning else {
            showBanner("Another command is already running. Stop it first (⌘.).", isError: true)
            return
        }

        if case .customShell(let raw) = action {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            commandHistory.removeAll { $0 == trimmed }
            commandHistory.insert(trimmed, at: 0)
            if commandHistory.count > 40 {
                commandHistory = Array(commandHistory.prefix(40))
            }
            commandInputText = ""
        }

        if settings.consoleExecutionMode == .systemTerminal {
            let command = PackageManagerSupport.buildCommand(
                action: action,
                packageManager: workspace.packageManager,
                workspaceRoot: workspace.rootURL,
                toolchain: toolchain,
                extraEnv: runOptions.environmentVariables,
                colorOutput: true
            )
            lastCommandLine = command.displayCommand
            do {
                let terminalName = try SystemTerminalLauncher.launch(
                    command: command,
                    runtime: toolchain.runtime,
                    title: action.displayTitle,
                    toolchain: toolchain,
                    preferredAppPath: settings.customTerminalAppPath
                )
                consoleLogs.append(ConsoleLogEntry(
                    timestamp: Date(),
                    text: "↗ [\(terminalName)] $ \(command.displayCommand)",
                    isError: false,
                    isStep: false,
                    isHighlight: true
                ))
                showBanner("Launched \(action.displayTitle) in \(terminalName)")
            } catch {
                consoleLogs.append(ConsoleLogEntry(
                    timestamp: Date(),
                    text: "System console launch failed: \(error.localizedDescription)",
                    isError: true,
                    isStep: false,
                    isHighlight: false
                ))
                showBanner("Could not launch system console: \(error.localizedDescription)", isError: true)
            }
            return
        }

        let command = PackageManagerSupport.buildCommand(
            action: action,
            packageManager: workspace.packageManager,
            workspaceRoot: workspace.rootURL,
            toolchain: toolchain,
            extraEnv: runOptions.environmentVariables
        )

        isRunning = true
        isConsoleVisible = true
        activeRunLabel = action.displayTitle
        lastCommandLine = command.displayCommand
        consoleLogs.append(ConsoleLogEntry(
            timestamp: Date(),
            text: "$ \(command.displayCommand)",
            isError: false,
            isStep: false,
            isHighlight: true
        ))

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.runnerService.execute(command: command) { [weak self] event in
                    Task { @MainActor [weak self] in
                        if case .logLine(let text, let isError) = event {
                            self?.consoleLogs.append(ConsoleLogEntry(
                                timestamp: Date(),
                                text: text,
                                isError: isError,
                                isStep: false,
                                isHighlight: false
                            ))
                            if let count = self?.consoleLogs.count, count > 4000 {
                                self?.consoleLogs.removeFirst(500)
                            }
                        }
                    }
                }

                let totalMs = max(1, Int((result.finishedAt.timeIntervalSince(result.startedAt) * 1000.0).rounded()))
                self.isRunning = false
                // Rescan workspace so newly updated packages, CodeceptJS versions, scripts, or steps.d.ts take effect immediately
                self.rescanWorkspace()

                if result.wasCancelled {
                    self.showBanner("Command cancelled.")
                } else if result.exitCode == 0 {
                    self.showBanner("\(action.displayTitle) completed in \(ReportExporter.formatDuration(ms: totalMs)).")
                } else {
                    self.showBanner("\(action.displayTitle) exited with code \(result.exitCode).", isError: true)
                }
            } catch {
                self.isRunning = false
                self.consoleLogs.append(ConsoleLogEntry(
                    timestamp: Date(),
                    text: "Command failed: \(error.localizedDescription)",
                    isError: true,
                    isStep: false,
                    isHighlight: false
                ))
                self.showBanner("Could not run command: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func focusConsoleCommandPrompt() {
        isConsoleVisible = true
        focusCommandInputTrigger += 1
    }

    func stopActiveRun() {
        if debugPhase.isActive {
            debugPhase = .stopping
        }
        cleanupDebugSession()
        runnerService.cancel()
    }

    func clearConsole() {
        consoleLogs = []
    }

    func statusForScenario(_ scenario: ParsedScenario) -> ExecutionStatus {
        let exact = Self.scenarioStatusKey(feature: scenario.featureTitle, scenario: scenario.title)
        if let st = liveScenarioStatuses[exact] { return st }
        let clean = Self.scenarioStatusKey(feature: scenario.featureTitle, scenario: scenario.cleanTitle)
        if let st = liveScenarioStatuses[clean] { return st }
        if activeRunningScenarioKey == exact || activeRunningScenarioKey == clean {
            return .running
        }
        return .idle
    }

    func durationForScenario(_ scenario: ParsedScenario) -> Int? {
        let exact = Self.scenarioStatusKey(feature: scenario.featureTitle, scenario: scenario.title)
        if let ms = liveScenarioDurations[exact] { return ms }
        let clean = Self.scenarioStatusKey(feature: scenario.featureTitle, scenario: scenario.cleanTitle)
        return liveScenarioDurations[clean]
    }

    private func handleLiveEvent(_ event: LiveOutputEvent) {
        switch event {
        case .logLine(let text, let isError):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let isStep = text.hasPrefix("    ") && !trimmed.isEmpty
            let isHighlight = trimmed.hasPrefix("✔") || trimmed.hasPrefix("✖") || trimmed.hasPrefix("OK |") || trimmed.hasPrefix("FAIL |")
            consoleLogs.append(ConsoleLogEntry(
                timestamp: Date(),
                text: text,
                isError: isError,
                isStep: isStep,
                isHighlight: isHighlight
            ))
            if consoleLogs.count > 4000 {
                consoleLogs.removeFirst(500)
            }

        case .suiteStarted:
            break

        case .scenarioStarted(let feature, let scenario):
            let key = Self.scenarioStatusKey(feature: feature, scenario: scenario)
            activeRunningScenarioKey = key
            liveScenarioStatuses[key] = .running

        case .stepLogged(let text, let depth):
            liveReplaySteps.append(
                ExecutedStepRecord(
                    text: text,
                    depth: depth,
                    status: .passed,
                    startedAt: Date()
                )
            )
            if liveReplaySteps.count > 400 {
                liveReplaySteps.removeFirst(50)
            }

        case .scenarioFinished(let record):
            let key = Self.scenarioStatusKey(feature: record.featureTitle, scenario: record.scenarioTitle)
            liveScenarioStatuses[key] = record.status
            liveScenarioDurations[key] = record.durationMs
            if activeRunningScenarioKey == key {
                activeRunningScenarioKey = nil
            }

        case .summary:
            isInteractivePauseShellActive = false

        case .inspectorListening(let url):
            if debugPhase == .launching {
                attachInspector(to: url)
            }

        case .inspectorWaitingToDisconnect:
            cleanupDebugSession()

        case .interactiveShellState(let active):
            isInteractivePauseShellActive = active
            if active {
                isConsoleVisible = true
                if debugPhase == .running || debugPhase == .launching {
                    debugPhase = .interactiveShell
                }
                focusCommandInputTrigger += 1
            } else if debugPhase == .interactiveShell {
                debugPhase = .running
            }
        }
    }

    static func scenarioStatusKey(feature: String, scenario: String) -> String {
        "\(feature.lowercased().trimmingCharacters(in: .whitespaces))::\(scenario.lowercased().trimmingCharacters(in: .whitespaces))"
    }

    // MARK: - Report Export

    private func loadTraceBundle(for report: TestRunReport) -> TimeTravelTraceBundle? {
        if let path = report.traceBundlePath, let loaded = traceStore.load(path: path) {
            return loaded
        }
        return traceStore.load(reportID: report.id)
    }

    func openSelectedTimeTravelReport() {
        guard let report = selectedReport else { return }
        let bundle = loadTraceBundle(for: report)
        let html = ReportExporter.toHTML(report, traceBundle: bundle)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceptra-reports", isDirectory: true)
        let targetURL = tempDir.appendingPathComponent("ceptra-time-travel-\(report.id.uuidString).html")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try html.write(to: targetURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(targetURL)
        } catch {
            showBanner("Could not open Time-Travel report: \(error.localizedDescription)", isError: true)
        }
    }

    func exportSelectedReport(asHTML: Bool) {
        guard let report = selectedReport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [asHTML ? .html : .plainText]
        panel.nameFieldStringValue = "ceptra-report-\(report.projectName).\(asHTML ? "html" : "md")"
        if panel.runModal() == .OK, let url = panel.url {
            let content = asHTML
                ? ReportExporter.toHTML(report, traceBundle: loadTraceBundle(for: report))
                : ReportExporter.toMarkdown(report)
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                showBanner("Exported report to \(url.lastPathComponent)")
            } catch {
                showBanner("Export failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func clearRunHistory() {
        guard let path = workspace?.rootURL.path else { return }
        historyStore.clearHistory(forProjectPath: path)
        runHistory = []
        selectedReportID = nil
    }

    // MARK: - Modular 3-Window Workspace & CodeceptUI Lifecycle

    var activeHelperDisplayName: String {
        guard let helpers = workspace?.config.helpers, !helpers.isEmpty else {
            return "CodeceptJS"
        }
        return helpers.first?.name ?? "CodeceptJS"
    }

    var isCodeceptUIInstalled: Bool {
        guard let root = workspace?.rootURL else { return false }
        return CodeceptUIServerManager.isInstalled(in: root)
    }

    func persistModulePreferences() {
        settings.modulePreferences.showLeftSidebar = isSidebarVisible
        settings.modulePreferences.showTerminal = isConsoleVisible
        settings.modulePreferences.showRightSidebar = isRightSidebarVisible
        settings.modulePreferences.showStatusBar = isStatusBarVisible
        settings.modulePreferences.activeRightTab = activeRightTab
        settingsStore.save(settings)
    }

    func toggleLeftSidebar() {
        isSidebarVisible.toggle()
        persistModulePreferences()
    }

    func toggleTerminal() {
        isConsoleVisible.toggle()
        persistModulePreferences()
    }

    func toggleRightSidebar() {
        isRightSidebarVisible.toggle()
        persistModulePreferences()
    }

    func setStatusBarVisible(_ visible: Bool) {
        isStatusBarVisible = visible
        persistModulePreferences()
    }

    func toggleStatusBar() {
        isStatusBarVisible.toggle()
        persistModulePreferences()
    }

    func setAutoOpenReplayOnRun(_ enabled: Bool) {
        settings.modulePreferences.autoOpenReplayOnRun = enabled
        settingsStore.save(settings)
    }

    func openRightTab(_ tab: RightInspectorTab) {
        activeRightTab = tab
        isRightSidebarVisible = true
        if tab == .debug {
            isDebugInspectorVisible = true
        }
        persistModulePreferences()
    }

    func toggleRightTab(_ tab: RightInspectorTab) {
        if isRightSidebarVisible && activeRightTab == tab {
            isRightSidebarVisible = false
            if tab == .debug {
                isDebugInspectorVisible = false
            }
        } else {
            activeRightTab = tab
            isRightSidebarVisible = true
            if tab == .debug {
                isDebugInspectorVisible = true
            }
        }
        persistModulePreferences()
    }

    func refreshSelectedReplayTrace() {
        guard let report = selectedReport else {
            activeReplayTraceBundle = nil
            return
        }
        activeReplayTraceBundle = loadTraceBundle(for: report)
    }

    func startCodeceptUIServer() {
        guard let workspace, let toolchain = resolvedToolchain else {
            showBanner("Open a CodeceptJS workspace first.", isError: true)
            return
        }
        guard !codeceptUIManager.isRunning else { return }

        codeceptUILogs = []
        do {
            let started = try codeceptUIManager.start(
                workspaceRoot: workspace.rootURL,
                customConfigPath: workspace.config.configFilePath,
                toolchain: toolchain,
                onOutput: { [weak self] line in
                    Task { @MainActor [weak self] in
                        self?.codeceptUILogs.append(line)
                        if let count = self?.codeceptUILogs.count, count > 250 {
                            self?.codeceptUILogs.removeFirst(50)
                        }
                    }
                },
                onExit: { [weak self] code in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if self.codeceptUIStatus.isActive {
                            if code == 0 || code == 15 {
                                self.codeceptUIStatus = .stopped
                            } else {
                                self.codeceptUIStatus = .failed(message: "@codeceptjs/ui exited with code \(code).")
                            }
                        }
                    }
                }
            )

            codeceptUIStatus = .starting(port: started.port)
            Task { [weak self] in
                guard let self else { return }
                let ready = await self.codeceptUIManager.waitForServerReady(url: started.url, timeoutSeconds: 18.0)
                if ready {
                    self.codeceptUIStatus = .running(url: started.url, port: started.port)
                } else if self.codeceptUIStatus == .starting(port: started.port) {
                    self.codeceptUIStatus = .failed(message: "Timed out waiting for @codeceptjs/ui on 127.0.0.1:\(started.port).")
                    self.codeceptUIManager.stop()
                }
            }
        } catch {
            codeceptUIStatus = .failed(message: error.localizedDescription)
            showBanner("Could not start @codeceptjs/ui: \(error.localizedDescription)", isError: true)
        }
    }

    func stopCodeceptUIServer() {
        codeceptUIManager.stop()
        codeceptUIStatus = .stopped
    }

    func restartCodeceptUIServer() {
        stopCodeceptUIServer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.startCodeceptUIServer()
        }
    }

    func installCodeceptUIPackage() {
        guard let workspace, let toolchain = resolvedToolchain else { return }
        let cmd = CodeceptUIServerManager.buildInstallCommand(
            packageManager: workspace.packageManager,
            workspaceRoot: workspace.rootURL,
            toolchain: toolchain
        )
        runDependencyAction(.customShell(command: cmd.displayCommand))
    }

    // MARK: - Settings

    func saveSettings() {
        settings.defaultRunOptions = runOptions
        persistModulePreferences()
    }

    // MARK: - GitHub Releases Auto-Updater

    func checkForUpdates(userInitiated: Bool) async {
        updateState = .checking
        do {
            let outcome = try await updateService.checkForUpdates(
                repository: settings.gitHubRepository,
                currentVersion: AppMetadata.currentSemanticVersion,
                includePrereleases: settings.includePrereleaseUpdates
            )
            switch outcome {
            case .updateAvailable(let release, let latestVersion, let asset):
                updateState = .available(release: release, latestVersion: latestVersion, asset: asset)
                if userInitiated {
                    showingUpdateSheet = true
                }
            case .upToDate(let current, _):
                updateState = .upToDate(current: current, checkedAt: Date())
            }
        } catch {
            if userInitiated {
                updateState = .failed(message: error.localizedDescription)
            } else {
                // Silent failure on automatic background check (e.g. offline or no release published yet)
                updateState = .idle
            }
        }
    }

    func downloadUpdate(release: GitHubRelease, asset: GitHubReleaseAsset) async {
        updateState = .downloading(release: release, asset: asset, progress: 0.0)
        do {
            let artifact = try await updateService.downloadAndVerify(
                release: release,
                asset: asset
            ) { [weak self] ratio in
                Task { @MainActor [weak self] in
                    self?.updateState = .downloading(release: release, asset: asset, progress: ratio)
                }
            }
            updateState = .readyToInstall(release: release, artifact: artifact)
        } catch {
            updateState = .failed(message: error.localizedDescription)
        }
    }

    func installDownloadedUpdateAndQuit(release: GitHubRelease, artifact: DownloadedUpdateArtifact) {
        updateState = .installing(release: release)
        let plan = UpdateInstallPlan(downloadedAssetURL: artifact.fileURL)
        do {
            try UpdateInstaller.launchDetachedInstaller(plan: plan)
            // Immediately close the running app so the detached installer can swap Ceptra.app and relaunch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            updateState = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Notifications

    func showBanner(_ message: String, isError: Bool = false) {
        bannerMessage = message
        bannerIsError = isError
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.bannerMessage == message {
                self?.bannerMessage = nil
            }
        }
    }
}
