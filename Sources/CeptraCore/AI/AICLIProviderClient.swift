import Foundation

public struct DetectedCLIAgent: Equatable, Identifiable, Sendable {
    public var id: String { kind.rawValue }
    public let kind: AIProviderKind
    public let executablePath: String?
    public let binaryName: String?

    public var isInstalled: Bool { executablePath != nil }

    public init(kind: AIProviderKind, executablePath: String?, binaryName: String?) {
        self.kind = kind
        self.executablePath = executablePath
        self.binaryName = binaryName
    }
}

public struct AICLIInvocation: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let stdinPrompt: String?
    public let workingDirectory: URL?
    public let usesClaudeStreamJSON: Bool

    public init(
        executableURL: URL,
        arguments: [String],
        stdinPrompt: String?,
        workingDirectory: URL?,
        usesClaudeStreamJSON: Bool
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.stdinPrompt = stdinPrompt
        self.workingDirectory = workingDirectory
        self.usesClaudeStreamJSON = usesClaudeStreamJSON
    }
}

/// Safe local CLI bridge for `claude`, `copilot` / `gh copilot`, and `codex`.
/// Security invariants (T-03):
/// - Direct `Process` execution (`executableURL` + `arguments` array); NEVER `/bin/sh -c`.
/// - Enforces read-only / non-editing flags so CLI agents cannot silently modify workspace files.
/// - Cleanly terminates active child processes on cancel or app quit.
public final class AICLIProviderClient: @unchecked Sendable {
    public static let maxResponseBytes = 512 * 1024

    private let lock = NSLock()
    private var activeProcesses: [UUID: Process] = [:]

    public init() {}

    public func cancelAll() {
        let procs: [Process] = lock.withLock {
            let values = Array(activeProcesses.values)
            activeProcesses.removeAll()
            return values
        }
        for proc in procs where proc.isRunning {
            proc.terminate()
        }
    }

    // MARK: - Binary Detection

    public static func detectInstalledCLIs(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [DetectedCLIAgent] {
        let cliKinds: [AIProviderKind] = [.claudeCLI, .copilotCLI, .codexCLI]
        return cliKinds.map { kind in
            if let resolved = resolveExecutable(for: kind, customPath: "", environment: environment) {
                return DetectedCLIAgent(
                    kind: kind,
                    executablePath: resolved.path,
                    binaryName: resolved.lastPathComponent
                )
            }
            return DetectedCLIAgent(kind: kind, executablePath: nil, binaryName: nil)
        }
    }

    public static func resolveExecutable(
        for kind: AIProviderKind,
        customPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let fm = FileManager.default
        let trimmedCustom = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustom.isEmpty {
            let expanded = (trimmedCustom as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: expanded, isDirectory: &isDir),
               !isDir.boolValue,
               fm.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
            return nil
        }

        let searchDirs = buildSearchDirectories(environment: environment)
        for name in kind.cliExecutableNames {
            // For GitHub Copilot CLI, plain `gh` only qualifies when the `gh-copilot` extension is installed.
            if kind == .copilotCLI && name == "gh" && !hasGHCopilotExtension(environment: environment) {
                continue
            }
            for dir in searchDirs {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name).path
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate, isDirectory: &isDir),
                   !isDir.boolValue,
                   fm.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        return nil
    }

    public static func hasGHCopilotExtension(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let fm = FileManager.default
        let home = environment["HOME"] ?? fm.homeDirectoryForCurrentUser.path
        var candidateDirs: [String] = []
        if let xdgData = environment["XDG_DATA_HOME"], !xdgData.isEmpty {
            candidateDirs.append(URL(fileURLWithPath: xdgData).appendingPathComponent("gh/extensions/gh-copilot").path)
        }
        candidateDirs.append(URL(fileURLWithPath: home).appendingPathComponent(".local/share/gh/extensions/gh-copilot").path)
        return candidateDirs.contains { fm.fileExists(atPath: $0) }
    }

    public static func buildSearchDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs: [String] = []
        if let pathEnv = environment["PATH"] {
            dirs.append(contentsOf: pathEnv.split(separator: ":").map(String.init))
        }
        dirs.append(contentsOf: [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin"
        ])
        // Deduplicate while preserving priority order
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static let allowedEnvironmentKeys: Set<String> = [
        "HOME", "USER", "LOGNAME", "TMPDIR",
        "LANG", "LC_ALL", "LC_CTYPE",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
        "http_proxy", "https_proxy", "no_proxy", "all_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"
    ]

    /// Constructs a minimal, secret-scrubbed environment for CLI subprocesses so arbitrary host
    /// secrets (`AWS_*`, `DATABASE_URL`, `*_TOKEN`, `*_KEY`, `SSH_AUTH_SOCK`, `DYLD_*`) are never leaked.
    public static func buildSanitizedEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var sanitized: [String: String] = [:]
        for key in allowedEnvironmentKeys {
            if let val = base[key], !val.isEmpty {
                sanitized[key] = val
            }
        }
        sanitized["PATH"] = buildSearchDirectories(environment: base).joined(separator: ":")
        sanitized["NO_COLOR"] = "1"
        sanitized["TERM"] = "dumb"
        sanitized["CI"] = "1"
        return sanitized
    }

