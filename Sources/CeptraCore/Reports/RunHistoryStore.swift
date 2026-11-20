import CryptoKit
import Foundation

public final class RunHistoryStore: @unchecked Sendable {
    private let baseDirectory: URL
    private let maxEntriesPerProject: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseDirectory: URL? = nil, maxEntriesPerProject: Int = 40) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.baseDirectory = appSupport
                .appendingPathComponent("Ceptra", isDirectory: true)
                .appendingPathComponent("history", isDirectory: true)
        }
        self.maxEntriesPerProject = maxEntriesPerProject

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public func loadHistory(forProjectPath projectPath: String) -> [TestRunReport] {
        let fileURL = storageURL(forProjectPath: projectPath)
        guard let data = try? Data(contentsOf: fileURL),
              let reports = try? decoder.decode([TestRunReport].self, from: data) else {
            return []
        }
        return reports.sorted { $0.startedAt > $1.startedAt }
    }

    public func append(_ report: TestRunReport) -> [TestRunReport] {
        var existing = loadHistory(forProjectPath: report.projectPath)
        existing.removeAll { $0.id == report.id }
        existing.insert(report, at: 0)
        if existing.count > maxEntriesPerProject {
            existing = Array(existing.prefix(maxEntriesPerProject))
        }
        save(existing, forProjectPath: report.projectPath)
        return existing
    }

    public func clearHistory(forProjectPath projectPath: String) {
        let fileURL = storageURL(forProjectPath: projectPath)
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save(_ reports: [TestRunReport], forProjectPath projectPath: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let fileURL = storageURL(forProjectPath: projectPath)
        if let data = try? encoder.encode(reports) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func storageURL(forProjectPath projectPath: String) -> URL {
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return baseDirectory.appendingPathComponent("\(hex).json")
    }
}
