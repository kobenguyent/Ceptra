import Foundation

public enum CodeceptRunMode: Equatable, Hashable, Sendable {
    case runAll
    case runFile(relativePath: String)
    case runScenario(relativePath: String?, scenarioTitle: String)
    case runTag(tag: String)
    case runLastFailed
    case runWorkers(
        count: Int,
        strategy: WorkerStrategy,
        selectedRuns: [String] = [],
        serialPattern: String? = nil,
        lastFailed: Bool = false
    )
    case runMultiple(suites: [String] = [], runAll: Bool = true)
    case dryRun(relativePath: String?)
    case checkEnvironment
    case generateDefinitions
    case listActions
    case playwrightCodegen(url: String? = nil)
    case playwrightShowReport(reportDirectory: String? = nil)

    public var displayLabel: String {
        displayLabel(for: .codeceptJS)
    }

    public func displayLabel(for framework: TestFrameworkKind) -> String {
        switch self {
        case .runAll:
            return "Run All Tests"
        case .runFile(let path):
            return "Run \(URL(fileURLWithPath: path).lastPathComponent)"
        case .runScenario(_, let title):
            return "Run \"\(title)\""
        case .runTag(let tag):
            return "Run \(tag)"
        case .runLastFailed:
            return "Re-run Failed"
        case .runWorkers(let count, let strategy, let selectedRuns, _, let lastFailed):
            var label: String
            switch framework {
            case .playwright:
                label = "Run \(count) Workers"
            case .playwrightPython:
                label = "Run \(count) Workers (-n)"
            case .codeceptJS:
                label = "Run \(count) Workers (\(strategy.rawValue))"
            }
            if !selectedRuns.isEmpty {
                label += " · \(selectedRuns.joined(separator: ", "))"
            } else if lastFailed {
                label += " · last-failed"
            }
            return label
        case .runMultiple(let suites, let runAll):
            let clean = suites.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if framework == .playwrightPython {
                if runAll || clean.isEmpty {
                    return "Run All Browsers"
                }
                return "Run Browsers (\(clean.joined(separator: ", ")))"
            }
            if framework == .playwright {
                if runAll || clean.isEmpty {
                    return "Run All Projects"
                }
                return "Run Projects (\(clean.joined(separator: ", ")))"
            }
            if runAll || clean.isEmpty {
                return "Run Multiple (--all)"
            }
            return "Run Multiple (\(clean.joined(separator: ", ")))"
        case .dryRun:
            switch framework {
            case .playwright: return "List Tests (--list)"
            case .playwrightPython: return "Collect Tests (--co)"
            case .codeceptJS: return "Dry Run"
            }
        case .checkEnvironment:
            switch framework {
            case .playwright: return "Playwright Version"
            case .playwrightPython: return "Pytest & Playwright Version"
            case .codeceptJS: return "Check Environment"
            }
        case .generateDefinitions:
            switch framework {
            case .playwright: return "Playwright Codegen"
            case .playwrightPython: return "Playwright Codegen (Python)"
            case .codeceptJS: return "Generate steps.d.ts"
            }
        case .listActions:
            switch framework {
            case .playwright: return "List Tests (--list)"
            case .playwrightPython: return "Collect Tests (--co)"
            case .codeceptJS: return "List I.* Actions"
            }
        case .playwrightCodegen:
            return framework == .playwrightPython ? "Playwright Codegen (Python)" : "Playwright Codegen"
        case .playwrightShowReport:
            return framework == .playwrightPython ? "Playwright Trace Viewer" : "Playwright HTML Report"
        }
    }

    public var supportsInteractiveDebugging: Bool {
        switch self {
        case .runAll, .runFile, .runScenario, .runTag, .runLastFailed:
            return true
        case .runWorkers, .runMultiple, .dryRun, .checkEnvironment, .generateDefinitions,
             .listActions, .playwrightCodegen, .playwrightShowReport:
            return false
        }
    }

