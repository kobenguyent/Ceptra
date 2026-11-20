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
    public var esmCjsCompat: Bool

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
        workerStrategy: WorkerStrategy = .pool,
        esmCjsCompat: Bool = true
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
        self.esmCjsCompat = esmCjsCompat
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
        self.profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? ""
        self.enabledPlugins = try c.decodeIfPresent([String].self, forKey: .enabledPlugins) ?? ["junitReporter"]
        self.environmentVariables = try c.decodeIfPresent([String: String].self, forKey: .environmentVariables) ?? [:]
        self.workerCount = try c.decodeIfPresent(Int.self, forKey: .workerCount) ?? 2
        self.workerStrategy = try c.decodeIfPresent(WorkerStrategy.self, forKey: .workerStrategy) ?? .pool
        self.esmCjsCompat = try c.decodeIfPresent(Bool.self, forKey: .esmCjsCompat) ?? true
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
