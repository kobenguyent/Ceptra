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
    public let startedAt: Date?
    public let finishedAt: Date?
    public let targetSelector: String?
    public let errorMessage: String?
    public let diagnostics: TimeTravelStepDiagnostics?

    public init(
        id: UUID = UUID(),
        text: String,
        depth: Int = 0,
        status: ExecutionStatus = .passed,
        durationMs: Int? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        targetSelector: String? = nil,
        errorMessage: String? = nil,
        diagnostics: TimeTravelStepDiagnostics? = nil
    ) {
        self.id = id
        self.text = text
        self.depth = depth
        self.status = status
        self.durationMs = durationMs
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.targetSelector = targetSelector
        self.errorMessage = errorMessage
        self.diagnostics = diagnostics
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = try c.decode(String.self, forKey: .text)
        self.depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? 0
        self.status = try c.decodeIfPresent(ExecutionStatus.self, forKey: .status) ?? .passed
        self.durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        self.startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        self.finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        self.targetSelector = try c.decodeIfPresent(String.self, forKey: .targetSelector)
        self.errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        self.diagnostics = try c.decodeIfPresent(TimeTravelStepDiagnostics.self, forKey: .diagnostics)
    }

    public func strippingDiagnostics() -> ExecutedStepRecord {
        ExecutedStepRecord(
            id: id,
            text: text,
            depth: depth,
            status: status,
            durationMs: durationMs,
            startedAt: startedAt,
            finishedAt: finishedAt,
            targetSelector: targetSelector,
            errorMessage: errorMessage,
            diagnostics: nil
        )
    }
}

public struct ExecutedScenarioRecord: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let featureTitle: String
    public let scenarioTitle: String
    public let filePath: String?
    public let status: ExecutionStatus
    public let durationMs: Int
    public let startedAt: Date?
    public let finishedAt: Date?
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
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
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
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.tags = tags
        self.steps = steps
        self.errorMessage = errorMessage
        self.errorStack = errorStack
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.featureTitle = try c.decode(String.self, forKey: .featureTitle)
        self.scenarioTitle = try c.decode(String.self, forKey: .scenarioTitle)
        self.filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
        self.status = try c.decode(ExecutionStatus.self, forKey: .status)
        self.durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
        self.startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        self.finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.steps = try c.decodeIfPresent([ExecutedStepRecord].self, forKey: .steps) ?? []
        self.errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        self.errorStack = try c.decodeIfPresent(String.self, forKey: .errorStack)
    }

    public func strippingDiagnostics() -> ExecutedScenarioRecord {
        ExecutedScenarioRecord(
            id: id,
            featureTitle: featureTitle,
            scenarioTitle: scenarioTitle,
            filePath: filePath,
            status: status,
            durationMs: durationMs,
            startedAt: startedAt,
            finishedAt: finishedAt,
            tags: tags,
            steps: steps.map { $0.strippingDiagnostics() },
            errorMessage: errorMessage,
            errorStack: errorStack
        )
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
    public let traceBundlePath: String?
    public let htmlReportPath: String?

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
        rawOutput: String,
        traceBundlePath: String? = nil,
        htmlReportPath: String? = nil
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
        self.traceBundlePath = traceBundlePath
        self.htmlReportPath = htmlReportPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.projectPath = try c.decode(String.self, forKey: .projectPath)
        self.projectName = try c.decode(String.self, forKey: .projectName)
        self.label = try c.decode(String.self, forKey: .label)
        self.commandLine = try c.decode(String.self, forKey: .commandLine)
        self.startedAt = try c.decode(Date.self, forKey: .startedAt)
        self.finishedAt = try c.decode(Date.self, forKey: .finishedAt)
        self.exitCode = try c.decode(Int32.self, forKey: .exitCode)
        self.wasCancelled = try c.decodeIfPresent(Bool.self, forKey: .wasCancelled) ?? false
        self.passedCount = try c.decode(Int.self, forKey: .passedCount)
        self.failedCount = try c.decode(Int.self, forKey: .failedCount)
        self.skippedCount = try c.decode(Int.self, forKey: .skippedCount)
        self.durationMs = try c.decode(Int.self, forKey: .durationMs)
        self.scenarios = try c.decodeIfPresent([ExecutedScenarioRecord].self, forKey: .scenarios) ?? []
        self.rawOutput = try c.decodeIfPresent(String.self, forKey: .rawOutput) ?? ""
        self.traceBundlePath = try c.decodeIfPresent(String.self, forKey: .traceBundlePath)
        self.htmlReportPath = try c.decodeIfPresent(String.self, forKey: .htmlReportPath)
    }

    public func strippingInlineDiagnostics() -> TestRunReport {
        TestRunReport(
            id: id,
            projectPath: projectPath,
            projectName: projectName,
            label: label,
            commandLine: commandLine,
            startedAt: startedAt,
            finishedAt: finishedAt,
            exitCode: exitCode,
            wasCancelled: wasCancelled,
            passedCount: passedCount,
            failedCount: failedCount,
            skippedCount: skippedCount,
            durationMs: durationMs,
            scenarios: scenarios.map { $0.strippingDiagnostics() },
            rawOutput: rawOutput,
            traceBundlePath: traceBundlePath,
            htmlReportPath: htmlReportPath
        )
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
