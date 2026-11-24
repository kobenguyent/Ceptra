import Foundation

public enum TestFrameworkKind: String, Codable, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case codeceptJS
    case playwright
    case playwrightPython

    public var id: String { rawValue }

    public var isPlaywrightFamily: Bool {
        self == .playwright || self == .playwrightPython
    }

    public var isPython: Bool {
        self == .playwrightPython
    }

    public var displayName: String {
        switch self {
        case .codeceptJS: return "CodeceptJS 4.x"
        case .playwright: return "Playwright Test"
        case .playwrightPython: return "Playwright Python"
        }
    }

    public var shortName: String {
        switch self {
        case .codeceptJS: return "CodeceptJS"
        case .playwright: return "Playwright"
        case .playwrightPython: return "Playwright (Py)"
        }
    }

    public var uiToolDisplayName: String {
        switch self {
        case .codeceptJS: return "CodeceptUI"
        case .playwright: return "Playwright UI"
        case .playwrightPython: return "Trace Viewer"
        }
    }

    public var uiPackageName: String {
        switch self {
        case .codeceptJS: return "@codeceptjs/ui"
        case .playwright: return "@playwright/test"
        case .playwrightPython: return "pytest-playwright"
        }
    }
}

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
        "Playwright", "Puppeteer", "WebDriver", "Appium", "Mobilewright", "Detox", "CDPBrowser",
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

public struct CodeceptMultipleSuiteInfo: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let browsers: [String]
    public let chunks: Int?
    public let grep: String?

    public init(name: String, browsers: [String] = [], chunks: Int? = nil, grep: String? = nil) {
        self.name = name
        self.browsers = browsers
        self.chunks = chunks
        self.grep = grep
    }

    /// Individual `suite:browser` targets (e.g. `smoke:chromium`, `smoke:firefox`).
    public var browserTargets: [String] {
        browsers.map { "\(name):\($0)" }
    }
}

public struct CodeceptConfigSummary: Codable, Equatable, Hashable, Sendable {
    public let framework: TestFrameworkKind
    public let configFilePath: String?
    public let isCustomConfigOverride: Bool
    public let projectName: String
    public let testsPattern: String
    public let hasExplicitTestsPattern: Bool
    public let outputDirectory: String
    public let htmlReportDirectory: String?
    public let baseURL: String?
    public let gherkinFeaturesPattern: String?
    public let gherkinStepsPaths: [String]
    public let helpers: [CodeceptHelperInfo]
    public let plugins: [CodeceptPluginInfo]
    public let includes: [CodeceptIncludeEntry]
    public let multipleSuites: [CodeceptMultipleSuiteInfo]
    public let playwrightProjects: [String]
    public let packageCodeceptVersion: String?
    public let isESM: Bool
    public let isTypeScript: Bool

    public init(
        framework: TestFrameworkKind = .codeceptJS,
        configFilePath: String? = nil,
        isCustomConfigOverride: Bool = false,
        projectName: String,
        testsPattern: String = "./*_test.js",
        hasExplicitTestsPattern: Bool = false,
        outputDirectory: String = "./output",
        htmlReportDirectory: String? = nil,
        baseURL: String? = nil,
        gherkinFeaturesPattern: String? = nil,
        gherkinStepsPaths: [String] = [],
        helpers: [CodeceptHelperInfo] = [],
        plugins: [CodeceptPluginInfo] = [],
        includes: [CodeceptIncludeEntry] = [],
        multipleSuites: [CodeceptMultipleSuiteInfo] = [],
        playwrightProjects: [String] = [],
        packageCodeceptVersion: String? = nil,
        isESM: Bool = false,
        isTypeScript: Bool = false
    ) {
        self.framework = framework
        self.configFilePath = configFilePath
        self.isCustomConfigOverride = isCustomConfigOverride
        self.projectName = projectName
        self.testsPattern = testsPattern
        self.hasExplicitTestsPattern = hasExplicitTestsPattern
        self.outputDirectory = outputDirectory
        self.htmlReportDirectory = htmlReportDirectory
        self.baseURL = baseURL
        self.gherkinFeaturesPattern = gherkinFeaturesPattern
        self.gherkinStepsPaths = gherkinStepsPaths
        self.helpers = helpers
        self.plugins = plugins
        self.includes = includes
        self.multipleSuites = multipleSuites
        self.playwrightProjects = playwrightProjects
        self.packageCodeceptVersion = packageCodeceptVersion
        self.isESM = isESM
        self.isTypeScript = isTypeScript
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.framework = try c.decodeIfPresent(TestFrameworkKind.self, forKey: .framework) ?? .codeceptJS
        self.configFilePath = try c.decodeIfPresent(String.self, forKey: .configFilePath)
        self.isCustomConfigOverride = try c.decodeIfPresent(Bool.self, forKey: .isCustomConfigOverride) ?? false
        self.projectName = try c.decode(String.self, forKey: .projectName)
        self.testsPattern = try c.decodeIfPresent(String.self, forKey: .testsPattern) ?? "./*_test.js"
        self.hasExplicitTestsPattern = try c.decodeIfPresent(Bool.self, forKey: .hasExplicitTestsPattern) ?? false
        self.outputDirectory = try c.decodeIfPresent(String.self, forKey: .outputDirectory) ?? "./output"
        self.htmlReportDirectory = try c.decodeIfPresent(String.self, forKey: .htmlReportDirectory)
        self.baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        self.gherkinFeaturesPattern = try c.decodeIfPresent(String.self, forKey: .gherkinFeaturesPattern)
        self.gherkinStepsPaths = try c.decodeIfPresent([String].self, forKey: .gherkinStepsPaths) ?? []
        self.helpers = try c.decodeIfPresent([CodeceptHelperInfo].self, forKey: .helpers) ?? []
        self.plugins = try c.decodeIfPresent([CodeceptPluginInfo].self, forKey: .plugins) ?? []
        self.includes = try c.decodeIfPresent([CodeceptIncludeEntry].self, forKey: .includes) ?? []
        self.multipleSuites = try c.decodeIfPresent([CodeceptMultipleSuiteInfo].self, forKey: .multipleSuites) ?? []
        self.playwrightProjects = try c.decodeIfPresent([String].self, forKey: .playwrightProjects) ?? []
        self.packageCodeceptVersion = try c.decodeIfPresent(String.self, forKey: .packageCodeceptVersion)
        self.isESM = try c.decodeIfPresent(Bool.self, forKey: .isESM) ?? false
        self.isTypeScript = try c.decodeIfPresent(Bool.self, forKey: .isTypeScript) ?? false
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

    /// Matches CodeceptJS `createOutputDir(config, testRoot)` / Playwright `outputDir`: resolves relative
    /// output path against the active config file's directory (`testRoot`).
    public func resolvedOutputURL(rootURL: URL) -> URL {
        let baseURL = resolvedTestRootURL(workspaceRoot: rootURL)
        let trimmed = outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let fallbackDir = framework.isPlaywrightFamily ? "test-results" : "output"
            return baseURL.appendingPathComponent(fallbackDir, isDirectory: true)
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        }
        return baseURL.appendingPathComponent(trimmed, isDirectory: true).standardizedFileURL
    }

