import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Local Ollama Models & Runtime State

public struct OllamaInstalledModel: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let sizeBytes: Int64
    public let parameterSize: String?
    public let quantizationLevel: String?
    public let family: String?
    public let modifiedAt: String?

    public init(
        name: String,
        sizeBytes: Int64 = 0,
        parameterSize: String? = nil,
        quantizationLevel: String? = nil,
        family: String? = nil,
        modifiedAt: String? = nil
    ) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.parameterSize = parameterSize
        self.quantizationLevel = quantizationLevel
        self.family = family
        self.modifiedAt = modifiedAt
    }

    public var formattedSize: String {
        guard sizeBytes > 0 else { return "" }
        let gb = Double(sizeBytes) / 1_000_000_000.0
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(sizeBytes) / 1_000_000.0
        return String(format: "%.0f MB", max(1, mb))
    }

    public var compactDetails: String {
        var parts: [String] = []
        if !formattedSize.isEmpty { parts.append(formattedSize) }
        if let parameterSize, !parameterSize.isEmpty { parts.append(parameterSize) }
        if let quantizationLevel, !quantizationLevel.isEmpty { parts.append(quantizationLevel) }
        return parts.joined(separator: " · ")
    }
}

public struct OllamaCatalogModel: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let approximateSize: String
    public let ramHint: String
    public let summary: String
    public let badge: String?

    public init(id: String, approximateSize: String, ramHint: String, summary: String, badge: String? = nil) {
        self.id = id
        self.approximateSize = approximateSize
        self.ramHint = ramHint
        self.summary = summary
        self.badge = badge
    }

    public static let recommendedCodingModels: [OllamaCatalogModel] = [
        OllamaCatalogModel(
            id: "qwen2.5-coder:3b",
            approximateSize: "~1.9 GB",
            ramHint: "8 GB+ RAM",
            summary: "Fast & lightweight for JS/TS and quick test edits"
        ),
        OllamaCatalogModel(
            id: "qwen2.5-coder:7b",
            approximateSize: "~4.7 GB",
            ramHint: "16 GB+ RAM",
            summary: "Best balance for CodeceptJS scenarios, page objects & locators",
            badge: "Recommended"
        ),
        OllamaCatalogModel(
            id: "qwen2.5-coder:14b",
            approximateSize: "~9.0 GB",
            ramHint: "24 GB+ RAM",
            summary: "Higher accuracy for complex refactors & flaky test analysis"
        ),
        OllamaCatalogModel(
            id: "llama3.2:3b",
            approximateSize: "~2.0 GB",
            ramHint: "8 GB+ RAM",
            summary: "Fast general Q&A and step-by-step explanations"
        ),
        OllamaCatalogModel(
            id: "deepseek-r1:8b",
            approximateSize: "~4.9 GB",
            ramHint: "16 GB+ RAM",
            summary: "Step-by-step reasoning for failure diagnosis & debugging"
        )
    ]
}

public enum OllamaRuntimeState: Equatable, Sendable {
    case unknown
    case notInstalled(homebrewPath: String?)
    case installedNotRunning(appURL: URL?, cliURL: URL?)
    case runningNoModels
    case running(models: [OllamaInstalledModel])
    case remoteUnreachable(message: String)

    public var isRunning: Bool {
        switch self {
        case .running, .runningNoModels:
            return true
        default:
            return false
        }
    }

    public var installedModels: [OllamaInstalledModel] {
        switch self {
        case .running(let models):
            return models
        default:
            return []
        }
    }
}

public struct OllamaPullProgress: Equatable, Sendable {
    public let modelName: String
    public let status: String
    public let completedBytes: Int64?
    public let totalBytes: Int64?
    public let isComplete: Bool

    public init(
        modelName: String,
        status: String,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        isComplete: Bool = false
    ) {
        self.modelName = modelName
        self.status = status
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.isComplete = isComplete
    }

    public var fraction: Double? {
        if isComplete { return 1.0 }
        guard let completed = completedBytes, let total = totalBytes, total > 0 else { return nil }
        return min(max(Double(completed) / Double(total), 0.0), 1.0)
    }

    public var percentageText: String? {
        guard let f = fraction else { return nil }
        return "\(Int((f * 100.0).rounded()))%"
    }

