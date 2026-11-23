import Foundation

public enum PackageManagerKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case npm
    case pnpm
    case yarn
    case bun

    public var executableName: String { rawValue }

    public var execRunnerName: String {
        switch self {
        case .npm: return "npx"
        case .pnpm: return "pnpm"
        case .yarn: return "yarn"
        case .bun: return "bunx"
        }
    }
}

public enum DependencyAction: Equatable, Hashable, Sendable {
    case install
    case update
    case cleanInstall
    case outdated
    case upgradeCodeceptJS
    case upgradePlaywright
    case installPlaywrightBrowsers
    case runScript(name: String)
    case customShell(command: String)

    public var displayTitle: String {
        switch self {
        case .install: return "Install Dependencies"
        case .update: return "Update Dependencies"
        case .cleanInstall: return "Clean Install (Lockfile)"
        case .outdated: return "Check Outdated Packages"
        case .upgradeCodeceptJS: return "Update CodeceptJS (@latest)"
        case .upgradePlaywright: return "Update @playwright/test (@latest)"
        case .installPlaywrightBrowsers: return "Install Playwright Browsers"
        case .runScript(let name): return "Script: \(name)"
        case .customShell(let cmd):
            let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > 44 ? String(trimmed.prefix(41)) + "…" : trimmed
        }
    }
}

public struct PackageScriptItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let command: String

    public init(name: String, command: String) {
        self.name = name
        self.command = command
    }
}

public enum PackageManagerSupport {
    /// Detects the project's package manager from `package.json` `"packageManager"` or lockfiles.
    public static func detectPackageManager(in workspaceRoot: URL) -> PackageManagerKind {
        let fm = FileManager.default
        let pkgURL = workspaceRoot.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: pkgURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pmField = (json["packageManager"] as? String)?.lowercased() {
            if pmField.hasPrefix("pnpm") { return .pnpm }
            if pmField.hasPrefix("yarn") { return .yarn }
            if pmField.hasPrefix("bun") { return .bun }
            if pmField.hasPrefix("npm") { return .npm }
        }

        if fm.fileExists(atPath: workspaceRoot.appendingPathComponent("pnpm-lock.yaml").path) {
            return .pnpm
        }
        if fm.fileExists(atPath: workspaceRoot.appendingPathComponent("yarn.lock").path) {
            return .yarn
        }
        if fm.fileExists(atPath: workspaceRoot.appendingPathComponent("bun.lock").path)
            || fm.fileExists(atPath: workspaceRoot.appendingPathComponent("bun.lockb").path) {
            return .bun
        }
        return .npm
    }