    /// Resolves Playwright's HTML report directory (defaults to `playwright-report` when `framework == .playwright`).
    public func resolvedHTMLReportURL(rootURL: URL) -> URL? {
        guard framework == .playwright || htmlReportDirectory != nil else { return nil }
        let baseURL = resolvedTestRootURL(workspaceRoot: rootURL)
        let trimmed = (htmlReportDirectory ?? "./playwright-report").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
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

    /// Returns true if `filePath` matches this config's `tests` or `gherkin.features` glob pattern.
    public func matchesTestFile(_ filePath: String, workspaceRoot: URL) -> Bool {
        let absPath: String
        if filePath.hasPrefix("/") {
            absPath = URL(fileURLWithPath: filePath).standardizedFileURL.path
        } else {
            absPath = workspaceRoot.appendingPathComponent(filePath).standardizedFileURL.path
        }
        let testRoot = resolvedTestRootURL(workspaceRoot: workspaceRoot)
        if absPath.lowercased().hasSuffix(".feature") {
            guard let featuresPattern = gherkinFeaturesPattern, !featuresPattern.isEmpty else {
                return false
            }
            return ConfigParser.globMatches(pattern: featuresPattern, path: absPath, baseDirectory: testRoot)
        }
        return ConfigParser.globMatches(pattern: testsPattern, path: absPath, baseDirectory: testRoot)
    }

    /// Returns true when `filePath` resides inside this config file's directory (`testRoot`).
    public func containsFileInConfigDirectory(_ filePath: String, workspaceRoot: URL) -> Bool {
        let absPath: String
        if filePath.hasPrefix("/") {
            absPath = URL(fileURLWithPath: filePath).standardizedFileURL.path
        } else {
            absPath = workspaceRoot.appendingPathComponent(filePath).standardizedFileURL.path
        }
        let dirPath = resolvedTestRootURL(workspaceRoot: workspaceRoot).path
        let prefix = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
        return absPath.hasPrefix(prefix)
    }
}

public struct CodeceptWorkspace: Equatable, Sendable {
    public let rootURL: URL
    public let config: CodeceptConfigSummary
    public let discoveredConfigPaths: [String]
    public let discoveredConfigs: [CodeceptConfigSummary]
    public let packageManager: PackageManagerKind
    public let packageScripts: [PackageScriptItem]
    public let files: [WorkspaceFile]
    public let rootTree: [WorkspaceTreeNode]
    public let allTags: [String]
    public let scannedAt: Date

    public init(
        rootURL: URL,
        config: CodeceptConfigSummary,
        discoveredConfigPaths: [String] = [],
        discoveredConfigs: [CodeceptConfigSummary] = [],
        packageManager: PackageManagerKind = .npm,
        packageScripts: [PackageScriptItem] = [],
        files: [WorkspaceFile],
        rootTree: [WorkspaceTreeNode] = [],
        allTags: [String],
        scannedAt: Date = Date()
    ) {
        self.rootURL = rootURL
        self.config = config
        self.discoveredConfigPaths = discoveredConfigPaths
        self.discoveredConfigs = discoveredConfigs
        self.packageManager = packageManager
        self.packageScripts = packageScripts
        self.files = files
        self.rootTree = rootTree
        self.allTags = allTags
        self.scannedAt = scannedAt
    }

