import Foundation

public enum ExecutionStatus: String, Codable, Equatable, Hashable, Sendable {
    case idle
    case running
    case passed
    case failed
    case skipped
    case cancelled
}

public struct ExecutedStepRecord: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let text: String
    public let depth: Int
    public let status: ExecutionStatus
    public let durationMs: Int?

    public init(
        id: UUID = UUID(),
        text: String,
        depth: Int = 0,
        status: ExecutionStatus = .passed,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.depth = depth
        self.status = status
        self.durationMs = durationMs
    }
}

public struct ExecutedScenarioRecord: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let featureTitle: String
    public let scenarioTitle: String
    public let filePath: String?
    public let status: ExecutionStatus
    public let durationMs: Int
    public let tags: [String]
    public let steps: [ExecutedStepRecord]
    public let errorMessage: String?
    public let errorStack: String?

    public init(
        id: UUID = UUID(),
        featureTitle: String,
        scenarioTitle: String,
        filePath: String? = nil,
        status: ExecutionStatus,
        durationMs: Int = 0,
        tags: [String] = [],
        steps: [ExecutedStepRecord] = [],
        errorMessage: String? = nil,
        errorStack: String? = nil
    ) {
        self.id = id
        self.featureTitle = featureTitle
        self.scenarioTitle = scenarioTitle
        self.filePath = filePath
        self.status = status
        self.durationMs = durationMs
        self.tags = tags
        self.steps = steps
        self.errorMessage = errorMessage
        self.errorStack = errorStack
    }
}

public enum ArtifactKind: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    case screenshot
    case aiTrace
    case screencast
    case subtitle
    case junitXML
    case htmlReport
    case snapshot

    public var displayName: String {
        switch self {
        case .screenshot: return "Screenshots"
        case .aiTrace: return "AI Traces"
        case .screencast: return "Screencasts"
        case .subtitle: return "Subtitles"
        case .junitXML: return "JUnit XML"
        case .htmlReport: return "HTML Reports"
        case .snapshot: return "Snapshots"
        }
    }

    public var symbolName: String {
        switch self {
        case .screenshot: return "photo"
        case .aiTrace: return "sparkles.rectangle.stack"
        case .screencast: return "film"
        case .subtitle: return "captions.bubble"
        case .junitXML: return "doc.badge.gearshape"
        case .htmlReport: return "globe"
        case .snapshot: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

public struct ReportArtifact: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let relativePath: String
    public let path: String
    public let kind: ArtifactKind
    public let fileSize: Int64
    public let modifiedAt: Date

    public init(
        name: String,
        relativePath: String,
        path: String,
        kind: ArtifactKind,
        fileSize: Int64,
        modifiedAt: Date
    ) {
        self.name = name
        self.relativePath = relativePath
        self.path = path
        self.kind = kind
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

public struct TestRunReport: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let projectPath: String
    public let projectName: String
    public let label: String
    public let commandLine: String
    public let startedAt: Date
    public let finishedAt: Date
    public let exitCode: Int32
    public let wasCancelled: Bool
    public let passedCount: Int
    public let failedCount: Int
    public let skippedCount: Int
    public let durationMs: Int
    public let scenarios: [ExecutedScenarioRecord]
    public let rawOutput: String

    public init(
        id: UUID = UUID(),
        projectPath: String,
        projectName: String,
        label: String,
        commandLine: String,
        startedAt: Date,
        finishedAt: Date,
        exitCode: Int32,
        wasCancelled: Bool = false,
        passedCount: Int,
        failedCount: Int,
        skippedCount: Int,
        durationMs: Int,
        scenarios: [ExecutedScenarioRecord],
        rawOutput: String
    ) {
        self.id = id
        self.projectPath = projectPath
        self.projectName = projectName
        self.label = label
        self.commandLine = commandLine
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.wasCancelled = wasCancelled
        self.passedCount = passedCount
        self.failedCount = failedCount
        self.skippedCount = skippedCount
        self.durationMs = durationMs
        self.scenarios = scenarios
        self.rawOutput = rawOutput
    }

    public var totalCount: Int {
        passedCount + failedCount + skippedCount
    }

    public var passRate: Double {
        guard totalCount > 0 else { return exitCode == 0 ? 1.0 : 0.0 }
        return Double(passedCount) / Double(totalCount)
    }

    public var overallStatus: ExecutionStatus {
        if wasCancelled { return .cancelled }
        if failedCount > 0 || exitCode != 0 { return .failed }
        if passedCount > 0 { return .passed }
        if skippedCount > 0 { return .skipped }
        return .passed
    }
}