    /// Reads `"scripts"` entries from `package.json`.
    public static func readPackageScripts(in workspaceRoot: URL) -> [PackageScriptItem] {
        let pkgURL = workspaceRoot.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: pkgURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: String] else {
            return []
        }
        return scripts
            .map { PackageScriptItem(name: $0.key, command: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Builds a `BuiltCommand` for a dependency/package-manager preset or custom workspace shell command.
    public static func buildCommand(
        action: DependencyAction,
        packageManager: PackageManagerKind,
        workspaceRoot: URL,
        toolchain: ResolvedToolchain,
        extraEnv: [String: String] = [:],
        colorOutput: Bool = false
    ) -> BuiltCommand {
        var env = ProcessInfo.processInfo.environment
        var envOverrides: [String: String] = [:]
        env["PATH"] = toolchain.searchPath
        if !colorOutput {
            env["FORCE_COLOR"] = "0"
            env["NO_COLOR"] = "1"
        } else {
            env.removeValue(forKey: "NO_COLOR")
            if env["FORCE_COLOR"] == "0" {
                env.removeValue(forKey: "FORCE_COLOR")
            }
        }
        for (k, v) in extraEnv where !k.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmedKey = k.trimmingCharacters(in: .whitespaces)
            env[trimmedKey] = v
            envOverrides[trimmedKey] = v
        }

        if case .customShell(let rawCommand) = action {
            let trimmed = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return BuiltCommand(
                executablePath: "/bin/zsh",
                arguments: ["-c", trimmed],
                workingDirectory: workspaceRoot,
                environment: env,
                environmentOverrides: envOverrides,
                displayCommand: trimmed
            )
        }

        let pmExecName: String
        let args: [String]

        switch action {
        case .install:
            pmExecName = packageManager.executableName
            args = ["install"]

        case .update:
            pmExecName = packageManager.executableName
            switch packageManager {
            case .npm, .pnpm, .bun: args = ["update"]
            case .yarn: args = ["upgrade"]
            }

        case .cleanInstall:
            pmExecName = packageManager.executableName
            switch packageManager {
            case .npm: args = ["ci"]
            case .pnpm, .yarn, .bun: args = ["install", "--frozen-lockfile"]
            }

        case .outdated:
            pmExecName = packageManager.executableName
            args = ["outdated"]

        case .upgradeCodeceptJS:
            pmExecName = packageManager.executableName
            switch packageManager {
            case .npm: args = ["install", "-D", "codeceptjs@latest"]
            case .pnpm, .yarn: args = ["add", "-D", "codeceptjs@latest"]
            case .bun: args = ["add", "-d", "codeceptjs@latest"]
            }

        case .upgradePlaywright:
            pmExecName = packageManager.executableName
            switch packageManager {
            case .npm: args = ["install", "-D", "@playwright/test@latest"]
            case .pnpm, .yarn: args = ["add", "-D", "@playwright/test@latest"]
            case .bun: args = ["add", "-d", "@playwright/test@latest"]
            }

        case .installPlaywrightBrowsers:
            pmExecName = packageManager.execRunnerName
            switch packageManager {
            case .npm, .bun: args = ["playwright", "install"]
            case .pnpm: args = ["exec", "playwright", "install"]
            case .yarn: args = ["playwright", "install"]
            }

        case .runScript(let name):
            pmExecName = packageManager.executableName
            args = ["run", name]

        case .customShell:
            pmExecName = "/bin/zsh"
            args = []
        }

        let resolvedExec = NodeToolchainResolver.findExecutable(named: pmExecName, in: toolchain.searchPath)
            ?? "/usr/bin/env"
        let finalArgs = resolvedExec == "/usr/bin/env" ? ([pmExecName] + args) : args
        let displayParts = [pmExecName] + args.map {
            $0.contains(" ") ? CommandBuilder.shellSingleQuote($0) : $0
        }

        return BuiltCommand(
            executablePath: resolvedExec,
            arguments: finalArgs,
            workingDirectory: workspaceRoot,
            environment: env,
            environmentOverrides: envOverrides,
            displayCommand: displayParts.joined(separator: " ")
        )
    }

    public static func commandPreview(for action: DependencyAction, packageManager: PackageManagerKind) -> String {
        switch action {
        case .install: return "\(packageManager.rawValue) install"
        case .update: return packageManager == .yarn ? "yarn upgrade" : "\(packageManager.rawValue) update"
        case .cleanInstall: return packageManager == .npm ? "npm ci" : "\(packageManager.rawValue) install --frozen-lockfile"
        case .outdated: return "\(packageManager.rawValue) outdated"
        case .upgradeCodeceptJS:
            switch packageManager {
            case .npm: return "npm install -D codeceptjs@latest"
            case .pnpm, .yarn: return "\(packageManager.rawValue) add -D codeceptjs@latest"
            case .bun: return "bun add -d codeceptjs@latest"
            }
        case .upgradePlaywright:
            switch packageManager {
            case .npm: return "npm install -D @playwright/test@latest"
            case .pnpm, .yarn: return "\(packageManager.rawValue) add -D @playwright/test@latest"
            case .bun: return "bun add -d @playwright/test@latest"
            }
        case .installPlaywrightBrowsers:
            switch packageManager {
            case .npm: return "npx playwright install"
            case .pnpm: return "pnpm exec playwright install"
            case .yarn: return "yarn playwright install"
            case .bun: return "bunx playwright install"
            }
        case .runScript(let name): return "\(packageManager.rawValue) run \(name)"
        case .customShell(let cmd): return cmd
        }
    }
}
