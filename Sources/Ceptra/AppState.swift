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
    var content: String
    var savedContent: String

    var isDirty: Bool { content != savedContent }
}

struct ConsoleLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let text: String
    let isError: Bool
    let isStep: Bool
    let isHighlight: Bool
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
    @Published var workspaceMode: WorkspaceViewMode = .split
    @Published var sidebarFilterText: String = ""
    @Published var selectedTagFilter: String? = nil
    @Published var isSidebarVisible: Bool = true
    @Published var isConsoleVisible: Bool = true

    // Editor Tabs
    @Published var openTabs: [OpenDocumentTab] = []
    @Published var activeTabPath: String? = nil
    @Published var pendingJumpToLine: Int? = nil
    @Published var liveParsedFeaturesByPath: [String: [ParsedFeature]] = [:]

    // Execution & Live Status
    @Published var runOptions: RunOptions
    @Published var isRunning: Bool = false
    @Published var activeRunLabel: String = ""
    @Published var lastCommandLine: String = ""
    @Published var consoleLogs: [ConsoleLogEntry] = []
    @Published var liveScenarioStatuses: [String: ExecutionStatus] = [:]
    @Published var liveScenarioDurations: [String: Int] = [:]
    @Published var activeRunningScenarioKey: String? = nil

    // Reports & Artifacts
    @Published var runHistory: [TestRunReport] = []
    @Published var selectedReportID: UUID? = nil
    @Published var artifacts: [ReportArtifact] = []

    // Sheets, Notifications, Settings & Updates
    @Published var settings: AppSettings
    @Published var showingNewFileSheet: Bool = false
    @Published var showingUpdateSheet: Bool = false
    @Published var showingRunOptionsPopover: Bool = false
    @Published var bannerMessage: String? = nil
    @Published var bannerIsError: Bool = false
    @Published var updateState: AppUpdateState = .idle

    // Services
    private let settingsStore = AppSettingsStore()
    private let historyStore = RunHistoryStore()
    private let runnerService = TestRunnerService()
    private let updateService = UpdateService()

    init() {
        let loadedSettings = settingsStore.load()
        self.settings = loadedSettings
        self.runOptions = loadedSettings.defaultRunOptions

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
            customNodePath: settings.customNodePath,
            customCodeceptPath: settings.customCodeceptPath
        )
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
        let savedConfigPath = settings.customConfigPath(forWorkspaceRoot: rootURL.path)
        let scanned = WorkspaceScanner.scan(rootURL: rootURL, customConfigPath: savedConfigPath)
        workspace = scanned
        openTabs = []
        activeTabPath = nil
        liveParsedFeaturesByPath = [:]
        liveScenarioStatuses = [:]
        liveScenarioDurations = [:]
        selectedTagFilter = nil

        settings.recordRecentProject(scanned.rootURL.path)
        settingsStore.save(settings)

        runHistory = historyStore.loadHistory(forProjectPath: scanned.rootURL.path)
        selectedReportID = runHistory.first?.id
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
        workspace = WorkspaceScanner.scan(rootURL: root, customConfigPath: savedConfigPath)
        refreshArtifacts()
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
        if let existing = openTabs.first(where: { $0.filePath == file.path }) {
            activeTabPath = existing.filePath
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
            content: content,
            savedContent: content
        )
        openTabs.append(tab)
        activeTabPath = tab.filePath
        if file.category == .testSuite || file.category == .gherkinFeature {
            liveParsedFeaturesByPath[file.path] = TestFileParser.parse(content: content, filePath: file.path)
        }
        if let jumpToLine {
            pendingJumpToLine = jumpToLine
        }
        if workspaceMode == .reports {
            workspaceMode = .split
        }
    }

    func closeTab(filePath: String) {
        guard let idx = openTabs.firstIndex(where: { $0.filePath == filePath }) else { return }
        openTabs.remove(at: idx)
        if activeTabPath == filePath {
            activeTabPath = openTabs.isEmpty ? nil : openTabs[max(0, idx - 1)].filePath
        }
    }

    func updateActiveTabContent(_ newText: String) {
        guard let activeTabPath,
              let idx = openTabs.firstIndex(where: { $0.filePath == activeTabPath }) else { return }
        guard openTabs[idx].content != newText else { return }
        openTabs[idx].content = newText

        let ext = URL(fileURLWithPath: activeTabPath).pathExtension.lowercased()
        if ["js", "ts", "mjs", "cjs", "feature"].contains(ext) {
            liveParsedFeaturesByPath[activeTabPath] = TestFileParser.parse(content: newText, filePath: activeTabPath)
        }
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

    func createNewFile(kind: ScaffoldTemplateKind, name: String, directory: String) {
        guard let root = workspace?.rootURL else { return }
        let cleanDir = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetDir = cleanDir.isEmpty ? root : root.appendingPathComponent(cleanDir, isDirectory: true)
        let baseName = ProjectScaffolder.sanitizeIdentifier(name)
        let fileName: String
        if name.contains(".") {
            fileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let prefix = (kind == .pageObject) ? baseName : baseName.lowercased()
            fileName = prefix + kind.defaultExtension
        }

        let fileURL = targetDir.appendingPathComponent(fileName)
        let body = ProjectScaffolder.renderTemplate(kind: kind, name: name)
        do {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
            rescanWorkspace()
            if let newlyScanned = workspace?.files.first(where: { $0.path == fileURL.standardizedFileURL.path }) {
                openFile(newlyScanned)
            }
            showBanner("Created \(fileName)")
        } catch {
            showBanner("Failed to create file: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Execution Engine

    func run(mode: CodeceptRunMode) {
        guard let workspace, let toolchain = resolvedToolchain else {
            showBanner("Open a CodeceptJS workspace first.", isError: true)
            return
        }
        guard !isRunning else {
            showBanner("A CodeceptJS run is already in progress.", isError: true)
            return
        }

        saveAllDirtyFiles()

        let command = CommandBuilder.build(
            mode: mode,
            options: runOptions,
            workspaceRoot: workspace.rootURL,
            configFilePath: workspace.config.configFilePath,
            toolchain: toolchain
        )

        isRunning = true
        isConsoleVisible = true
        activeRunLabel = mode.displayLabel
        lastCommandLine = command.displayCommand
        consoleLogs = [
            ConsoleLogEntry(
                timestamp: Date(),
                text: "$ \(command.displayCommand)",
                isError: false,
                isStep: false,
                isHighlight: true
            )
        ]
        activeRunningScenarioKey = nil

        if case .runAll = mode {
            liveScenarioStatuses = [:]
            liveScenarioDurations = [:]
        }

        let outputURL = workspace.config.resolvedOutputURL(rootURL: workspace.rootURL)
        let projectPath = workspace.rootURL.path
        let projectName = workspace.config.projectName

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.runnerService.execute(command: command) { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleLiveEvent(event)
                    }
                }

                // Prefer rich CodeceptJS 4.x JUnit XML report if freshly generated during this run
                var finalScenarios = result.parsedScenarios
                if let freshXML = ArtifactScanner.newestJUnitXML(in: outputURL, modifiedAfter: result.startedAt) {
                    let xmlRecords = JUnitReportParser.parse(fileURL: freshXML)
                    if !xmlRecords.isEmpty {
                        finalScenarios = xmlRecords
                        for rec in xmlRecords {
                            let key = Self.scenarioStatusKey(feature: rec.featureTitle, scenario: rec.scenarioTitle)
                            self.liveScenarioStatuses[key] = rec.status
                            self.liveScenarioDurations[key] = rec.durationMs
                        }
                    }
                }

                let passed = result.summaryPassed ?? finalScenarios.filter { $0.status == .passed }.count
                let failed = result.summaryFailed ?? finalScenarios.filter { $0.status == .failed }.count
                let skipped = result.summarySkipped ?? finalScenarios.filter { $0.status == .skipped }.count
                let totalMs = max(1, Int((result.finishedAt.timeIntervalSince(result.startedAt) * 1000.0).rounded()))

                let shouldRecordHistory: Bool
                switch mode {
                case .runAll, .runFile, .runScenario, .runTag, .runLastFailed, .runWorkers:
                    shouldRecordHistory = true
                case .dryRun, .checkEnvironment, .generateDefinitions, .listActions:
                    shouldRecordHistory = false
                }

                if shouldRecordHistory {
                    let report = TestRunReport(
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
                        rawOutput: result.rawOutput
                    )
                    self.runHistory = self.historyStore.append(report)
                    self.selectedReportID = report.id
                }

                self.isRunning = false
                self.activeRunningScenarioKey = nil
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
        guard let file = activeWorkspaceFile else {
            run(mode: .runAll)
            return
        }
        run(mode: .runFile(relativePath: file.relativePath))
    }

    func stopActiveRun() {
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

        case .stepLogged:
            break

        case .scenarioFinished(let record):
            let key = Self.scenarioStatusKey(feature: record.featureTitle, scenario: record.scenarioTitle)
            liveScenarioStatuses[key] = record.status
            liveScenarioDurations[key] = record.durationMs
            if activeRunningScenarioKey == key {
                activeRunningScenarioKey = nil
            }

        case .summary:
            break
        }
    }

    static func scenarioStatusKey(feature: String, scenario: String) -> String {
        "\(feature.lowercased().trimmingCharacters(in: .whitespaces))::\(scenario.lowercased().trimmingCharacters(in: .whitespaces))"
    }

    // MARK: - Report Export

    func exportSelectedReport(asHTML: Bool) {
        guard let report = selectedReport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [asHTML ? .html : .plainText]
        panel.nameFieldStringValue = "ceptra-report-\(report.projectName).\(asHTML ? "html" : "md")"
        if panel.runModal() == .OK, let url = panel.url {
            let content = asHTML ? ReportExporter.toHTML(report) : ReportExporter.toMarkdown(report)
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

    // MARK: - Settings

    func saveSettings() {
        settings.defaultRunOptions = runOptions
        settingsStore.save(settings)
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