    /// Returns a copy of this workspace using `newConfig` as the active config without re-walking disk.
    public func withActiveConfig(_ newConfig: CodeceptConfigSummary) -> CodeceptWorkspace {
        CodeceptWorkspace(
            rootURL: rootURL,
            config: newConfig,
            discoveredConfigPaths: discoveredConfigPaths,
            discoveredConfigs: discoveredConfigs,
            packageManager: packageManager,
            packageScripts: packageScripts,
            files: files,
            rootTree: rootTree,
            allTags: allTags,
            scannedAt: scannedAt
        )
    }

    /// Resolves the most appropriate CodeceptJS config for `filePath` (relative to `rootURL` or absolute)
    /// across multi-config / monorepo workspaces.
    ///
    /// Rules:
    /// - Single-config workspaces always return `config`.
    /// - External custom overrides outside `rootURL` are preserved.
    /// - Explicit custom overrides inside `rootURL` are preserved whenever the pinned config already
    ///   matches `filePath` (e.g., environment overrides like `configs/staging.conf.ts` vs `configs/prod.conf.ts`).
    /// - When a file lives under or matches a different suite config (e.g. `tests/web/tests/login_test.ts`
    ///   while `tests/api/codecept.conf.ts` is active), the owning config (`tests/web/codecept.conf.ts`) is selected.
    public func resolvedConfig(forFilePath filePath: String) -> CodeceptConfigSummary {
        let trimmed = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return config }

        let stdRoot = rootURL.standardizedFileURL
        let rootPath = stdRoot.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let absPath = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed).standardizedFileURL.path
            : stdRoot.appendingPathComponent(trimmed).standardizedFileURL.path

        // Build unique candidate list (prefer parsed summaries in `discoveredConfigs`, fallback to `config`)
        var candidates: [CodeceptConfigSummary] = []
        var seenPaths = Set<String>()
        for cfg in discoveredConfigs {
            if let path = cfg.configFilePath, seenPaths.insert(path).inserted {
                candidates.append(cfg)
            }
        }
        if let activePath = config.configFilePath {
            if let existingIdx = candidates.firstIndex(where: { $0.configFilePath == activePath }) {
                candidates[existingIdx] = config
            } else if seenPaths.insert(activePath).inserted {
                candidates.append(config)
            }
        }
        guard candidates.count > 1 else { return config }

        // Respect an explicit external config file outside the workspace root
        if config.isCustomConfigOverride,
           let activePath = config.configFilePath,
           !activePath.hasPrefix(rootPrefix) {
            return config
        }

        // Respect an explicit custom override inside the workspace if it already owns/matches `absPath`
        if config.isCustomConfigOverride,
           let activePath = config.configFilePath {
            let activeDir = config.resolvedTestRootURL(workspaceRoot: stdRoot).path
            let activeIsStrictSubdir = config.containsFileInConfigDirectory(absPath, workspaceRoot: stdRoot) && activeDir != rootPath
            if activePath == absPath
                || config.matchesTestFile(absPath, workspaceRoot: stdRoot)
                || activeIsStrictSubdir {
                return config
            }
        }

        struct CandidateScore {
            let summary: CodeceptConfigSummary
            let tier: Int
            let dirDepth: Int
            let isActive: Bool
            let orderIndex: Int
        }

        var scored: [CandidateScore] = []
        for (idx, candidate) in candidates.enumerated() {
            guard let cPath = candidate.configFilePath else { continue }
            let isActive = (cPath == config.configFilePath)
            let dirURL = candidate.resolvedTestRootURL(workspaceRoot: stdRoot)
            let dirPath = dirURL.path
            let dirDepth = dirURL.pathComponents.count
            let isUnderDir = candidate.containsFileInConfigDirectory(absPath, workspaceRoot: stdRoot)
            let isRootDir = (dirPath == rootPath)
            let isStrictSubdir = isUnderDir && !isRootDir
            let matchesPattern = candidate.matchesTestFile(absPath, workspaceRoot: stdRoot)

            let tier: Int
            if cPath == absPath {
                tier = 5
            } else if matchesPattern && isUnderDir {
                tier = 4
            } else if matchesPattern {
                tier = 3
            } else if isStrictSubdir {
                tier = 2
            } else if isUnderDir {
                tier = 1
            } else {
                tier = 0
            }

            scored.append(CandidateScore(
                summary: candidate,
                tier: tier,
                dirDepth: dirDepth,
                isActive: isActive,
                orderIndex: idx
            ))
        }

        guard let best = scored.max(by: { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.dirDepth != rhs.dirDepth { return lhs.dirDepth < rhs.dirDepth }
            if lhs.isActive != rhs.isActive { return !lhs.isActive && rhs.isActive }
            return lhs.orderIndex > rhs.orderIndex
        }), best.tier > 0 else {
            return config
        }

        return best.summary
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
