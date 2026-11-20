import Foundation

public enum CodeceptRunMode: Equatable, Hashable, Sendable {
    case runAll
    case runFile(relativePath: String)
    case runScenario(relativePath: String?, scenarioTitle: String)
    case runTag(tag: String)
    case runLastFailed
    case runWorkers(count: Int, strategy: WorkerStrategy)
    case dryRun(relativePath: String?)
    case checkEnvironment
    case generateDefinitions
    case listActions

    public var displayLabel: String {
        switch self {
        case .runAll: return "Run All Tests"
        case .runFile(let path): return "Run \(URL(fileURLWithPath: path).lastPathComponent)"
        case .runScenario(_, let title): return "Run \"\(title)\""
        case .runTag(let tag): return "Run \(tag)"
        case .runLastFailed: return "Re-run Failed"
        case .runWorkers(let count, let strategy): return "Run \(count) Workers (\(strategy.rawValue))"
        case .dryRun: return "Dry Run"
        case .checkEnvironment: return "Check Environment"
        case .generateDefinitions: return "Generate steps.d.ts"
        case .listActions: return "List I.* Actions"
        }
    }
}

public enum WorkerStrategy: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case pool
    case test
    case suite
}

public struct RunOptions: Codable, Equatable, Hashable, Sendable {
    public var showSteps: Bool
    public var debug: Bool
    public var verbose: Bool
    public var aiEnabled: Bool
    public var bailOnFail: Bool
    public var noTimeouts: Bool
    public var grepPattern: String
    public var profile: String
    public var enabledPlugins: [String]
    public var environmentVariables: [String: String]
    public var workerCount: Int
    public var workerStrategy: WorkerStrategy

    public init(
        showSteps: Bool = true,
        debug: Bool = false,
        verbose: Bool = false,
        aiEnabled: Bool = false,
        bailOnFail: Bool = false,
        noTimeouts: Bool = false,
        grepPattern: String = "",
        profile: String = "",
        enabledPlugins: [String] = ["junitReporter"],
        environmentVariables: [String: String] = [:],
        workerCount: Int = 2,
        workerStrategy: WorkerStrategy = .pool
    ) {
        self.showSteps = showSteps
        self.debug = debug
        self.verbose = verbose
        self.aiEnabled = aiEnabled
        self.bailOnFail = bailOnFail
        self.noTimeouts = noTimeouts
        self.grepPattern = grepPattern
        self.profile = profile
        self.enabledPlugins = enabledPlugins
        self.environmentVariables = environmentVariables
        self.workerCount = workerCount
        self.workerStrategy = workerStrategy
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
