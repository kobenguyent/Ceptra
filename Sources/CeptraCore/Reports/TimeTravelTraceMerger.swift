import Foundation

public enum TimeTravelTraceMerger {
    private struct WorkerTraceFile: Codable {
        let version: Int?
        let workerPid: Int?
        let scenarios: [ExecutedScenarioRecord]
    }

    /// Loads and sorts scenario traces written by one or more CodeceptJS worker processes.
    public static func loadWorkerTraces(from directoryURL: URL) -> [ExecutedScenarioRecord] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directoryURL.path),
              let entries = try? fm.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let decoder = makeISO8601Decoder()
        var collected: [ExecutedScenarioRecord] = []

        for fileURL in entries where fileURL.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let workerFile = try? decoder.decode(WorkerTraceFile.self, from: data) else {
                continue
            }
            collected.append(contentsOf: workerFile.scenarios)
        }

        return collected.sorted { lhs, rhs in
            let lDate = lhs.startedAt ?? Date.distantFuture
            let rDate = rhs.startedAt ?? Date.distantFuture
            if lDate != rDate { return lDate < rDate }
            return lhs.scenarioTitle < rhs.scenarioTitle
        }
    }

    /// Merges captured time-travel scenario traces into primary JUnit / live-parsed scenarios
    /// and ensures every step has a chronological timestamp for timeline scrubbing.
    public static func merge(
        primaryScenarios: [ExecutedScenarioRecord],
        traceScenarios: [ExecutedScenarioRecord],
        runStartedAt: Date
    ) -> [ExecutedScenarioRecord] {
        let merged: [ExecutedScenarioRecord]
        if traceScenarios.isEmpty {
            merged = primaryScenarios
        } else if primaryScenarios.isEmpty {
            merged = traceScenarios
        } else {
            var remainingTraces = traceScenarios
            var result: [ExecutedScenarioRecord] = []

            for primary in primaryScenarios {
                let key = matchKey(feature: primary.featureTitle, scenario: primary.scenarioTitle)
                if let matchIdx = remainingTraces.firstIndex(where: {
                    matchKey(feature: $0.featureTitle, scenario: $0.scenarioTitle) == key
                }) {
                    let trace = remainingTraces.remove(at: matchIdx)
                    result.append(combine(primary: primary, trace: trace))
                } else {
                    result.append(primary)
                }
            }
            result.append(contentsOf: remainingTraces)
            merged = result
        }

        return synthesizeMissingTimestamps(in: merged, runStartedAt: runStartedAt)
    }

    private static func combine(primary: ExecutedScenarioRecord, trace: ExecutedScenarioRecord) -> ExecutedScenarioRecord {
        let mergedSteps: [ExecutedStepRecord]
        if !trace.steps.isEmpty {
            mergedSteps = trace.steps.enumerated().map { idx, traceStep in
                let fallbackPrimary = idx < primary.steps.count ? primary.steps[idx] : nil
                return ExecutedStepRecord(
                    id: traceStep.id,
                    text: traceStep.text.isEmpty ? (fallbackPrimary?.text ?? "Step \(idx + 1)") : traceStep.text,
                    depth: traceStep.depth,
                    status: traceStep.status == .failed ? .failed : (fallbackPrimary?.status ?? traceStep.status),
                    durationMs: traceStep.durationMs ?? fallbackPrimary?.durationMs,
                    startedAt: traceStep.startedAt ?? fallbackPrimary?.startedAt,
                    finishedAt: traceStep.finishedAt ?? fallbackPrimary?.finishedAt,
                    targetSelector: traceStep.targetSelector ?? fallbackPrimary?.targetSelector,
                    errorMessage: traceStep.errorMessage ?? fallbackPrimary?.errorMessage,
                    diagnostics: traceStep.diagnostics ?? fallbackPrimary?.diagnostics
                )
            }
        } else {
            mergedSteps = primary.steps
        }

        let allTags = Array(Set(primary.tags + trace.tags)).sorted()
        return ExecutedScenarioRecord(
            id: primary.id,
            featureTitle: primary.featureTitle.isEmpty ? trace.featureTitle : primary.featureTitle,
            scenarioTitle: primary.scenarioTitle.isEmpty ? trace.scenarioTitle : primary.scenarioTitle,
            filePath: primary.filePath ?? trace.filePath,
            status: primary.status == .failed || trace.status == .failed ? .failed : primary.status,
            durationMs: primary.durationMs > 0 ? primary.durationMs : trace.durationMs,
            startedAt: trace.startedAt ?? primary.startedAt,
            finishedAt: trace.finishedAt ?? primary.finishedAt,
            tags: allTags,
            steps: mergedSteps,
            errorMessage: primary.errorMessage ?? trace.errorMessage,
            errorStack: primary.errorStack ?? trace.errorStack
        )
    }

    private static func synthesizeMissingTimestamps(
        in scenarios: [ExecutedScenarioRecord],
        runStartedAt: Date
    ) -> [ExecutedScenarioRecord] {
        var cursor = runStartedAt
        return scenarios.map { sc in
            let scStart = sc.startedAt ?? cursor
            var stepCursor = scStart
            let updatedSteps = sc.steps.map { step -> ExecutedStepRecord in
                let stStart = step.startedAt ?? stepCursor
                let durMs = step.durationMs ?? 0
                let stEnd = step.finishedAt ?? stStart.addingTimeInterval(Double(durMs) / 1000.0)
                stepCursor = max(stepCursor, stEnd)
                return ExecutedStepRecord(
                    id: step.id,
                    text: step.text,
                    depth: step.depth,
                    status: step.status,
                    durationMs: step.durationMs,
                    startedAt: stStart,
                    finishedAt: stEnd,
                    targetSelector: step.targetSelector,
                    errorMessage: step.errorMessage,
                    diagnostics: step.diagnostics
                )
            }
            let scEnd = sc.finishedAt ?? max(stepCursor, scStart.addingTimeInterval(Double(sc.durationMs) / 1000.0))
            cursor = max(cursor, scEnd)
            return ExecutedScenarioRecord(
                id: sc.id,
                featureTitle: sc.featureTitle,
                scenarioTitle: sc.scenarioTitle,
                filePath: sc.filePath,
                status: sc.status,
                durationMs: sc.durationMs,
                startedAt: scStart,
                finishedAt: scEnd,
                tags: sc.tags,
                steps: updatedSteps,
                errorMessage: sc.errorMessage,
                errorStack: sc.errorStack
            )
        }
    }

    private static func matchKey(feature: String, scenario: String) -> String {
        let f = feature.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let s = scenario.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(f)::\(s)"
    }

    static func makeISO8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = ISO8601FractionalFormatter.withFractional.date(from: str)
                ?? ISO8601FractionalFormatter.standard.date(from: str) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(str)")
        }
        return decoder
    }
}