    public var byteProgressText: String? {
        guard let completed = completedBytes, let total = totalBytes, total > 0 else { return nil }
        return "\(Self.formatBytes(completed)) / \(Self.formatBytes(total))"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000.0
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / 1_000_000.0
        return String(format: "%.0f MB", max(1, mb))
    }
}

public enum OllamaManagerError: LocalizedError, Equatable, Sendable {
    case invalidModelName(String)
    case remoteHostNotEligibleForLocalControl
    case ollamaNotFound
    case serverStartTimedOut
    case pullFailed(String)
    case deleteFailed(String)
    case installFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidModelName(let name):
            return "Invalid Ollama model name '\(name)'. Use tags like 'qwen2.5-coder:7b' or 'llama3.2:3b'."
        case .remoteHostNotEligibleForLocalControl:
            return "Local Ollama install/start is only available for loopback endpoints (127.0.0.1 / localhost)."
        case .ollamaNotFound:
            return "Ollama is not installed on this Mac yet."
        case .serverStartTimedOut:
            return "Ollama was launched but did not respond at 127.0.0.1:11434 within 12 seconds. Check the Ollama menu-bar icon or click Refresh."
        case .pullFailed(let msg):
            return "Failed to pull model: \(msg)"
        case .deleteFailed(let msg):
            return "Failed to delete model: \(msg)"
        case .installFailed(let msg):
            return "Homebrew install failed: \(msg)"
        case .cancelled:
            return "Operation cancelled."
        }
    }
}

// MARK: - OllamaManager Service

/// Zero-dependency, testable manager for Local Ollama discovery, 1-click install/start,
/// native NDJSON streaming `POST /api/pull`, and `DELETE /api/delete`.
public final class OllamaManager: @unchecked Sendable {
    public static let downloadPageURL = URL(string: "https://ollama.com/download/mac")!

    private let probeTransport: AIHTTPTransport
    private let streamTransport: AIHTTPTransport
    private let lock = NSLock()
    private var activeBrewProcess: Process?
    private var activeServeProcess: Process?

    public init(
        probeTransport: AIHTTPTransport = URLSessionAIHTTPTransport(connectTimeoutSeconds: 2.5, idleTimeoutSeconds: 4.0),
        streamTransport: AIHTTPTransport = URLSessionAIHTTPTransport(connectTimeoutSeconds: 30, idleTimeoutSeconds: 3600)
    ) {
        self.probeTransport = probeTransport
        self.streamTransport = streamTransport
    }

    public func cancelAllProcesses() {
        let procs: [Process] = lock.withLock {
            var list: [Process] = []
            if let brew = activeBrewProcess { list.append(brew); activeBrewProcess = nil }
            return list
        }
        for proc in procs where proc.isRunning {
            proc.terminate()
        }
    }

    // MARK: - Validation & Parsing (Pure & Testable)

