import Foundation

public enum WorkspaceAppearance: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case dark
    case light
    case system

    public var displayName: String {
        switch self {
        case .dark: return "Obsidian Dark"
        case .light: return "Paper Light"
        case .system: return "Match macOS"
        }
    }
}

public enum RightInspectorTab: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case replay
    case codeceptUI
    case outline
    case debug
    case ai

    public var displayTitle: String {
        displayTitle(for: .codeceptJS)
    }

    public func displayTitle(for framework: TestFrameworkKind) -> String {
        switch self {
        case .replay: return "Replay"
        case .codeceptUI: return framework.uiToolDisplayName
        case .outline: return "Outline"
        case .debug: return "Debug"
        case .ai: return "AI"
        }
    }
}

public struct WorkspaceModulePreferences: Codable, Equatable, Sendable {
    public var showLeftSidebar: Bool
    public var showTerminal: Bool
    public var showRightSidebar: Bool
    public var showStatusBar: Bool
    public var activeRightTab: RightInspectorTab
    public var autoOpenReplayOnRun: Bool

    public init(
        showLeftSidebar: Bool = true,
        showTerminal: Bool = false,
        showRightSidebar: Bool = false,
        showStatusBar: Bool = true,
        activeRightTab: RightInspectorTab = .replay,
        autoOpenReplayOnRun: Bool = true
    ) {
        self.showLeftSidebar = showLeftSidebar
        self.showTerminal = showTerminal
        self.showRightSidebar = showRightSidebar
        self.showStatusBar = showStatusBar
        self.activeRightTab = activeRightTab
        self.autoOpenReplayOnRun = autoOpenReplayOnRun
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.showLeftSidebar = try c.decodeIfPresent(Bool.self, forKey: .showLeftSidebar) ?? true
        self.showTerminal = try c.decodeIfPresent(Bool.self, forKey: .showTerminal) ?? false
        self.showRightSidebar = try c.decodeIfPresent(Bool.self, forKey: .showRightSidebar) ?? false
        self.showStatusBar = try c.decodeIfPresent(Bool.self, forKey: .showStatusBar) ?? true
        self.activeRightTab = try c.decodeIfPresent(RightInspectorTab.self, forKey: .activeRightTab) ?? .replay
        self.autoOpenReplayOnRun = try c.decodeIfPresent(Bool.self, forKey: .autoOpenReplayOnRun) ?? true
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let defaultEditorFontSize: Double = 13.0
    public static let minEditorFontSize: Double = 9.0
    public static let maxEditorFontSize: Double = 28.0

    public static func clampedEditorFontSize(_ raw: Double) -> Double {
        let clamped = min(max(raw, minEditorFontSize), maxEditorFontSize)
        return (clamped * 2.0).rounded() / 2.0
    }

    public var editorZoomScale: Double {
        Self.clampedEditorFontSize(editorFontSize) / Self.defaultEditorFontSize
    }

    public var editorZoomPercentage: Int {
        Int((editorZoomScale * 100.0).rounded())
    }

    public var recentProjectPaths: [String]
    public var workspaceConfigPaths: [String: String]
    public var editorFontSize: Double
    public var autoCheckForUpdates: Bool
    public var includePrereleaseUpdates: Bool
    public var gitHubRepository: String
    public var jsRuntime: JSRuntimeKind
    public var customNodePath: String
    public var customBunPath: String
    public var customCodeceptPath: String
    public var customPlaywrightPath: String
    public var consoleExecutionMode: ConsoleExecutionMode
    public var customTerminalAppPath: String
    public var defaultRunOptions: RunOptions
    public var appearance: WorkspaceAppearance
    public var modulePreferences: WorkspaceModulePreferences
    public var codeSnapshotStyle: CodeSnapshotStyle
    public var aiSettings: AISettings

    public init(
        recentProjectPaths: [String] = [],
        workspaceConfigPaths: [String: String] = [:],
        editorFontSize: Double = 13.0,
        autoCheckForUpdates: Bool = true,
        includePrereleaseUpdates: Bool = false,
        gitHubRepository: String = AppMetadata.configuredGitHubRepo,
        jsRuntime: JSRuntimeKind = .node,
        customNodePath: String = "",
        customBunPath: String = "",
        customCodeceptPath: String = "",
        customPlaywrightPath: String = "",
        consoleExecutionMode: ConsoleExecutionMode = .builtIn,
        customTerminalAppPath: String = "",
        defaultRunOptions: RunOptions = RunOptions(),
        appearance: WorkspaceAppearance = .dark,
        modulePreferences: WorkspaceModulePreferences = WorkspaceModulePreferences(),
        codeSnapshotStyle: CodeSnapshotStyle = CodeSnapshotStyle(),
        aiSettings: AISettings = AISettings()
    ) {
        self.recentProjectPaths = recentProjectPaths
        self.workspaceConfigPaths = workspaceConfigPaths
        self.editorFontSize = editorFontSize
        self.autoCheckForUpdates = autoCheckForUpdates
        self.includePrereleaseUpdates = includePrereleaseUpdates
        self.gitHubRepository = gitHubRepository
        self.jsRuntime = jsRuntime
        self.customNodePath = customNodePath
        self.customBunPath = customBunPath
        self.customCodeceptPath = customCodeceptPath
        self.customPlaywrightPath = customPlaywrightPath
        self.consoleExecutionMode = consoleExecutionMode
        self.customTerminalAppPath = customTerminalAppPath
        self.defaultRunOptions = defaultRunOptions
        self.appearance = appearance
        self.modulePreferences = modulePreferences
        self.codeSnapshotStyle = codeSnapshotStyle
        self.aiSettings = aiSettings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.recentProjectPaths = try c.decodeIfPresent([String].self, forKey: .recentProjectPaths) ?? []
        self.workspaceConfigPaths = try c.decodeIfPresent([String: String].self, forKey: .workspaceConfigPaths) ?? [:]
        self.editorFontSize = try c.decodeIfPresent(Double.self, forKey: .editorFontSize) ?? 13.0
        self.autoCheckForUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoCheckForUpdates) ?? true
        self.includePrereleaseUpdates = try c.decodeIfPresent(Bool.self, forKey: .includePrereleaseUpdates) ?? false
        self.gitHubRepository = try c.decodeIfPresent(String.self, forKey: .gitHubRepository) ?? AppMetadata.configuredGitHubRepo
        self.jsRuntime = try c.decodeIfPresent(JSRuntimeKind.self, forKey: .jsRuntime) ?? .node
        self.customNodePath = try c.decodeIfPresent(String.self, forKey: .customNodePath) ?? ""
        self.customBunPath = try c.decodeIfPresent(String.self, forKey: .customBunPath) ?? ""
        self.customCodeceptPath = try c.decodeIfPresent(String.self, forKey: .customCodeceptPath) ?? ""
        self.customPlaywrightPath = try c.decodeIfPresent(String.self, forKey: .customPlaywrightPath) ?? ""
        self.consoleExecutionMode = try c.decodeIfPresent(ConsoleExecutionMode.self, forKey: .consoleExecutionMode) ?? .builtIn
        self.customTerminalAppPath = try c.decodeIfPresent(String.self, forKey: .customTerminalAppPath) ?? ""
        self.defaultRunOptions = try c.decodeIfPresent(RunOptions.self, forKey: .defaultRunOptions) ?? RunOptions()
        self.appearance = try c.decodeIfPresent(WorkspaceAppearance.self, forKey: .appearance) ?? .dark
        self.modulePreferences = try c.decodeIfPresent(WorkspaceModulePreferences.self, forKey: .modulePreferences) ?? WorkspaceModulePreferences()
        self.codeSnapshotStyle = try c.decodeIfPresent(CodeSnapshotStyle.self, forKey: .codeSnapshotStyle) ?? CodeSnapshotStyle()
        self.aiSettings = try c.decodeIfPresent(AISettings.self, forKey: .aiSettings) ?? AISettings()
    }

