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
    case runMobilewrightDoctor
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
        case .runMobilewrightDoctor: return "Run Mobilewright Doctor"
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

public enum DetectedRuntimeEnvironment: Equatable, Hashable, Sendable {
    case pythonUV
    case pythonPoetry
    case pythonVenv(directoryName: String)
    case pythonSystem
    case nodePackageManager(PackageManagerKind)

    public var isPython: Bool {
        switch self {
        case .pythonUV, .pythonPoetry, .pythonVenv, .pythonSystem:
            return true
        case .nodePackageManager:
            return false
        }
    }

    public var badgeTitle: String {
        switch self {
        case .pythonUV: return "uv"
        case .pythonPoetry: return "poetry"
        case .pythonVenv(let dir): return dir
        case .pythonSystem: return "pip"
        case .nodePackageManager(let pm): return pm.rawValue
        }
    }

    public var displayName: String {
        switch self {
        case .pythonUV: return "Python · uv"
        case .pythonPoetry: return "Python · Poetry"
        case .pythonVenv(let dir): return "Python · \(dir)"
        case .pythonSystem: return "Python · pip"
        case .nodePackageManager(let pm): return pm.rawValue
        }
    }

    public var iconName: String {
        switch self {
        case .pythonUV, .pythonPoetry, .pythonVenv, .pythonSystem:
            return "terminal.fill"
        case .nodePackageManager(.bun):
            return "bolt.fill"
        case .nodePackageManager:
            return "shippingbox"
        }
    }
}

public enum TerminalCommandSection: String, Equatable, Hashable, Sendable {
    case dependencies
    case frameworkAndBrowsers
    case quickCommands
}

public struct TerminalCommandSuggestion: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let section: TerminalCommandSection
    public let title: String
    public let commandPreview: String
    public let iconName: String
    public let action: DependencyAction

    public init(
        id: String,
        section: TerminalCommandSection,
        title: String,
        commandPreview: String,
        iconName: String,
        action: DependencyAction
    ) {
        self.id = id
        self.section = section
        self.title = title
        self.commandPreview = commandPreview
        self.iconName = iconName
        self.action = action
    }
}

public struct TerminalEnvironmentSuggestions: Equatable, Sendable {
    public let environment: DetectedRuntimeEnvironment
    public let framework: TestFrameworkKind
    public let badgeTitle: String
    public let dependenciesHeader: String
    public let frameworkHeader: String
    public let quickCommandsHeader: String
    public let dependencyItems: [TerminalCommandSuggestion]
    public let frameworkItems: [TerminalCommandSuggestion]
    public let quickCommandItems: [TerminalCommandSuggestion]
    public let emptyLogHint: String
    public let placeholderExamples: [String]

    public var allSuggestions: [TerminalCommandSuggestion] {
        dependencyItems + frameworkItems + quickCommandItems
    }