    /// Target test file path (relative or absolute) when targeting a single file or scenario.
    public var targetFilePath: String? {
        switch self {
        case .runFile(let relativePath):
            return relativePath.isEmpty ? nil : relativePath
        case .runScenario(let relativePath, _):
            guard let relativePath, !relativePath.isEmpty else { return nil }
            return relativePath
        case .dryRun(let relativePath):
            guard let relativePath, !relativePath.isEmpty else { return nil }
            return relativePath
        case .runAll, .runTag, .runLastFailed, .runWorkers, .runMultiple,
             .checkEnvironment, .generateDefinitions, .listActions,
             .playwrightCodegen, .playwrightShowReport:
            return nil
        }
    }
}

public enum PlaywrightTraceMode: String, Codable, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case configDefault = "default"
    case on = "on"
    case retainOnFailure = "retain-on-failure"
    case onFirstRetry = "on-first-retry"
    case off = "off"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .configDefault: return "Config Default"
        case .on: return "Always On"
        case .retainOnFailure: return "Retain on Failure"
        case .onFirstRetry: return "On First Retry"
        case .off: return "Off"
        }
    }
}

public enum WorkerStrategy: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case pool
    case test
    case suite

    public var summary: String {
        switch self {
        case .pool: return "Dynamic load-balanced queue (recommended)"
        case .test: return "Pre-assign individual scenarios across workers"
        case .suite: return "Pre-assign entire test files across workers"
        }
    }
}

public struct RunOptions: Codable, Equatable, Hashable, Sendable {
    public var showSteps: Bool
    public var debug: Bool
    public var verbose: Bool
    public var aiEnabled: Bool
    public var bailOnFail: Bool
    public var noTimeouts: Bool
    public var grepPattern: String
    public var invertGrep: Bool
    public var profile: String
    public var enabledPlugins: [String]
    public var environmentVariables: [String: String]
    public var workerCount: Int
    public var workerStrategy: WorkerStrategy
    public var workerSerialPattern: String
    public var workerLastFailed: Bool
    public var workerSelectedRuns: [String]
    public var multipleSelectedSuites: [String]
    public var multipleRunAll: Bool
    public var esmCjsCompat: Bool
    public var timeTravelTrace: Bool
    public var debugLaunchOptions: DebugLaunchOptions
    public var playwrightHeaded: Bool
    public var playwrightTraceMode: PlaywrightTraceMode
    public var playwrightUpdateSnapshots: Bool
    public var playwrightRetries: Int?
    public var playwrightSelectedProjects: [String]

