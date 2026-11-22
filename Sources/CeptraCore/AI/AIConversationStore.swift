import Foundation

/// Persists per-workspace AI chat sessions locally under Application Support.
/// Security invariant: stores only non-secret message text & metadata; runs secret redaction
/// before writing and caps session/message counts to prevent unbounded disk growth.
public final class AIConversationStore: @unchecked Sendable {
    public static let maxSessionsPerWorkspace = 20
    public static let maxMessagesPerSession = 40

    private let baseDirectory: URL
    private let fm: FileManager

    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fm = fileManager
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.baseDirectory = appSupport
                .appendingPathComponent("Ceptra", isDirectory: true)
                .appendingPathComponent("ai-sessions", isDirectory: true)
        }
    }

    public func loadSessions(forWorkspacePath workspacePath: String) -> [AIChatSession] {
        let url = fileURL(forWorkspacePath: workspacePath)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([AIChatSession].self, from: data) else { return [] }
        return decoded
            .filter { !$0.messages.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func saveSessions(
        _ sessions: [AIChatSession],
        forWorkspacePath workspacePath: String,
        explicitSecretsToStrip: [String] = []
    ) {
        let nonEmpty = sessions.filter { !$0.messages.isEmpty }
        if nonEmpty.isEmpty {
            clearSessions(forWorkspacePath: workspacePath)
            return
        }

        let capped = Array(
            nonEmpty
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(Self.maxSessionsPerWorkspace)
        ).map { session -> AIChatSession in
            var copy = session
            let trimmedMessages = Array(session.messages.suffix(Self.maxMessagesPerSession))
            copy.messages = trimmedMessages.map { msg in
                var m = msg
                m.content = AISecretRedactor.redact(msg.content, explicitSecrets: explicitSecretsToStrip).text
                // Strip raw wire image base64 payloads on disk; lightweight thumbnails remain in attachedSummaries
                m.images = []
                return m
            }
            return copy
        }

        do {
            try fm.createDirectory(
                at: baseDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDirectory.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(capped)
            let url = fileURL(forWorkspacePath: workspacePath)
            try data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Best-effort local persistence; never crash UI on disk error
        }
    }

    public func clearSessions(forWorkspacePath workspacePath: String) {
        let url = fileURL(forWorkspacePath: workspacePath)
        try? fm.removeItem(at: url)
    }

    private func fileURL(forWorkspacePath workspacePath: String) -> URL {
        let normalized = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
        let hash = Self.stableFNV1aHex(normalized)
        return baseDirectory.appendingPathComponent("ws-\(hash).json")
    }

    private static func stableFNV1aHex(_ string: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