    public func inputPlaceholder(systemTerminalName: String?) -> String {
        let joined = placeholderExamples.joined(separator: ", ")
        if let termName = systemTerminalName, !termName.isEmpty {
            return "Run command in \(termName) (e.g. \(joined))…"
        }
        return "Run workspace command (e.g. \(joined))…"
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
            env.removeValue(forKey: "NO_COLOR")
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

        if toolchain.framework == .playwrightPython {
            return buildPythonCommand(
                action: action,
                workspaceRoot: workspaceRoot,
                toolchain: toolchain,
                env: env,
                envOverrides: envOverrides
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

        case .runMobilewrightDoctor:
            pmExecName = packageManager.execRunnerName
            switch packageManager {
            case .npm, .bun: args = ["mobilewright", "doctor"]
            case .pnpm: args = ["exec", "mobilewright", "doctor"]
            case .yarn: args = ["mobilewright", "doctor"]
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

    private static func buildPythonCommand(
        action: DependencyAction,
        workspaceRoot: URL,
        toolchain: ResolvedToolchain,
        env: [String: String],
        envOverrides: [String: String]
    ) -> BuiltCommand {
        let fm = FileManager.default
        let detectedEnv = detectRuntimeEnvironment(
            workspaceRoot: workspaceRoot,
            framework: .playwrightPython,
            packageManager: .npm,
            jsRuntime: .node,
            toolchain: toolchain
        )
        let hasRequirements = fm.fileExists(atPath: workspaceRoot.appendingPathComponent("requirements.txt").path)
        let uvBin = NodeToolchainResolver.findExecutable(named: "uv", in: toolchain.searchPath)
        let poetryBin = NodeToolchainResolver.findExecutable(named: "poetry", in: toolchain.searchPath)
        let pythonExec = toolchain.pythonPath
            ?? NodeToolchainResolver.findExecutable(named: "python3", in: toolchain.searchPath)
            ?? "/usr/bin/env"
        let pyPrefix = pythonExec == "/usr/bin/env" ? ["python3"] : []
        let pyDisplay: String = {
            if case .pythonVenv(let dir) = detectedEnv {
                return "\(dir)/bin/python"
            }
            return pythonExec == "/usr/bin/env" ? "python3" : URL(fileURLWithPath: pythonExec).lastPathComponent
        }()

        func makeZsh(_ cmd: String, display: String? = nil) -> BuiltCommand {
            BuiltCommand(
                executablePath: "/bin/zsh",
                arguments: ["-c", cmd],
                workingDirectory: workspaceRoot,
                environment: env,
                environmentOverrides: envOverrides,
                displayCommand: display ?? cmd
            )
        }

        // 1. uv project (`uv.lock`)
        if detectedEnv == .pythonUV, let uvBin {
            switch action {
            case .install:
                return BuiltCommand(executablePath: uvBin, arguments: ["sync"], workingDirectory: workspaceRoot, environment: env, environmentOverrides: envOverrides, displayCommand: "uv sync")
            case .cleanInstall:
                return BuiltCommand(executablePath: uvBin, arguments: ["sync", "--frozen"], workingDirectory: workspaceRoot, environment: env, environmentOverrides: envOverrides, displayCommand: "uv sync --frozen")
            case .update:
                let uvQ = CommandBuilder.shellSingleQuote(uvBin)
                return makeZsh("\(uvQ) lock --upgrade && \(uvQ) sync", display: "uv lock --upgrade && uv sync")
            case .outdated:
                return BuiltCommand(executablePath: uvBin, arguments: ["pip", "list", "--outdated"], workingDirectory: workspaceRoot, environment: env, environmentOverrides: envOverrides, displayCommand: "uv pip list --outdated")
            case .upgradePlaywright:
                return BuiltCommand(executablePath: uvBin, arguments: ["sync", "--upgrade-package", "pytest-playwright", "--upgrade-package", "playwright"], workingDirectory: workspaceRoot, environment: env, environmentOverrides: envOverrides, displayCommand: "uv sync --upgrade-package pytest-playwright --upgrade-package playwright")
            case .installPlaywrightBrowsers:
                return BuiltCommand(executablePath: uvBin, arguments: ["run", "playwright", "install"], workingDirectory: workspaceRoot, environment: env, environmentOverrides: envOverrides, displayCommand: "uv run playwright install")
            case .upgradeCodeceptJS, .runMobilewrightDoctor, .runScript, .customShell:
                return BuiltCommand(executablePath: uvBin, arguments: ["sync"], workingDirectory: workspaceRoot, environment: env, environmentOverrides: envOverrides, displayCommand: "uv sync")
            }
        }

        // 2. Poetry project (`poetry.lock`)
        if detectedEnv == .pythonPoetry, let poetryBin {
            switch action {
            case .install:
                return BuiltCommand(executablePath: poetryBin, arguments: ["install"], workingDirectory: workspaceRoot, environment: env, environmentOverrides: envOverrides, displayCommand: "poetry install")
            case .cleanInstall:
                return BuiltCommand(executablePath: poetryBin, arguments: ["install", "--sync"], workingDirectory: workspaceRoot, environment: env, environmentOverrides: envOverrides, displayCommand: "poetry install --sync")
            case .update:
                return BuiltCommand(executablePath: poetryBin, arguments: ["update"], workingDirectory: workspaceRoot, environment: env, environmentOverrides: envOverrides, displayCommand: "poetry update")
            case .outdated:
                return BuiltCommand(executablePath: poetryBin, arguments: ["show", "--outdated"], workingDirectory: workspaceRoot, environment: env, environmentOverrides: envOverrides, displayCommand: "poetry show --outdated")
            case .upgradePlaywright:
                return BuiltCommand(executablePath: poetryBin, arguments: ["update", "pytest-playwright", "playwright"], workingDirectory: workspaceRoot, environment: env, environmentOverrides: envOverrides, displayCommand: "poetry update pytest-playwright playwright")
            case .installPlaywrightBrowsers:
                return BuiltCommand(executablePath: poetryBin, arguments: ["run", "playwright", "install"], workingDirectory: workspaceRoot, environment: env, environmentOverrides: envOverrides, displayCommand: "poetry run playwright install")
            case .upgradeCodeceptJS, .runMobilewrightDoctor, .runScript, .customShell:
                return BuiltCommand(executablePath: poetryBin, arguments: ["install"], workingDirectory: workspaceRoot, environment: env, environmentOverrides: envOverrides, displayCommand: "poetry install")
            }
        }

        // 3. Local virtualenv (`.venv` / `venv`) or system `python3` (bootstrapping `.venv`)
        let hasLocalVenv: Bool = {
            if case .pythonVenv = detectedEnv { return true }
            return false
        }()

        switch action {
        case .installPlaywrightBrowsers:
            let cli = NodeToolchainResolver.resolvePlaywrightPythonCLI(toolchain: toolchain)
            let displayPrefix: [String]
            if case .pythonVenv(let dir) = detectedEnv {
                displayPrefix = cli.prefixArguments.isEmpty ? ["\(dir)/bin/playwright"] : (["\(dir)/bin/python"] + cli.prefixArguments)
            } else {
                let execName = URL(fileURLWithPath: cli.executable).lastPathComponent
                displayPrefix = cli.prefixArguments.isEmpty ? [execName] : ([execName] + cli.prefixArguments)
            }
            return BuiltCommand(
                executablePath: cli.executable,
                arguments: cli.prefixArguments + ["install"],
                workingDirectory: workspaceRoot,
                environment: env,
                environmentOverrides: envOverrides,
                displayCommand: (displayPrefix + ["install"]).joined(separator: " ")
            )

        case .upgradePlaywright:
            if !hasLocalVenv {
                let bootstrapPy = pythonExec == "/usr/bin/env" ? "python3" : CommandBuilder.shellSingleQuote(pythonExec)
                return makeZsh(
                    "\(bootstrapPy) -m venv .venv && .venv/bin/python -m pip install --upgrade pytest-playwright playwright",
                    display: "python3 -m venv .venv && .venv/bin/python -m pip install --upgrade pytest-playwright playwright"
                )
            }
            let args = pyPrefix + ["-m", "pip", "install", "--upgrade", "pytest-playwright", "playwright"]
            return BuiltCommand(
                executablePath: pythonExec,
                arguments: args,
                workingDirectory: workspaceRoot,
                environment: env,
                environmentOverrides: envOverrides,
                displayCommand: "\(pyDisplay) -m pip install --upgrade pytest-playwright playwright"
            )

        case .install, .cleanInstall:
            let installArgs = hasRequirements ? ["-m", "pip", "install", "-r", "requirements.txt"] : ["-m", "pip", "install", "-e", "."]
            let installTail = hasRequirements
                ? ".venv/bin/python -m pip install -r requirements.txt"
                : ".venv/bin/python -m pip install -e ."
            if !hasLocalVenv {
                let bootstrapPy = pythonExec == "/usr/bin/env" ? "python3" : CommandBuilder.shellSingleQuote(pythonExec)
                let shellCmd = action == .cleanInstall
                    ? "rm -rf .venv && \(bootstrapPy) -m venv .venv && \(installTail)"
                    : "\(bootstrapPy) -m venv .venv && \(installTail)"
                let display = action == .cleanInstall
                    ? "rm -rf .venv && python3 -m venv .venv && \(installTail)"
                    : "python3 -m venv .venv && \(installTail)"
                return makeZsh(shellCmd, display: display)
            }
            let finalInstallArgs = action == .cleanInstall
                ? (hasRequirements ? ["-m", "pip", "install", "--force-reinstall", "-r", "requirements.txt"] : ["-m", "pip", "install", "--force-reinstall", "-e", "."])
                : installArgs
            let displayTail = finalInstallArgs.joined(separator: " ")
            return BuiltCommand(
                executablePath: pythonExec,
                arguments: pyPrefix + finalInstallArgs,
                workingDirectory: workspaceRoot,
                environment: env,
                environmentOverrides: envOverrides,
                displayCommand: "\(pyDisplay) \(displayTail)"
            )

        case .outdated:
            let args = pyPrefix + ["-m", "pip", "list", "--outdated"]
            return BuiltCommand(
                executablePath: pythonExec,
                arguments: args,
                workingDirectory: workspaceRoot,
                environment: env,
                environmentOverrides: envOverrides,
                displayCommand: "\(pyDisplay) -m pip list --outdated"
            )

        case .update, .upgradeCodeceptJS, .runMobilewrightDoctor, .runScript, .customShell:
            if !hasLocalVenv {
                let bootstrapPy = pythonExec == "/usr/bin/env" ? "python3" : CommandBuilder.shellSingleQuote(pythonExec)
                return makeZsh(
                    "\(bootstrapPy) -m venv .venv && .venv/bin/python -m pip install --upgrade pytest pytest-playwright playwright",
                    display: "python3 -m venv .venv && .venv/bin/python -m pip install --upgrade pytest pytest-playwright playwright"
                )
            }
            let upgradeArgs = hasRequirements
                ? ["-m", "pip", "install", "--upgrade", "-r", "requirements.txt"]
                : ["-m", "pip", "install", "--upgrade", "pytest", "pytest-playwright", "playwright"]
            return BuiltCommand(
                executablePath: pythonExec,
                arguments: pyPrefix + upgradeArgs,
                workingDirectory: workspaceRoot,
                environment: env,
                environmentOverrides: envOverrides,
                displayCommand: "\(pyDisplay) \(upgradeArgs.joined(separator: " "))"
            )
        }
    }

    // MARK: - Runtime Environment Detection & Adaptive Terminal Pre-Suggested Commands

    public static func detectRuntimeEnvironment(
        workspaceRoot: URL,
        framework: TestFrameworkKind,
        packageManager: PackageManagerKind,
        jsRuntime: JSRuntimeKind,
        toolchain: ResolvedToolchain? = nil
    ) -> DetectedRuntimeEnvironment {
        if framework == .playwrightPython {
            let fm = FileManager.default
            if fm.fileExists(atPath: workspaceRoot.appendingPathComponent("uv.lock").path) {
                return .pythonUV
            }
            if fm.fileExists(atPath: workspaceRoot.appendingPathComponent("poetry.lock").path) {
                return .pythonPoetry
            }
            for dirName in [".venv", "venv"] {
                let py1 = workspaceRoot.appendingPathComponent("\(dirName)/bin/python").path
                let py2 = workspaceRoot.appendingPathComponent("\(dirName)/bin/python3").path
                if fm.isExecutableFile(atPath: py1) || fm.isExecutableFile(atPath: py2) {
                    return .pythonVenv(directoryName: dirName)
                }
            }
            if let source = toolchain?.resolutionSource.lowercased() {
                if source.contains("uv") { return .pythonUV }
                if source.contains("poetry") { return .pythonPoetry }
            }
            return .pythonSystem
        }

        if jsRuntime == .bun || packageManager == .bun {
            return .nodePackageManager(.bun)
        }
        return .nodePackageManager(packageManager)
    }

    /// Generates the complete collection of pre-suggested terminal commands, previews, labels,
    /// and input placeholders adapted to the detected runtime environment and test framework.
    public static func terminalSuggestions(
        workspaceRoot: URL,
        framework: TestFrameworkKind,
        packageManager: PackageManagerKind,
        jsRuntime: JSRuntimeKind,
        toolchain: ResolvedToolchain? = nil
    ) -> TerminalEnvironmentSuggestions {
        let envKind = detectRuntimeEnvironment(
            workspaceRoot: workspaceRoot,
            framework: framework,
            packageManager: packageManager,
            jsRuntime: jsRuntime,
            toolchain: toolchain
        )
        let fm = FileManager.default

        switch envKind {
        case .pythonUV:
            let depItems: [TerminalCommandSuggestion] = [
                TerminalCommandSuggestion(id: "py-uv-install", section: .dependencies, title: "Sync Dependencies", commandPreview: "uv sync", iconName: "arrow.down.circle", action: .install),
                TerminalCommandSuggestion(id: "py-uv-update", section: .dependencies, title: "Upgrade Lockfile & Sync", commandPreview: "uv lock --upgrade && uv sync", iconName: "arrow.triangle.2.circlepath", action: .update),
                TerminalCommandSuggestion(id: "py-uv-frozen", section: .dependencies, title: "Clean Frozen Sync", commandPreview: "uv sync --frozen", iconName: "sparkles", action: .cleanInstall),
                TerminalCommandSuggestion(id: "py-uv-outdated", section: .dependencies, title: "Check Outdated Packages", commandPreview: "uv pip list --outdated", iconName: "clock.badge.exclamationmark", action: .outdated)
            ]
            let fwItems: [TerminalCommandSuggestion] = [
                TerminalCommandSuggestion(id: "py-uv-pw-upgrade", section: .frameworkAndBrowsers, title: "Update pytest-playwright", commandPreview: "uv sync --upgrade-package pytest-playwright --upgrade-package playwright", iconName: "theatermasks", action: .upgradePlaywright),
                TerminalCommandSuggestion(id: "py-uv-browsers", section: .frameworkAndBrowsers, title: "Install Playwright Browsers", commandPreview: "uv run playwright install", iconName: "globe", action: .installPlaywrightBrowsers)
            ]
            let quickItems: [TerminalCommandSuggestion] = [
                TerminalCommandSuggestion(id: "py-uv-collect", section: .quickCommands, title: "Collect Pytest Tests", commandPreview: "uv run pytest --co -q", iconName: "checklist", action: .customShell(command: "uv run pytest --co -q")),
                TerminalCommandSuggestion(id: "py-uv-smoke", section: .quickCommands, title: "Run @smoke Marker", commandPreview: "uv run pytest -v -m smoke", iconName: "flame", action: .customShell(command: "uv run pytest -v -m smoke")),
                TerminalCommandSuggestion(id: "py-uv-codegen", section: .quickCommands, title: "Record with Codegen (Python)", commandPreview: "uv run playwright codegen --target python-pytest", iconName: "record.circle", action: .customShell(command: "uv run playwright codegen --target python-pytest"))
            ]
            return TerminalEnvironmentSuggestions(
                environment: envKind,
                framework: framework,
                badgeTitle: envKind.badgeTitle,
                dependenciesHeader: "Dependencies (uv)",
                frameworkHeader: "Playwright Python & Browsers",
                quickCommandsHeader: "Quick Pytest Commands (uv)",
                dependencyItems: depItems,
                frameworkItems: fwItems,
                quickCommandItems: quickItems,
                emptyLogHint: "Ready. Press ⌘R to run pytest, use the uv menu to sync Python packages or browsers, or run any shell command below.",
                placeholderExamples: ["uv sync", "uv run playwright install", "uv run pytest -v"]
            )

        case .pythonPoetry:
            let depItems: [TerminalCommandSuggestion] = [
                TerminalCommandSuggestion(id: "py-poetry-install", section: .dependencies, title: "Install Dependencies", commandPreview: "poetry install", iconName: "arrow.down.circle", action: .install),
                TerminalCommandSuggestion(id: "py-poetry-update", section: .dependencies, title: "Update Dependencies", commandPreview: "poetry update", iconName: "arrow.triangle.2.circlepath", action: .update),
                TerminalCommandSuggestion(id: "py-poetry-sync", section: .dependencies, title: "Clean Sync Lockfile", commandPreview: "poetry install --sync", iconName: "sparkles", action: .cleanInstall),
                TerminalCommandSuggestion(id: "py-poetry-outdated", section: .dependencies, title: "Check Outdated Packages", commandPreview: "poetry show --outdated", iconName: "clock.badge.exclamationmark", action: .outdated)
            ]
            let fwItems: [TerminalCommandSuggestion] = [
                TerminalCommandSuggestion(id: "py-poetry-pw-upgrade", section: .frameworkAndBrowsers, title: "Update pytest-playwright", commandPreview: "poetry update pytest-playwright playwright", iconName: "theatermasks", action: .upgradePlaywright),
                TerminalCommandSuggestion(id: "py-poetry-browsers", section: .frameworkAndBrowsers, title: "Install Playwright Browsers", commandPreview: "poetry run playwright install", iconName: "globe", action: .installPlaywrightBrowsers)
            ]
            let quickItems: [TerminalCommandSuggestion] = [
                TerminalCommandSuggestion(id: "py-poetry-collect", section: .quickCommands, title: "Collect Pytest Tests", commandPreview: "poetry run pytest --co -q", iconName: "checklist", action: .customShell(command: "poetry run pytest --co -q")),
                TerminalCommandSuggestion(id: "py-poetry-smoke", section: .quickCommands, title: "Run @smoke Marker", commandPreview: "poetry run pytest -v -m smoke", iconName: "flame", action: .customShell(command: "poetry run pytest -v -m smoke")),
                TerminalCommandSuggestion(id: "py-poetry-codegen", section: .quickCommands, title: "Record with Codegen (Python)", commandPreview: "poetry run playwright codegen --target python-pytest", iconName: "record.circle", action: .customShell(command: "poetry run playwright codegen --target python-pytest"))
            ]
            return TerminalEnvironmentSuggestions(
                environment: envKind,
                framework: framework,
                badgeTitle: envKind.badgeTitle,
                dependenciesHeader: "Dependencies (Poetry)",
                frameworkHeader: "Playwright Python & Browsers",
                quickCommandsHeader: "Quick Pytest Commands (Poetry)",
                dependencyItems: depItems,
                frameworkItems: fwItems,
                quickCommandItems: quickItems,
                emptyLogHint: "Ready. Press ⌘R to run pytest, use the poetry menu to manage Python dependencies or browsers, or run any shell command below.",
                placeholderExamples: ["poetry install", "poetry run playwright install", "poetry run pytest -v"]
            )

        case .pythonVenv(let dir):
            let hasRequirements = fm.fileExists(atPath: workspaceRoot.appendingPathComponent("requirements.txt").path)
            let py = "\(dir)/bin/python"
            let pw = fm.isExecutableFile(atPath: workspaceRoot.appendingPathComponent("\(dir)/bin/playwright").path)
                ? "\(dir)/bin/playwright"
                : "\(py) -m playwright"
            let pytestCmd = fm.isExecutableFile(atPath: workspaceRoot.appendingPathComponent("\(dir)/bin/pytest").path)
                ? "\(dir)/bin/pytest"
                : "\(py) -m pytest"
            let installPreview = hasRequirements ? "\(py) -m pip install -r requirements.txt" : "\(py) -m pip install -e ."
            let updatePreview = hasRequirements ? "\(py) -m pip install --upgrade -r requirements.txt" : "\(py) -m pip install --upgrade pytest pytest-playwright playwright"
            let cleanPreview = hasRequirements ? "\(py) -m pip install --force-reinstall -r requirements.txt" : "\(py) -m pip install --force-reinstall -e ."

            let depItems: [TerminalCommandSuggestion] = [
                TerminalCommandSuggestion(id: "py-venv-install", section: .dependencies, title: "Install Dependencies", commandPreview: installPreview, iconName: "arrow.down.circle", action: .install),
                TerminalCommandSuggestion(id: "py-venv-update", section: .dependencies, title: "Upgrade Dependencies", commandPreview: updatePreview, iconName: "arrow.triangle.2.circlepath", action: .update),
                TerminalCommandSuggestion(id: "py-venv-clean", section: .dependencies, title: "Force Reinstall Packages", commandPreview: cleanPreview, iconName: "sparkles", action: .cleanInstall),
                TerminalCommandSuggestion(id: "py-venv-outdated", section: .dependencies, title: "Check Outdated Packages", commandPreview: "\(py) -m pip list --outdated", iconName: "clock.badge.exclamationmark", action: .outdated)
            ]
            let fwItems: [TerminalCommandSuggestion] = [
                TerminalCommandSuggestion(id: "py-venv-pw-upgrade", section: .frameworkAndBrowsers, title: "Update pytest-playwright", commandPreview: "\(py) -m pip install --upgrade pytest-playwright playwright", iconName: "theatermasks", action: .upgradePlaywright),
                TerminalCommandSuggestion(id: "py-venv-browsers", section: .frameworkAndBrowsers, title: "Install Playwright Browsers", commandPreview: "\(pw) install", iconName: "globe", action: .installPlaywrightBrowsers)
            ]
            let quickItems: [TerminalCommandSuggestion] = [
                TerminalCommandSuggestion(id: "py-venv-collect", section: .quickCommands, title: "Collect Pytest Tests", commandPreview: "\(pytestCmd) --co -q", iconName: "checklist", action: .customShell(command: "\(pytestCmd) --co -q")),
                TerminalCommandSuggestion(id: "py-venv-smoke", section: .quickCommands, title: "Run @smoke Marker", commandPreview: "\(pytestCmd) -v -m smoke", iconName: "flame", action: .customShell(command: "\(pytestCmd) -v -m smoke")),
                TerminalCommandSuggestion(id: "py-venv-codegen", section: .quickCommands, title: "Record with Codegen (Python)", commandPreview: "\(pw) codegen --target python-pytest", iconName: "record.circle", action: .customShell(command: "\(pw) codegen --target python-pytest"))
            ]
            return TerminalEnvironmentSuggestions(
                environment: envKind,
                framework: framework,
                badgeTitle: envKind.badgeTitle,
                dependenciesHeader: "Dependencies (\(dir) · pip)",
                frameworkHeader: "Playwright Python & Browsers",
                quickCommandsHeader: "Quick Pytest Commands (\(dir))",
                dependencyItems: depItems,
                frameworkItems: fwItems,
                quickCommandItems: quickItems,
                emptyLogHint: "Ready. Press ⌘R to run pytest, use the \(dir) menu to install packages or Playwright browsers, or run any shell command below.",
                placeholderExamples: [installPreview, "\(pw) install", "\(pytestCmd) -v"]
            )

        case .pythonSystem:
            let hasRequirements = fm.fileExists(atPath: workspaceRoot.appendingPathComponent("requirements.txt").path)
            let reqTail = hasRequirements ? "-r requirements.txt" : "-e ."
            let depItems: [TerminalCommandSuggestion] = [
                TerminalCommandSuggestion(id: "py-sys-install", section: .dependencies, title: "Create .venv & Install", commandPreview: "python3 -m venv .venv && .venv/bin/python -m pip install \(reqTail)", iconName: "arrow.down.circle", action: .install),
                TerminalCommandSuggestion(id: "py-sys-update", section: .dependencies, title: "Upgrade Playwright Packages", commandPreview: "python3 -m venv .venv && .venv/bin/python -m pip install --upgrade pytest pytest-playwright playwright", iconName: "arrow.triangle.2.circlepath", action: .update),
                TerminalCommandSuggestion(id: "py-sys-clean", section: .dependencies, title: "Recreate .venv & Install", commandPreview: "rm -rf .venv && python3 -m venv .venv && .venv/bin/python -m pip install \(reqTail)", iconName: "sparkles", action: .cleanInstall),
                TerminalCommandSuggestion(id: "py-sys-outdated", section: .dependencies, title: "Check Outdated Packages", commandPreview: "python3 -m pip list --outdated", iconName: "clock.badge.exclamationmark", action: .outdated)
            ]
            let fwItems: [TerminalCommandSuggestion] = [
                TerminalCommandSuggestion(id: "py-sys-pw-upgrade", section: .frameworkAndBrowsers, title: "Install / Update pytest-playwright", commandPreview: "python3 -m venv .venv && .venv/bin/python -m pip install --upgrade pytest-playwright playwright", iconName: "theatermasks", action: .upgradePlaywright),
                TerminalCommandSuggestion(id: "py-sys-browsers", section: .frameworkAndBrowsers, title: "Install Playwright Browsers", commandPreview: "python3 -m playwright install", iconName: "globe", action: .installPlaywrightBrowsers)
            ]
            let quickItems: [TerminalCommandSuggestion] = [
                TerminalCommandSuggestion(id: "py-sys-collect", section: .quickCommands, title: "Collect Pytest Tests", commandPreview: "python3 -m pytest --co -q", iconName: "checklist", action: .customShell(command: "python3 -m pytest --co -q")),
                TerminalCommandSuggestion(id: "py-sys-codegen", section: .quickCommands, title: "Record with Codegen (Python)", commandPreview: "python3 -m playwright codegen --target python-pytest", iconName: "record.circle", action: .customShell(command: "python3 -m playwright codegen --target python-pytest")),
                TerminalCommandSuggestion(id: "py-sys-version", section: .quickCommands, title: "Check Python & Pytest Version", commandPreview: "python3 --version && python3 -m pytest --version", iconName: "stethoscope", action: .customShell(command: "python3 --version && python3 -m pytest --version"))
            ]
            return TerminalEnvironmentSuggestions(
                environment: envKind,
                framework: framework,
                badgeTitle: envKind.badgeTitle,
                dependenciesHeader: "Dependencies (Python · .venv)",
                frameworkHeader: "Playwright Python & Browsers",
                quickCommandsHeader: "Quick Python Commands",
                dependencyItems: depItems,
                frameworkItems: fwItems,
                quickCommandItems: quickItems,
                emptyLogHint: "Ready. Use the pip menu to create .venv & install pytest-playwright, press ⌘R to run tests, or run any shell command below.",
                placeholderExamples: ["python3 -m venv .venv", ".venv/bin/pip install \(reqTail)", ".venv/bin/playwright install"]
            )

        case .nodePackageManager(let pm):
            let execPrefix: String = {
                switch pm {
                case .npm: return "npx"
                case .pnpm: return "pnpm exec"
                case .yarn: return "yarn"
                case .bun: return "bunx"
                }
            }()

            let depItems: [TerminalCommandSuggestion] = [
                TerminalCommandSuggestion(id: "js-install", section: .dependencies, title: "Install Dependencies", commandPreview: commandPreview(for: .install, packageManager: pm), iconName: "arrow.down.circle", action: .install),
                TerminalCommandSuggestion(id: "js-update", section: .dependencies, title: "Update Dependencies", commandPreview: commandPreview(for: .update, packageManager: pm), iconName: "arrow.triangle.2.circlepath", action: .update),
                TerminalCommandSuggestion(id: "js-clean", section: .dependencies, title: "Clean Install", commandPreview: commandPreview(for: .cleanInstall, packageManager: pm), iconName: "sparkles", action: .cleanInstall),
                TerminalCommandSuggestion(id: "js-outdated", section: .dependencies, title: "Check Outdated", commandPreview: commandPreview(for: .outdated, packageManager: pm), iconName: "clock.badge.exclamationmark", action: .outdated)
            ]

            let fwItems: [TerminalCommandSuggestion]
            let quickItems: [TerminalCommandSuggestion]
            let fwHeader: String
            let quickHeader: String
            let placeholders: [String]

            if framework == .playwright {
                fwHeader = "Playwright Test & Browsers"
                quickHeader = "Quick Playwright Commands (\(pm.rawValue))"
                fwItems = [
                    TerminalCommandSuggestion(id: "js-pw-upgrade", section: .frameworkAndBrowsers, title: "Update @playwright/test", commandPreview: commandPreview(for: .upgradePlaywright, packageManager: pm), iconName: "theatermasks", action: .upgradePlaywright),
                    TerminalCommandSuggestion(id: "js-pw-browsers", section: .frameworkAndBrowsers, title: "Install Playwright Browsers", commandPreview: commandPreview(for: .installPlaywrightBrowsers, packageManager: pm), iconName: "globe", action: .installPlaywrightBrowsers)
                ]
                quickItems = [
                    TerminalCommandSuggestion(id: "js-pw-list", section: .quickCommands, title: "List Playwright Tests", commandPreview: "\(execPrefix) playwright test --list", iconName: "checklist", action: .customShell(command: "\(execPrefix) playwright test --list")),
                    TerminalCommandSuggestion(id: "js-pw-codegen", section: .quickCommands, title: "Record with Codegen", commandPreview: "\(execPrefix) playwright codegen", iconName: "record.circle", action: .customShell(command: "\(execPrefix) playwright codegen")),
                    TerminalCommandSuggestion(id: "js-pw-version", section: .quickCommands, title: "Check Playwright Version", commandPreview: "\(execPrefix) playwright --version", iconName: "stethoscope", action: .customShell(command: "\(execPrefix) playwright --version"))
                ]
                placeholders = [
                    commandPreview(for: .install, packageManager: pm),
                    commandPreview(for: .installPlaywrightBrowsers, packageManager: pm),
                    "\(execPrefix) playwright test --list"
                ]
            } else {
                fwHeader = "CodeceptJS & Browsers"
                quickHeader = "Quick CodeceptJS Commands (\(pm.rawValue))"
                fwItems = [
                    TerminalCommandSuggestion(id: "js-cc-upgrade", section: .frameworkAndBrowsers, title: "Update CodeceptJS", commandPreview: commandPreview(for: .upgradeCodeceptJS, packageManager: pm), iconName: "arrow.up.circle", action: .upgradeCodeceptJS),
                    TerminalCommandSuggestion(id: "js-cc-browsers", section: .frameworkAndBrowsers, title: "Install Playwright Browsers", commandPreview: commandPreview(for: .installPlaywrightBrowsers, packageManager: pm), iconName: "globe", action: .installPlaywrightBrowsers)
                ]
                quickItems = [
                    TerminalCommandSuggestion(id: "js-cc-check", section: .quickCommands, title: "Check Environment", commandPreview: "\(execPrefix) codeceptjs check", iconName: "stethoscope", action: .customShell(command: "\(execPrefix) codeceptjs check")),
                    TerminalCommandSuggestion(id: "js-cc-dry", section: .quickCommands, title: "Dry Run Tests", commandPreview: "\(execPrefix) codeceptjs dry-run", iconName: "checklist", action: .customShell(command: "\(execPrefix) codeceptjs dry-run")),
                    TerminalCommandSuggestion(id: "js-cc-def", section: .quickCommands, title: "Generate Type Definitions", commandPreview: "\(execPrefix) codeceptjs def", iconName: "curlybraces", action: .customShell(command: "\(execPrefix) codeceptjs def"))
                ]
                placeholders = [
                    commandPreview(for: .update, packageManager: pm),
                    commandPreview(for: .upgradeCodeceptJS, packageManager: pm),
                    commandPreview(for: .installPlaywrightBrowsers, packageManager: pm)
                ]
            }

            return TerminalEnvironmentSuggestions(
                environment: envKind,
                framework: framework,
                badgeTitle: envKind.badgeTitle,
                dependenciesHeader: "Dependencies (\(pm.rawValue))",
                frameworkHeader: fwHeader,
                quickCommandsHeader: quickHeader,
                dependencyItems: depItems,
                frameworkItems: fwItems,
                quickCommandItems: quickItems,
                emptyLogHint: "Ready. Press ⌘R to run tests, use the \(pm.rawValue) menu to update dependencies or run scripts, or run any shell command below.",
                placeholderExamples: placeholders
            )
        }
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
        case .runMobilewrightDoctor:
            switch packageManager {
            case .npm: return "npx mobilewright doctor"
            case .pnpm: return "pnpm exec mobilewright doctor"
            case .yarn: return "yarn mobilewright doctor"
            case .bun: return "bunx mobilewright doctor"
            }
        case .runScript(let name): return "\(packageManager.rawValue) run \(name)"
        case .customShell(let cmd): return cmd
        }
    }
}