    public static func validateModelName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else {
            throw OllamaManagerError.invalidModelName(raw)
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/-")
        guard let first = trimmed.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first),
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw OllamaManagerError.invalidModelName(raw)
        }
        return trimmed
    }

    public static func parseTagsResponse(_ data: Data) throws -> [OllamaInstalledModel] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else {
            return []
        }

        return models.compactMap { entry in
            guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
            let sizeNum: Int64
            if let s = entry["size"] as? Int64 {
                sizeNum = s
            } else if let s = entry["size"] as? Int {
                sizeNum = Int64(s)
            } else if let s = entry["size"] as? Double {
                sizeNum = Int64(s)
            } else {
                sizeNum = 0
            }
            let details = entry["details"] as? [String: Any]
            let paramSize = details?["parameter_size"] as? String
            let quant = details?["quantization_level"] as? String
            let family = details?["family"] as? String
            let modified = entry["modified_at"] as? String
            return OllamaInstalledModel(
                name: name,
                sizeBytes: sizeNum,
                parameterSize: paramSize,
                quantizationLevel: quant,
                family: family,
                modifiedAt: modified
            )
        }
    }

    public static func parsePullProgressLine(_ line: String, modelName: String) throws -> OllamaPullProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let errMsg = obj["error"] as? String, !errMsg.isEmpty {
            throw OllamaManagerError.pullFailed(errMsg)
        }

        let status = (obj["status"] as? String) ?? "downloading"
        let completed = Self.extractInt64(obj["completed"])
        let total = Self.extractInt64(obj["total"])
        let isComplete = status.lowercased() == "success"
        return OllamaPullProgress(
            modelName: modelName,
            status: status,
            completedBytes: completed,
            totalBytes: total,
            isComplete: isComplete
        )
    }

    public static func buildPullRequest(
        modelName: String,
        baseURL: String,
        allowInsecureLocalHTTP: Bool = false,
        apiKey: String? = nil
    ) throws -> URLRequest {
        let validModel = try validateModelName(modelName)
        let validatedURL = try AIURLValidator.validateBaseURL(
            baseURL,
            allowInsecureLocalHTTP: allowInsecureLocalHTTP
        )
        var request = URLRequest(url: validatedURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        if let cleanKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !cleanKey.isEmpty {
            request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["name": validModel, "stream": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public static func buildDeleteRequest(
        modelName: String,
        baseURL: String,
        allowInsecureLocalHTTP: Bool = false,
        apiKey: String? = nil
    ) throws -> URLRequest {
        let validModel = try validateModelName(modelName)
        let validatedURL = try AIURLValidator.validateBaseURL(
            baseURL,
            allowInsecureLocalHTTP: allowInsecureLocalHTTP
        )
        var request = URLRequest(url: validatedURL.appendingPathComponent("api/delete"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let cleanKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !cleanKey.isEmpty {
            request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["name": validModel]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Local Installation & Binary Detection

    public static func detectLocalAppURL() -> URL? {
        let fm = FileManager.default
        let candidates = [
            "/Applications/Ollama.app",
            "\(fm.homeDirectoryForCurrentUser.path)/Applications/Ollama.app"
        ]
        for path in candidates where fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public static func detectLocalCLIURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let fm = FileManager.default
        var dirs = AICLIProviderClient.buildSearchDirectories(environment: environment)
        dirs.append("/Applications/Ollama.app/Contents/Resources")
        for dir in dirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("ollama").path
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir),
               !isDir.boolValue,
               fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    public static func detectHomebrewURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let fm = FileManager.default
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin"] + AICLIProviderClient.buildSearchDirectories(environment: environment)
        for dir in dirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("brew").path
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir),
               !isDir.boolValue,
               fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    // MARK: - Live Probing

    public func probeStatus(
        baseURL: String,
        allowInsecureLocalHTTP: Bool = false,
        apiKey: String? = nil
    ) async -> OllamaRuntimeState {
        let cleanBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AIProviderKind.ollama.defaultBaseURL
            : baseURL
        let isLoopback = AIURLValidator.isLoopbackBaseURL(cleanBase)

        do {
            let validated = try AIURLValidator.validateBaseURL(
                cleanBase,
                allowInsecureLocalHTTP: allowInsecureLocalHTTP
            )
            var request = URLRequest(url: validated.appendingPathComponent("api/tags"))
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let cleanKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !cleanKey.isEmpty {
                request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
            }

            let response = try await probeTransport.data(for: request)
            if (200..<300).contains(response.statusCode) {
                let models = (try? Self.parseTagsResponse(response.body)) ?? []
                return models.isEmpty ? .runningNoModels : .running(models: models)
            }
            if !isLoopback {
                return .remoteUnreachable(message: "Remote Ollama server returned HTTP \(response.statusCode).")
            }
        } catch {
            if !isLoopback {
                return .remoteUnreachable(message: error.localizedDescription)
            }
        }

        // Loopback server didn't respond — determine whether Ollama is installed or missing
        let appURL = Self.detectLocalAppURL()
        let cliURL = Self.detectLocalCLIURL()
        if appURL != nil || cliURL != nil {
            return .installedNotRunning(appURL: appURL, cliURL: cliURL)
        }
        return .notInstalled(homebrewPath: Self.detectHomebrewURL()?.path)
    }

    // MARK: - 1-Click Start Local Server

    public func startLocalServer(
        baseURL: String,
        appURL: URL? = nil,
        cliURL: URL? = nil
    ) async throws -> OllamaRuntimeState {
        guard AIURLValidator.isLoopbackBaseURL(baseURL) else {
            throw OllamaManagerError.remoteHostNotEligibleForLocalControl
        }

        let resolvedApp = appURL ?? Self.detectLocalAppURL()
        let resolvedCLI = cliURL ?? Self.detectLocalCLIURL()

        if let resolvedApp {
            #if canImport(AppKit)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: resolvedApp, configuration: config)
            #endif
        } else if let resolvedCLI {
            let process = Process()
            process.executableURL = resolvedCLI
            process.arguments = ["serve"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            lock.withLock {
                activeServeProcess = process
            }
        } else {
            throw OllamaManagerError.ollamaNotFound
        }

        // Poll up to 12 seconds for local daemon to accept requests
        for _ in 0..<20 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 600_000_000)
            let status = await probeStatus(baseURL: baseURL)
            if status.isRunning {
                return status
            }
        }
        throw OllamaManagerError.serverStartTimedOut
    }

    // MARK: - 1-Click Homebrew Install (Direct Process, Zero Shell)

    public func installViaHomebrew(brewPath: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let brewURL = URL(fileURLWithPath: brewPath)
                let process = Process()
                process.executableURL = brewURL
                process.arguments = ["install", "--cask", "ollama"]
                var env = ProcessInfo.processInfo.environment
                env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
                process.environment = env

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                self.lock.withLock { self.activeBrewProcess = process }

                do {
                    try process.run()
                } catch {
                    self.lock.withLock { self.activeBrewProcess = nil }
                    continuation.finish(throwing: OllamaManagerError.installFailed(error.localizedDescription))
                    return
                }

                let handle = pipe.fileHandleForReading
                var tailLine = ""
                do {
                    for try await line in handle.bytes.lines {
                        if Task.isCancelled {
                            if process.isRunning { process.terminate() }
                            self.lock.withLock { self.activeBrewProcess = nil }
                            continuation.finish(throwing: OllamaManagerError.cancelled)
                            return
                        }
                        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty {
                            tailLine = cleaned
                            continuation.yield(cleaned)
                        }
                    }
                } catch {
                    if process.isRunning { process.terminate() }
                    self.lock.withLock { self.activeBrewProcess = nil }
                    continuation.finish(throwing: OllamaManagerError.installFailed(error.localizedDescription))
                    return
                }

                process.waitUntilExit()
                self.lock.withLock { self.activeBrewProcess = nil }

                if process.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    let detail = tailLine.isEmpty ? "Exit code \(process.terminationStatus)" : tailLine
                    continuation.finish(throwing: OllamaManagerError.installFailed(detail))
                }
            }

            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.cancelAllProcesses()
            }
        }
    }

    // MARK: - Streaming Model Pull (`POST /api/pull`)

    public func pullModel(
        name: String,
        baseURL: String,
        allowInsecureLocalHTTP: Bool = false,
        apiKey: String? = nil
    ) -> AsyncThrowingStream<OllamaPullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let validName = try Self.validateModelName(name)
                    let request = try Self.buildPullRequest(
                        modelName: validName,
                        baseURL: baseURL,
                        allowInsecureLocalHTTP: allowInsecureLocalHTTP,
                        apiKey: apiKey
                    )
                    let response = try await streamTransport.streamLines(for: request)
                    guard (200..<300).contains(response.statusCode) else {
                        var errLines: [String] = []
                        for try await line in response.lines {
                            errLines.append(line)
                            if errLines.count >= 8 { break }
                        }
                        let msg = errLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                        throw OllamaManagerError.pullFailed(msg.isEmpty ? "HTTP \(response.statusCode)" : msg)
                    }

                    for try await line in response.lines {
                        if Task.isCancelled {
                            continuation.finish(throwing: OllamaManagerError.cancelled)
                            return
                        }
                        if let progress = try Self.parsePullProgressLine(line, modelName: validName) {
                            continuation.yield(progress)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: OllamaManagerError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Model Deletion (`DELETE /api/delete`)

    public func deleteModel(
        name: String,
        baseURL: String,
        allowInsecureLocalHTTP: Bool = false,
        apiKey: String? = nil
    ) async throws {
        let request = try Self.buildDeleteRequest(
            modelName: name,
            baseURL: baseURL,
            allowInsecureLocalHTTP: allowInsecureLocalHTTP,
            apiKey: apiKey
        )
        let response = try await probeTransport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let text = String(data: response.body, encoding: .utf8) ?? "HTTP \(response.statusCode)"
            throw OllamaManagerError.deleteFailed(text)
        }
    }

    // MARK: - Helpers

    private static func extractInt64(_ raw: Any?) -> Int64? {
        if let v = raw as? Int64 { return v }
        if let v = raw as? Int { return Int64(v) }
        if let v = raw as? Double { return Int64(v) }
        return nil
    }
}