    /// Returns an isolated, empty `0700` directory so CLI subprocesses cannot auto-scan workspace
    /// dotfiles (`.env`, `.mcp.json`, hooks) or mutate project files in the current working directory.
    public static func isolatedSandboxDirectory() -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ceptra-ai-cli-sandbox", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    // MARK: - Safe Invocation Builder (Testable)

    public static func buildInvocation(
        profile: AIProviderProfile,
        request: AIChatRequest,
        resolvedExecutable: URL
    ) throws -> AICLIInvocation {
        let prompt = formatConversationPrompt(request: request)
        let model = profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let binName = resolvedExecutable.lastPathComponent.lowercased()
        let sandboxCwd = isolatedSandboxDirectory()

        // Full Workspace mode runs inside workspaceRoot ONLY if it is a safe non-sensitive directory.
        // Sensitive directories (~/.ssh, ~/.aws, /etc, home root, etc.) always fall back to the empty sandbox.
        let safeWorkspaceCwd: URL? = {
            guard request.permissionMode.allowsCLIWorkspaceTools,
                  let ws = request.workspaceRoot else {
                return nil
            }
            let resolved = ws.standardizedFileURL.resolvingSymlinksInPath()
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
            if resolved.path == "/" || resolved.path == home.path {
                return nil
            }
            if AIMediaAttachmentProcessor.isBlockedSecretFile(url: resolved)
                || AIMediaAttachmentProcessor.isBlockedSecretFile(url: ws) {
                return nil
            }
            return resolved
        }()
        let effectiveCwd = safeWorkspaceCwd ?? sandboxCwd
        let grantWorkspaceTools = safeWorkspaceCwd != nil

        switch profile.kind {
        case .claudeCLI:
            var args: [String]
            if grantWorkspaceTools {
                // Workspace-scoped file tools only (no Bash shell tool) with edit acceptance inside active project
                args = [
                    "-p", "--output-format", "stream-json", "--verbose",
                    "--allowedTools", "Read,Edit,Write,Glob,Grep",
                    "--permission-mode", "acceptEdits"
                ]
            } else {
                // Read-only non-interactive print mode with zero tools in an isolated empty sandbox directory
                args = ["-p", "--output-format", "stream-json", "--verbose", "--tools", ""]
            }
            if !model.isEmpty && model.lowercased() != "default" {
                args.append(contentsOf: ["--model", model])
            }
            return AICLIInvocation(
                executableURL: resolvedExecutable,
                arguments: args,
                stdinPrompt: prompt,
                workingDirectory: effectiveCwd,
                usesClaudeStreamJSON: true
            )

        case .codexCLI:
            let sandboxArg = grantWorkspaceTools ? "workspace-write" : "read-only"
            var args = ["exec", "--sandbox", sandboxArg]
            if !model.isEmpty && model.lowercased() != "default" {
                args.append(contentsOf: ["-m", model])
            }
            if let lastImages = request.messages.last(where: { $0.role == .user })?.images {
                for img in lastImages {
                    if let path = img.localFilePath,
                       !path.isEmpty,
                       !AIMediaAttachmentProcessor.isBlockedSecretFile(url: URL(fileURLWithPath: path)) {
                        args.append(contentsOf: ["-i", path])
                    }
                }
            }
            args.append("-")
            return AICLIInvocation(
                executableURL: resolvedExecutable,
                arguments: args,
                stdinPrompt: prompt,
                workingDirectory: effectiveCwd,
                usesClaudeStreamJSON: false
            )

        case .copilotCLI:
            // Direct execve (zero shell interpolation); runs in isolated sandbox unless workspace mode enabled
            if binName == "gh" {
                return AICLIInvocation(
                    executableURL: resolvedExecutable,
                    arguments: ["copilot", "explain", prompt],
                    stdinPrompt: nil,
                    workingDirectory: effectiveCwd,
                    usesClaudeStreamJSON: false
                )
            } else {
                var args = ["-p", prompt, "--silent"]
                if !model.isEmpty && model.lowercased() != "default" {
                    args.append(contentsOf: ["--model", model])
                }
                return AICLIInvocation(
                    executableURL: resolvedExecutable,
                    arguments: args,
                    stdinPrompt: nil,
                    workingDirectory: effectiveCwd,
                    usesClaudeStreamJSON: false
                )
            }

        default:
            throw AIProviderError.invalidBaseURL("\(profile.kind.displayName) is not a CLI provider.")
        }
    }

