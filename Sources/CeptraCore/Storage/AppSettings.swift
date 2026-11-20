import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var recentProjectPaths: [String]
    public var editorFontSize: Double
    public var autoCheckForUpdates: Bool
    public var includePrereleaseUpdates: Bool
    public var gitHubRepository: String
    public var customNodePath: String
    public var customCodeceptPath: String
    public var defaultRunOptions: RunOptions

    public init(
        recentProjectPaths: [String] = [],
        editorFontSize: Double = 13.0,
        autoCheckForUpdates: Bool = true,
        includePrereleaseUpdates: Bool = false,
        gitHubRepository: String = AppMetadata.configuredGitHubRepo,
        customNodePath: String = "",
        customCodeceptPath: String = "",
        defaultRunOptions: RunOptions = RunOptions()
    ) {
        self.recentProjectPaths = recentProjectPaths
        self.editorFontSize = editorFontSize
        self.autoCheckForUpdates = autoCheckForUpdates
        self.includePrereleaseUpdates = includePrereleaseUpdates
        self.gitHubRepository = gitHubRepository
        self.customNodePath = customNodePath
        self.customCodeceptPath = customCodeceptPath
        self.defaultRunOptions = defaultRunOptions
    }

    public mutating func recordRecentProject(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        recentProjectPaths.removeAll { $0 == normalized }
        recentProjectPaths.insert(normalized, at: 0)
        if recentProjectPaths.count > 12 {
            recentProjectPaths = Array(recentProjectPaths.prefix(12))
        }
    }
}

public final class AppSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "com.kobenguyent.Ceptra.settings.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else {
            return AppSettings()
        }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            return AppSettings()
        }
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