    public mutating func recordRecentProject(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        recentProjectPaths.removeAll { $0 == normalized }
        recentProjectPaths.insert(normalized, at: 0)
        if recentProjectPaths.count > 12 {
            recentProjectPaths = Array(recentProjectPaths.prefix(12))
        }
    }

    public func customConfigPath(forWorkspaceRoot rootPath: String) -> String? {
        let normalized = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let val = workspaceConfigPaths[normalized]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (val?.isEmpty == false) ? val : nil
    }

    public mutating func setCustomConfigPath(_ configPath: String?, forWorkspaceRoot rootPath: String) {
        let normalized = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        if let trimmed = configPath?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            workspaceConfigPaths[normalized] = trimmed
        } else {
            workspaceConfigPaths.removeValue(forKey: normalized)
        }
    }
}

public final class AppSettingsStore: @unchecked Sendable {
    public static let sharedSuiteName = "com.kobenguyent.Ceptra"
    private let defaults: UserDefaults
    private let key = "com.kobenguyent.Ceptra.settings.v1"
    private let aiSettingsKey = "com.kobenguyent.Ceptra.ai-settings.v1"

    public init(defaults: UserDefaults? = nil) {
        if let defaults {
            self.defaults = defaults
        } else {
            // Use the app's canonical bundle domain so both `/Applications/Ceptra.app`
            // and unbundled `swift run Ceptra` dev launches share the exact same settings.
            self.defaults = UserDefaults(suiteName: Self.sharedSuiteName) ?? .standard
        }
    }

    public func load() -> AppSettings {
        var loaded: AppSettings
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            loaded = decoded
        } else {
            loaded = AppSettings()
        }

        // Recover AI provider profiles from dedicated key if an older Ceptra build overwrote `settings.v1`
        if loaded.aiSettings.profiles.isEmpty,
           let aiData = defaults.data(forKey: aiSettingsKey),
           let recoveredAI = try? JSONDecoder().decode(AISettings.self, from: aiData),
           !recoveredAI.profiles.isEmpty {
            loaded.aiSettings = recoveredAI
        }
        return loaded
    }

    public func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
        if let aiData = try? JSONEncoder().encode(settings.aiSettings) {
            defaults.set(aiData, forKey: aiSettingsKey)
        }
    }
}
