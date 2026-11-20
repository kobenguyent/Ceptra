import Foundation

public struct CodeceptHelperInfo: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let isBuiltIn: Bool
    public let requirePath: String?
    public let summary: String?

    public init(name: String, isBuiltIn: Bool, requirePath: String? = nil, summary: String? = nil) {
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.requirePath = requirePath
        self.summary = summary
    }

    public static let knownBuiltIns: Set<String> = [
        "Playwright", "Puppeteer", "WebDriver", "Appium", "CDPBrowser",
        "Obscura", "Lightpanda", "Moli", "Kitesurf",
        "REST", "GraphQL", "JSONResponse", "ApiDataFactory",
        "GraphQLDataFactory", "FileSystem", "Decision"
    ]
}

public struct CodeceptPluginInfo: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let enabled: Bool
    public let requirePath: String?

    public init(name: String, enabled: Bool, requirePath: String? = nil) {
        self.name = name
        self.enabled = enabled
        self.requirePath = requirePath
    }
}

public struct CodeceptIncludeEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { alias }
    public let alias: String
    public let relativePath: String

    public init(alias: String, relativePath: String) {
        self.alias = alias
        self.relativePath = relativePath
    }
}

public struct CodeceptConfigSummary: Codable, Equatable, Hashable, Sendable {
    public let configFilePath: String?
    public let isCustomConfigOverride: Bool
    public let projectName: String
    public let testsPattern: String
    public let outputDirectory: String
    public let gherkinFeaturesPattern: String?
    public let gherkinStepsPaths: [String]
    public let helpers: [CodeceptHelperInfo]
    public let plugins: [CodeceptPluginInfo]
    public let includes: [CodeceptIncludeEntry]
    public let packageCodeceptVersion: String?
    public let isESM: Bool
    public let isTypeScript: Bool

    public init(
        configFilePath: String? = nil,
        isCustomConfigOverride: Bool = false,
        projectName: String,
        testsPattern: String = "./*_test.js",
        outputDirectory: String = "./output",
        gherkinFeaturesPattern: String? = nil,
        gherkinStepsPaths: [String] = [],
        helpers: [CodeceptHelperInfo] = [],
        plugins: [CodeceptPluginInfo] = [],
        includes: [CodeceptIncludeEntry] = [],
        packageCodeceptVersion: String? = nil,
        isESM: Bool = false,
        isTypeScript: Bool = false
    ) {
        self.configFilePath = configFilePath
        self.isCustomConfigOverride = isCustomConfigOverride
        self.projectName = projectName
        self.testsPattern = testsPattern
        self.outputDirectory = outputDirectory
        self.gherkinFeaturesPattern = gherkinFeaturesPattern
        self.gherkinStepsPaths = gherkinStepsPaths
        self.helpers = helpers
        self.plugins = plugins
        self.includes = includes
        self.packageCodeceptVersion = packageCodeceptVersion
        self.isESM = isESM
        self.isTypeScript = isTypeScript
    }

    /// Matches CodeceptJS `getTestRoot(configFile)`: the directory containing the active config file,
    /// falling back to the workspace root when no config file is active.
    public func resolvedTestRootURL(workspaceRoot: URL) -> URL {
        guard let configFilePath, !configFilePath.isEmpty else {
            return workspaceRoot.standardizedFileURL
        }
        return URL(fileURLWithPath: configFilePath)
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    /// Matches CodeceptJS `createOutputDir(config, testRoot)`: resolves relative `output` against the
    /// active config file's directory (`testRoot`).
    public func resolvedOutputURL(rootURL: URL) -> URL {
        let baseURL = resolvedTestRootURL(workspaceRoot: rootURL)
        let trimmed = outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return baseURL.appendingPathComponent("output", isDirectory: true)
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        }
        return baseURL.appendingPathComponent(trimmed, isDirectory: true).standardizedFileURL
    }

    /// Human-readable path for the active config (relative to workspace root when inside it, otherwise shortened path).
    public func displayConfigPath(relativeTo workspaceRoot: URL) -> String? {
        guard let configFilePath else { return nil }
        let stdConfig = URL(fileURLWithPath: configFilePath).standardizedFileURL.path
        let stdRoot = workspaceRoot.standardizedFileURL.path
        let prefix = stdRoot.hasSuffix("/") ? stdRoot : stdRoot + "/"
        if stdConfig.hasPrefix(prefix) {
            return String(stdConfig.dropFirst(prefix.count))
        }
        return stdConfig
    }
}

public struct CodeceptWorkspace: Equatable, Sendable {
    public let rootURL: URL
    public let config: CodeceptConfigSummary
    public let discoveredConfigPaths: [String]
    public let files: [WorkspaceFile]
    public let allTags: [String]
    public let scannedAt: Date

    public init(
        rootURL: URL,
        config: CodeceptConfigSummary,
        discoveredConfigPaths: [String] = [],
        files: [WorkspaceFile],
        allTags: [String],
        scannedAt: Date = Date()
    ) {
        self.rootURL = rootURL
        self.config = config
        self.discoveredConfigPaths = discoveredConfigPaths
        self.files = files
        self.allTags = allTags
        self.scannedAt = scannedAt
    }

    public var testFiles: [WorkspaceFile] {
        files.filter { $0.category == .testSuite || $0.category == .gherkinFeature }
    }

    public var supportFiles: [WorkspaceFile] {
        files.filter { $0.category == .pageObject || $0.category == .stepDefinition }
    }

    public var configAndHelperFiles: [WorkspaceFile] {
        files.filter { $0.category == .config || $0.category == .helper || $0.category == .other }
    }

    public var totalFeatureCount: Int {
        testFiles.reduce(0) { $0 + $1.features.count }
    }

    public var totalScenarioCount: Int {
        testFiles.reduce(0) { total, file in
            total + file.features.reduce(0) { $0 + $1.scenarios.count }
        }
    }
}
