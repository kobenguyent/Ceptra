import Darwin
import Foundation

public enum CodeceptUIServerStatus: Equatable, Sendable {
    case stopped
    case starting(port: Int)
    case running(url: URL, port: Int)
    case failed(message: String)

    public var isActive: Bool {
        switch self {
        case .starting, .running:
            return true
        case .stopped, .failed:
            return false
        }
    }

    public var activeURL: URL? {
        if case .running(let url, _) = self {
            return url
        }
        return nil
    }

    public var activePort: Int? {
        switch self {
        case .starting(let port), .running(_, let port):
            return port
        case .stopped, .failed:
            return nil
        }
    }
}

public enum CodeceptUIServerError: Error, LocalizedError, Sendable {
    case portAllocationFailed
    case invalidLoopbackURL

    public var errorDescription: String? {
        switch self {
        case .portAllocationFailed:
            return "Unable to allocate a free local loopback port for @codeceptjs/ui."
        case .invalidLoopbackURL:
            return "Failed to construct a valid 127.0.0.1 URL for @codeceptjs/ui."
        }
    }
}

public final class CodeceptUIServerManager: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProcess: Process?
    private var activePortValue: Int?

    public init() {}

    public var isRunning: Bool {
        lock.withLock { activeProcess?.isRunning == true }
    }

    public var currentPort: Int? {
        lock.withLock { activePortValue }
    }

    /// Returns `true` if `@codeceptjs/ui` (CodeceptJS) or `@playwright/test` (Playwright) is declared
    /// in `package.json` or its binary exists in `node_modules/.bin`.
    public static func isInstalled(in workspaceRoot: URL, framework: TestFrameworkKind = .codeceptJS) -> Bool {
        let fm = FileManager.default
        var dir = workspaceRoot.standardizedFileURL

        let binName = framework == .playwright ? "playwright" : "codecept-ui"
        let pkgName = framework == .playwright ? "@playwright/test" : "@codeceptjs/ui"

        for _ in 0...4 {
            let localBin = dir.appendingPathComponent("node_modules/.bin/\(binName)").path
            if fm.isExecutableFile(atPath: localBin) {
                return true
            }
            let localPkg = dir.appendingPathComponent("node_modules/\(pkgName)/package.json").path
            if fm.fileExists(atPath: localPkg) {
                return true
            }
            let pkgURL = dir.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: pkgURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let deps = json["dependencies"] as? [String: Any]
                let devDeps = json["devDependencies"] as? [String: Any]
                if deps?[pkgName] != nil || devDeps?[pkgName] != nil {
                    return true
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return false
    }

    /// Allocates an ephemeral free TCP port strictly on `127.0.0.1`.
    public static func findAvailableLoopbackPort() throws -> Int {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodeceptUIServerError.portAllocationFailed }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw CodeceptUIServerError.portAllocationFailed }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(fd, sockPtr, &len)
            }
        }
        guard nameResult == 0 else { throw CodeceptUIServerError.portAllocationFailed }
        let port = Int(UInt16(bigEndian: boundAddr.sin_port))
        guard port >= 1024 && port <= 65535 else { throw CodeceptUIServerError.portAllocationFailed }
        return port
    }

    /// Strictly validates that a WebView navigation URL targets the loopback `@codeceptjs/ui` server port.
    public static func isAllowedLoopbackURL(_ url: URL, port: Int) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "ws" else {
            return false
        }
        guard let host = url.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" else {
            return false
        }
        return url.port == port
    }

    /// Builds a loopback-bound launch command for `@codeceptjs/ui` or `playwright test --ui-host=127.0.0.1 --ui-port=<port>`.
    public static func buildStartCommand(
        workspaceRoot: URL,
        port: Int,
        customConfigPath: String? = nil,
        toolchain: ResolvedToolchain,
        framework: TestFrameworkKind = .codeceptJS
    ) -> BuiltCommand {
        let fm = FileManager.default
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolchain.searchPath
        env["HOST"] = "127.0.0.1"
        env["PORT"] = String(port)
        env["FORCE_COLOR"] = "0"
        env["NO_COLOR"] = "1"

        if framework == .playwright {
            var tailArgs: [String] = ["test", "--ui-host=127.0.0.1", "--ui-port=\(port)"]
            if let custom = customConfigPath?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
                tailArgs.append(contentsOf: ["-c", custom])
            }
            var searchDir = workspaceRoot.standardizedFileURL
            for _ in 0...4 {
                let localBin = searchDir.appendingPathComponent("node_modules/.bin/playwright").path
                if fm.isExecutableFile(atPath: localBin) {
                    return BuiltCommand(
                        executablePath: localBin,
                        arguments: tailArgs,
                        workingDirectory: workspaceRoot,
                        environment: env,
                        displayCommand: (["playwright"] + tailArgs).joined(separator: " ")
                    )
                }
                let parent = searchDir.deletingLastPathComponent()
                if parent.path == searchDir.path { break }
                searchDir = parent
            }
            if let globalBin = NodeToolchainResolver.findExecutable(named: "playwright", in: toolchain.searchPath) {
                return BuiltCommand(
                    executablePath: globalBin,
                    arguments: tailArgs,
                    workingDirectory: workspaceRoot,
                    environment: env,
                    displayCommand: (["playwright"] + tailArgs).joined(separator: " ")
                )
            }
            let npx = NodeToolchainResolver.findExecutable(named: "npx", in: toolchain.searchPath) ?? "/usr/bin/env"
            let prefix = npx.hasSuffix("/env") ? ["npx", "--no-install", "playwright"] : ["--no-install", "playwright"]
            return BuiltCommand(
                executablePath: npx,
                arguments: prefix + tailArgs,
                workingDirectory: workspaceRoot,
                environment: env,
                displayCommand: (["npx", "--no-install", "playwright"] + tailArgs).joined(separator: " ")
            )
        }

        var tailArgs: [String] = ["--port", String(port)]
        if let custom = customConfigPath?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            tailArgs.append(contentsOf: ["-c", custom])
        }

        // 1. Prefer local workspace or parent monorepo node_modules/.bin/codecept-ui
        var searchDir = workspaceRoot.standardizedFileURL
        for _ in 0...4 {
            let localBin = searchDir.appendingPathComponent("node_modules/.bin/codecept-ui").path
            if fm.isExecutableFile(atPath: localBin) {
                return BuiltCommand(
                    executablePath: localBin,
                    arguments: tailArgs,
                    workingDirectory: workspaceRoot,
                    environment: env,
                    displayCommand: (["codecept-ui"] + tailArgs).joined(separator: " ")
                )
            }
            let parent = searchDir.deletingLastPathComponent()
            if parent.path == searchDir.path { break }
            searchDir = parent
        }

        // 2. Global codecept-ui binary
        if let globalBin = NodeToolchainResolver.findExecutable(named: "codecept-ui", in: toolchain.searchPath) {
            return BuiltCommand(
                executablePath: globalBin,
                arguments: tailArgs,
                workingDirectory: workspaceRoot,
                environment: env,
                displayCommand: (["codecept-ui"] + tailArgs).joined(separator: " ")
            )
        }

        // 3. Fallback to npx --no-install codecept-ui
        let npx = NodeToolchainResolver.findExecutable(named: "npx", in: toolchain.searchPath) ?? "/usr/bin/env"
        let prefix = npx.hasSuffix("/env") ? ["npx", "--no-install", "codecept-ui"] : ["--no-install", "codecept-ui"]
        return BuiltCommand(
            executablePath: npx,
            arguments: prefix + tailArgs,
            workingDirectory: workspaceRoot,
            environment: env,
            displayCommand: (["npx", "--no-install", "codecept-ui"] + tailArgs).joined(separator: " ")
        )
    }

    /// Builds a devDependency install command for `@codeceptjs/ui` or `@playwright/test` matching the project's package manager.
    public static func buildInstallCommand(
        packageManager: PackageManagerKind,
        workspaceRoot: URL,
        toolchain: ResolvedToolchain,
        framework: TestFrameworkKind = .codeceptJS
    ) -> BuiltCommand {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolchain.searchPath
        env["FORCE_COLOR"] = "0"
        env["NO_COLOR"] = "1"

        let pkg = framework.uiPackageName
        let pmExecName = packageManager.executableName
        let args: [String]
        switch packageManager {
        case .npm:
            args = ["install", "-D", pkg]
        case .pnpm, .yarn:
            args = ["add", "-D", pkg]
        case .bun:
            args = ["add", "-d", pkg]
        }

        let resolvedExec = NodeToolchainResolver.findExecutable(named: pmExecName, in: toolchain.searchPath) ?? "/usr/bin/env"
        let finalArgs = resolvedExec == "/usr/bin/env" ? ([pmExecName] + args) : args
        return BuiltCommand(
            executablePath: resolvedExec,
            arguments: finalArgs,
            workingDirectory: workspaceRoot,
            environment: env,
            displayCommand: ([pmExecName] + args).joined(separator: " ")
        )
    }

    /// Starts `@codeceptjs/ui` or `playwright test --ui-host=127.0.0.1` on a fresh `127.0.0.1` loopback port.
    @discardableResult
    public func start(
        workspaceRoot: URL,
        customConfigPath: String? = nil,
        toolchain: ResolvedToolchain,
        framework: TestFrameworkKind = .codeceptJS,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> (port: Int, url: URL) {
        stop()

        let port = try Self.findAvailableLoopbackPort()
        guard let url = URL(string: "http://127.0.0.1:\(port)") else {
            throw CodeceptUIServerError.invalidLoopbackURL
        }

        let command = Self.buildStartCommand(
            workspaceRoot: workspaceRoot,
            port: port,
            customConfigPath: customConfigPath,
            toolchain: toolchain,
            framework: framework
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        process.currentDirectoryURL = command.workingDirectory
        process.environment = command.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let emitChunk: @Sendable (Data) -> Void = { data in
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                onOutput(LiveOutputParser.stripANSI(line))
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            emitChunk(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            emitChunk(handle.availableData)
        }

        process.terminationHandler = { [weak self] proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            self?.lock.withLock {
                if self?.activeProcess === proc {
                    self?.activeProcess = nil
                    self?.activePortValue = nil
                }
            }
            onExit(proc.terminationStatus)
        }

        try process.run()
        lock.withLock {
            activeProcess = process
            activePortValue = port
        }

        return (port: port, url: url)
    }

    /// Polls `127.0.0.1:<port>` until an HTTP response is received or the process stops/times out.
    public func waitForServerReady(url: URL, timeoutSeconds: Double = 15.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.0
        config.timeoutIntervalForResource = 1.5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        while Date() < deadline {
            if !isRunning { return false }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            if let (_, response) = try? await session.data(for: req),
               let http = response as? HTTPURLResponse,
               (200...499).contains(http.statusCode) {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// Cleanly terminates the running `@codeceptjs/ui` process and any child processes.
    public func stop() {
        let proc: Process? = lock.withLock {
            let p = activeProcess
            activeProcess = nil
            activePortValue = nil
            return p
        }
        guard let proc, proc.isRunning else { return }
        let pid = proc.processIdentifier
        kill(-pid, SIGTERM)
        proc.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.2) {
            if proc.isRunning {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
    }
}