    public init(
        showSteps: Bool = true,
        debug: Bool = false,
        verbose: Bool = false,
        aiEnabled: Bool = false,
        bailOnFail: Bool = false,
        noTimeouts: Bool = false,
        grepPattern: String = "",
        invertGrep: Bool = false,
        profile: String = "",
        enabledPlugins: [String] = ["junitReporter"],
        environmentVariables: [String: String] = [:],
        workerCount: Int = 2,
        workerStrategy: WorkerStrategy = .pool,
        workerSerialPattern: String = "",
        workerLastFailed: Bool = false,
        workerSelectedRuns: [String] = [],
        multipleSelectedSuites: [String] = [],
        multipleRunAll: Bool = true,
        esmCjsCompat: Bool = true,
        timeTravelTrace: Bool = true,
        debugLaunchOptions: DebugLaunchOptions = DebugLaunchOptions(),
        playwrightHeaded: Bool = false,
        playwrightTraceMode: PlaywrightTraceMode = .configDefault,
        playwrightUpdateSnapshots: Bool = false,
        playwrightRetries: Int? = nil,
        playwrightSelectedProjects: [String] = []
    ) {
        self.showSteps = showSteps
        self.debug = debug
        self.verbose = verbose
        self.aiEnabled = aiEnabled
        self.bailOnFail = bailOnFail
        self.noTimeouts = noTimeouts
        self.grepPattern = grepPattern
        self.invertGrep = invertGrep
        self.profile = profile
        self.enabledPlugins = enabledPlugins
        self.environmentVariables = environmentVariables
        self.workerCount = workerCount
        self.workerStrategy = workerStrategy
        self.workerSerialPattern = workerSerialPattern
        self.workerLastFailed = workerLastFailed
        self.workerSelectedRuns = workerSelectedRuns
        self.multipleSelectedSuites = multipleSelectedSuites
        self.multipleRunAll = multipleRunAll
        self.esmCjsCompat = esmCjsCompat
        self.timeTravelTrace = timeTravelTrace
        self.debugLaunchOptions = debugLaunchOptions
        self.playwrightHeaded = playwrightHeaded
        self.playwrightTraceMode = playwrightTraceMode
        self.playwrightUpdateSnapshots = playwrightUpdateSnapshots
        self.playwrightRetries = playwrightRetries
        self.playwrightSelectedProjects = playwrightSelectedProjects
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.showSteps = try c.decodeIfPresent(Bool.self, forKey: .showSteps) ?? true
        self.debug = try c.decodeIfPresent(Bool.self, forKey: .debug) ?? false
        self.verbose = try c.decodeIfPresent(Bool.self, forKey: .verbose) ?? false
        self.aiEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiEnabled) ?? false
        self.bailOnFail = try c.decodeIfPresent(Bool.self, forKey: .bailOnFail) ?? false
        self.noTimeouts = try c.decodeIfPresent(Bool.self, forKey: .noTimeouts) ?? false
        self.grepPattern = try c.decodeIfPresent(String.self, forKey: .grepPattern) ?? ""
        self.invertGrep = try c.decodeIfPresent(Bool.self, forKey: .invertGrep) ?? false
        self.profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? ""
        self.enabledPlugins = try c.decodeIfPresent([String].self, forKey: .enabledPlugins) ?? ["junitReporter"]
        self.environmentVariables = try c.decodeIfPresent([String: String].self, forKey: .environmentVariables) ?? [:]
        self.workerCount = try c.decodeIfPresent(Int.self, forKey: .workerCount) ?? 2
        self.workerStrategy = try c.decodeIfPresent(WorkerStrategy.self, forKey: .workerStrategy) ?? .pool
        self.workerSerialPattern = try c.decodeIfPresent(String.self, forKey: .workerSerialPattern) ?? ""
        self.workerLastFailed = try c.decodeIfPresent(Bool.self, forKey: .workerLastFailed) ?? false
        self.workerSelectedRuns = try c.decodeIfPresent([String].self, forKey: .workerSelectedRuns) ?? []
        self.multipleSelectedSuites = try c.decodeIfPresent([String].self, forKey: .multipleSelectedSuites) ?? []
        self.multipleRunAll = try c.decodeIfPresent(Bool.self, forKey: .multipleRunAll) ?? true
        self.esmCjsCompat = try c.decodeIfPresent(Bool.self, forKey: .esmCjsCompat) ?? true
        self.timeTravelTrace = try c.decodeIfPresent(Bool.self, forKey: .timeTravelTrace) ?? true
        self.debugLaunchOptions = try c.decodeIfPresent(DebugLaunchOptions.self, forKey: .debugLaunchOptions) ?? DebugLaunchOptions()
        self.playwrightHeaded = try c.decodeIfPresent(Bool.self, forKey: .playwrightHeaded) ?? false
        self.playwrightTraceMode = try c.decodeIfPresent(PlaywrightTraceMode.self, forKey: .playwrightTraceMode) ?? .configDefault
        self.playwrightUpdateSnapshots = try c.decodeIfPresent(Bool.self, forKey: .playwrightUpdateSnapshots) ?? false
        self.playwrightRetries = try c.decodeIfPresent(Int.self, forKey: .playwrightRetries)
        self.playwrightSelectedProjects = try c.decodeIfPresent([String].self, forKey: .playwrightSelectedProjects) ?? []
    }

    public static let availableQuickPlugins: [String] = [
        "junitReporter",
        "screenshot",
        "aiTrace",
        "screencast",
        "retryFailedStep",
        "heal"
    ]
}