    public static func formatConversationPrompt(request: AIChatRequest) -> String {
        var sections: [String] = []
        if !request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("System Instructions:\n\(request.systemPrompt)")
        }
        let nonSystem = request.messages.filter { $0.role != .system }
        if nonSystem.count == 1, let only = nonSystem.first {
            sections.append(only.content)
        } else {
            let transcript = nonSystem.map { msg -> String in
                let speaker = msg.role == .assistant ? "Assistant" : "User"
                return "\(speaker):\n\(msg.content)"
            }.joined(separator: "\n\n---\n\n")
            sections.append("Conversation:\n\(transcript)\n\nRespond to the latest User message above.")
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Connection Test & Streaming Execution

    public func testConnection(profile: AIProviderProfile) async throws -> AIConnectionTestResult {
        let start = Date()
        let trimmedCustom = profile.customCLIPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let executable = Self.resolveExecutable(for: profile.kind, customPath: trimmedCustom) else {
            if !trimmedCustom.isEmpty {
                throw AIProviderError.invalidCLIPath(trimmedCustom)
            }
            throw AIProviderError.cliNotFound(
                kind: profile.kind,
                searchedHint: "expected \(profile.kind.cliExecutableNames.joined(separator: " or ")) on PATH"
            )
        }

        let versionArgs = executable.lastPathComponent.lowercased() == "gh" ? ["copilot", "--version"] : ["--version"]
        let versionOutput = try await runQuickVersionProbe(executableURL: executable, arguments: versionArgs)
        let latencyMs = max(1, Int(Date().timeIntervalSince(start) * 1000))
        let firstLine = versionOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? executable.lastPathComponent
        let models = profile.kind.curatedModels.map { AIModelDescriptor(id: $0) }
        return AIConnectionTestResult(
            ok: true,
            latencyMs: latencyMs,
            summary: "Detected \(executable.path) (\(firstLine))",
            discoveredModels: models
        )
    }

    public func streamChat(
        request: AIChatRequest,
        profile: AIProviderProfile
    ) -> AsyncThrowingStream<AIStreamDelta, Error> {
        return AsyncThrowingStream { continuation in
            let runID = UUID()
            let task = Task.detached(priority: .userInitiated) {
                let trimmedCustom = profile.customCLIPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let executable = Self.resolveExecutable(for: profile.kind, customPath: trimmedCustom) else {
                    if !trimmedCustom.isEmpty {
                        continuation.finish(throwing: AIProviderError.invalidCLIPath(trimmedCustom))
                    } else {
                        continuation.finish(throwing: AIProviderError.cliNotFound(
                            kind: profile.kind,
                            searchedHint: "expected \(profile.kind.cliExecutableNames.joined(separator: " or ")) on PATH"
                        ))
                    }
                    return
                }

                let invocation: AICLIInvocation
                do {
                    invocation = try Self.buildInvocation(profile: profile, request: request, resolvedExecutable: executable)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                let process = Process()
                process.executableURL = invocation.executableURL
                process.arguments = invocation.arguments
                process.currentDirectoryURL = invocation.workingDirectory ?? Self.isolatedSandboxDirectory()
                process.environment = Self.buildSanitizedEnvironment()

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let stdinPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = stdinPipe

                self.lock.withLock {
                    self.activeProcesses[runID] = process
                }
                defer {
                    _ = self.lock.withLock {
                        self.activeProcesses.removeValue(forKey: runID)
                    }
                    if process.isRunning {
                        process.terminate()
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.finish(throwing: AIProviderError.networkFailure("Failed to launch \(executable.lastPathComponent): \(error.localizedDescription)"))
                    return
                }

                if let stdinText = invocation.stdinPrompt, let data = stdinText.data(using: .utf8) {
                    try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
                }
                try? stdinPipe.fileHandleForWriting.close()

                let stderrBuffer = LockedStringBuffer()
                let stderrTask = Task.detached {
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if let text = String(data: data, encoding: .utf8) {
                        stderrBuffer.append(text)
                    }
                }

                var claudeParser = ClaudeCLIStreamJSONLineParser()
                var emittedBytes = 0
                var streamError: Error? = nil

                do {
                    for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                        if Task.isCancelled {
                            if process.isRunning { process.terminate() }
                            continuation.finish(throwing: AIProviderError.cancelled)
                            return
                        }
                        if invocation.usesClaudeStreamJSON {
                            let deltas = try claudeParser.consume(line: line)
                            for delta in deltas {
                                if case .text(let chunk) = delta {
                                    emittedBytes += chunk.utf8.count
                                    if emittedBytes > Self.maxResponseBytes {
                                        if process.isRunning { process.terminate() }
                                        continuation.finish(throwing: AIProviderError.responseTooLarge(limitBytes: Self.maxResponseBytes))
                                        return
                                    }
                                }
                                continuation.yield(delta)
                            }
                        } else {
                            let chunk = line + "\n"
                            emittedBytes += chunk.utf8.count
                            if emittedBytes > Self.maxResponseBytes {
                                if process.isRunning { process.terminate() }
                                continuation.finish(throwing: AIProviderError.responseTooLarge(limitBytes: Self.maxResponseBytes))
                                return
                            }
                            continuation.yield(.text(chunk))
                        }
                    }
                } catch {
                    streamError = error
                }

                process.waitUntilExit()
                await stderrTask.value

                if Task.isCancelled {
                    continuation.finish(throwing: AIProviderError.cancelled)
                    return
                }
                if let streamError {
                    continuation.finish(throwing: streamError)
                    return
                }
                if process.terminationStatus != 0 && emittedBytes == 0 {
                    let rawErr = stderrBuffer.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    let redacted = AISecretRedactor.redact(String(rawErr.prefix(320))).text
                    continuation.finish(throwing: AIProviderError.cliProcessFailure(
                        exitCode: process.terminationStatus,
                        message: redacted.isEmpty ? "Ensure you are signed in to \(profile.kind.displayName)." : redacted
                    ))
                    return
                }

                continuation.yield(.completed(stopReason: "stop"))
                continuation.finish()
            }

            continuation.onTermination = { [weak self] _ in
                task.cancel()
                guard let self else { return }
                let proc: Process? = self.lock.withLock { self.activeProcesses.removeValue(forKey: runID) }
                if let proc, proc.isRunning {
                    proc.terminate()
                }
            }
        }
    }

    private func runQuickVersionProbe(executableURL: URL, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = executableURL
            proc.arguments = arguments
            proc.currentDirectoryURL = Self.isolatedSandboxDirectory()
            proc.environment = Self.buildSanitizedEnvironment()
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""
            return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? err : out
        }.value
    }
}

private final class LockedStringBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ s: String) {
        lock.withLock { storage.append(s) }
    }

    var value: String {
        lock.withLock { storage }
    }
}