private enum ISO8601FractionalFormatter {
    nonisolated(unsafe) static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let standard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// Persists heavy per-run time-travel trace bundles separately from `RunHistoryStore`
/// so startup remains fast while any recent run can be exported or opened with full telemetry.
public final class TimeTravelTraceStore: @unchecked Sendable {
    private let baseDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.baseDirectory = appSupport
                .appendingPathComponent("Ceptra", isDirectory: true)
                .appendingPathComponent("traces", isDirectory: true)
        }

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        self.decoder = TimeTravelTraceMerger.makeISO8601Decoder()
    }

    @discardableResult
    public func save(bundle: TimeTravelTraceBundle) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            let url = fileURL(forReportID: bundle.reportID)
            let data = try encoder.encode(bundle)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    public func load(reportID: UUID) -> TimeTravelTraceBundle? {
        load(path: fileURL(forReportID: reportID).path)
    }

    public func load(path: String) -> TimeTravelTraceBundle? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? decoder.decode(TimeTravelTraceBundle.self, from: data)
    }

    public func remove(reportID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(forReportID: reportID))
    }

    public func prune(keepingReportIDs keepIDs: Set<UUID>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        let keepNames = Set(keepIDs.map { "\($0.uuidString).json" })
        for url in files where url.pathExtension.lowercased() == "json" {
            if !keepNames.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        }
    }

    private func fileURL(forReportID id: UUID) -> URL {
        baseDirectory.appendingPathComponent("\(id.uuidString).json")
    }
}
