import Foundation
#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif

public enum ConsoleExecutionMode: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case builtIn
    case systemTerminal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .builtIn: return "Built-in Console"
        case .systemTerminal: return "System Console"
        }
    }

    public var shortName: String {
        switch self {
        case .builtIn: return "Built-in"
        case .systemTerminal: return "System"
        }
    }

    public var symbolName: String {
        switch self {
        case .builtIn: return "rectangle.bottomthird.inset.filled"
        case .systemTerminal: return "terminal"
        }
    }
}

public struct DetectedTerminalApp: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let bundleIdentifier: String?
    public let isSystemDefault: Bool

    public init(name: String, path: String, bundleIdentifier: String?, isSystemDefault: Bool) {
        self.name = name
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.isSystemDefault = isSystemDefault
    }
}

public enum SystemTerminalLauncherError: LocalizedError {
    case terminalAppNotFound(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .terminalAppNotFound(let path):
            return "System console application not found at \(path)."
        case .launchFailed(let details):
            return "Could not launch system console: \(details)"
        }
    }
}

public enum SystemTerminalLauncher {
    private static let launcherDirectoryName = "terminal-launchers"
    private static let maxRetainedLaunchers = 15

    public static let fallbackTerminalAppURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    /// Resolves the macOS system default application registered to open `.command` terminal scripts.
    public static func resolveSystemDefaultTerminalAppURL() -> URL {
        #if canImport(AppKit)
        if let commandType = UTType(filenameExtension: "command"),
           let appURL = NSWorkspace.shared.urlForApplication(toOpen: commandType),
           FileManager.default.fileExists(atPath: appURL.path) {
            return appURL
        }
        #endif
        return fallbackTerminalAppURL
    }

    /// Resolves the active terminal application URL, honoring an optional user override.
    public static func resolveTargetTerminalAppURL(preferredAppPath: String = "") -> URL {
        let trimmed = preferredAppPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, FileManager.default.fileExists(atPath: trimmed) {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        return resolveSystemDefaultTerminalAppURL()
    }

    /// Friendly display name (e.g. "Terminal", "iTerm2", "Ghostty") for an app bundle URL.
    public static func displayName(forAppAt url: URL) -> String {
        if let bundle = Bundle(url: url) {
            if let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return display
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    public static func activeTerminalDisplayName(preferredAppPath: String = "") -> String {
        displayName(forAppAt: resolveTargetTerminalAppURL(preferredAppPath: preferredAppPath))
    }

    public static func systemDefaultTerminalDisplayName() -> String {
        displayName(forAppAt: resolveSystemDefaultTerminalAppURL())
    }

    /// Discovers installed macOS terminal applications for Settings selection.
    public static func detectInstalledTerminalApps() -> [DetectedTerminalApp] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let defaultURL = resolveSystemDefaultTerminalAppURL().standardizedFileURL

        let knownPaths: [String] = [
            defaultURL.path,
            "/System/Applications/Utilities/Terminal.app",
            "/Applications/iTerm.app",
            "\(home)/Applications/iTerm.app",
            "/Applications/Ghostty.app",
            "\(home)/Applications/Ghostty.app",
            "/Applications/Warp.app",
            "\(home)/Applications/Warp.app",
            "/Applications/WezTerm.app",
            "\(home)/Applications/WezTerm.app",
            "/Applications/Alacritty.app",
            "\(home)/Applications/Alacritty.app",
            "/Applications/kitty.app",
            "\(home)/Applications/kitty.app",
            "/Applications/Hyper.app",
            "\(home)/Applications/Hyper.app"
        ]

        var seen = Set<String>()
        var detected: [DetectedTerminalApp] = []

        for rawPath in knownPaths {
            let stdPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            guard seen.insert(stdPath).inserted else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: stdPath, isDirectory: &isDir), isDir.boolValue else { continue }
            let url = URL(fileURLWithPath: stdPath)
            let bundleID = Bundle(url: url)?.bundleIdentifier
            detected.append(
                DetectedTerminalApp(
                    name: displayName(forAppAt: url),
                    path: stdPath,
                    bundleIdentifier: bundleID,
                    isSystemDefault: stdPath == defaultURL.path
                )
            )
        }
        return detected
    }

    /// Generates an executable zsh `.command` script that runs `command` in the user's real TTY,
    /// preserves the user's login shell `$PATH`, prints an exit-code summary, and keeps an interactive
    /// shell open in the workspace directory afterward.
    public static func buildLauncherScript(
        command: BuiltCommand,
        runtime: JSRuntimeKind,
        title: String,
        priorityPathDirs: [String] = [],
        fallbackPathDirs: [String] = [],
        keepShellOpen: Bool = true
    ) -> String {
        var lines: [String] = [
            "#!/bin/zsh -l",
            "# Ceptra System Console Launcher",
            "",
            "cd \(CommandBuilder.shellSingleQuote(command.workingDirectory.path)) || exit 1",
            ""
        ]

        let cleanPriority = uniqueNonEmpty(priorityPathDirs)
        let cleanFallback = uniqueNonEmpty(fallbackPathDirs)
        if !cleanPriority.isEmpty || !cleanFallback.isEmpty {
            var pathSegments: [String] = []
            if !cleanPriority.isEmpty {
                pathSegments.append(CommandBuilder.shellSingleQuote(cleanPriority.joined(separator: ":")))
            }
            pathSegments.append("\"$PATH\"")
            if !cleanFallback.isEmpty {
                pathSegments.append(CommandBuilder.shellSingleQuote(cleanFallback.joined(separator: ":")))
            }
            lines.append("export PATH=\(pathSegments.joined(separator: ":"))")
        }

        // Export only explicit Ceptra/user environment overrides (never stale GUI ProcessInfo vars)
        let sortedKeys = command.environmentOverrides.keys.sorted()
        for key in sortedKeys {
            guard isValidEnvKey(key), let value = command.environmentOverrides[key] else { continue }
            if key == "NODE_OPTIONS" {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let quoted = CommandBuilder.shellSingleQuote(trimmed)
                lines.append("case \" ${NODE_OPTIONS:-} \" in")
                lines.append("  *\(quoted)*) ;;")
                lines.append("  *) export NODE_OPTIONS=\"${NODE_OPTIONS:+${NODE_OPTIONS} }\"\(quoted) ;;")
                lines.append("esac")
            } else {
                lines.append("export \(key)=\(CommandBuilder.shellSingleQuote(value))")
            }
        }

        lines.append("")
        lines.append("printf '\\033[1;36m[Ceptra]\\033[0m %s (%s)\\n' \(CommandBuilder.shellSingleQuote(title)) \(CommandBuilder.shellSingleQuote(runtime.displayName))")
        lines.append("printf '\\033[2m$ %s\\033[0m\\n\\n' \(CommandBuilder.shellSingleQuote(command.displayCommand))")
        lines.append("")
        lines.append("CEPTRA_START=$(date +%s)")
        lines.append("CEPTRA_INTERRUPTED=0")
        lines.append("trap 'CEPTRA_INTERRUPTED=1' INT")
        lines.append("")

        if command.executablePath == "/bin/zsh",
           command.arguments.count == 2,
           command.arguments[0] == "-c" {
            // Execute custom workspace shell commands directly so pipes, globs, and && work naturally
            lines.append(command.arguments[1])
        } else {
            let invocation = ([command.executablePath] + command.arguments)
                .map { CommandBuilder.shellSingleQuote($0) }
                .joined(separator: " ")
            lines.append(invocation)
        }

        lines.append("CEPTRA_EXIT=$?")
        lines.append("trap - INT")
        lines.append("")
        lines.append("CEPTRA_END=$(date +%s)")
        lines.append("CEPTRA_ELAPSED=$((CEPTRA_END - CEPTRA_START))")
        lines.append("")
        lines.append("echo \"\"")
        lines.append("if [ \"$CEPTRA_EXIT\" -eq 0 ]; then")
        lines.append("  printf '\\033[32m[Ceptra]\\033[0m Finished with exit code 0 (%ss)\\n' \"$CEPTRA_ELAPSED\"")
        lines.append("elif [ \"$CEPTRA_INTERRUPTED\" -eq 1 ]; then")
        lines.append("  printf '\\033[33m[Ceptra]\\033[0m Interrupted (exit %s, %ss)\\n' \"$CEPTRA_EXIT\" \"$CEPTRA_ELAPSED\"")
        lines.append("else")
        lines.append("  printf '\\033[31m[Ceptra]\\033[0m Finished with exit code %s (%ss)\\n' \"$CEPTRA_EXIT\" \"$CEPTRA_ELAPSED\"")
        lines.append("fi")

        if keepShellOpen {
            lines.append("echo \"\"")
            lines.append("exec \"${SHELL:-/bin/zsh}\" -i")
        } else {
            lines.append("exit \"$CEPTRA_EXIT\"")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes a `.command` launcher script with 0755 permissions under `~/Library/Caches/Ceptra/terminal-launchers/`.
    public static func writeLauncherScript(_ content: String) throws -> URL {
        let fm = FileManager.default
        let cacheBase = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let dir = cacheBase
            .appendingPathComponent("Ceptra", isDirectory: true)
            .appendingPathComponent(launcherDirectoryName, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        pruneOldLaunchers(in: dir)

        let timestamp = Int(Date().timeIntervalSince1970)
        let shortID = UUID().uuidString.prefix(8).lowercased()
        let scriptURL = dir.appendingPathComponent("ceptra-\(timestamp)-\(shortID).command")
        try content.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    /// Launches a `BuiltCommand` in the macOS system default (or user-selected) console application.
    @discardableResult
    public static func launch(
        command: BuiltCommand,
        runtime: JSRuntimeKind,
        title: String,
        toolchain: ResolvedToolchain,
        preferredAppPath: String = "",
        keepShellOpen: Bool = true
    ) throws -> String {
        var priorityDirs: [String] = [
            command.workingDirectory.appendingPathComponent("node_modules/.bin").path
        ]
        if let activePath = toolchain.activeRuntimePath {
            priorityDirs.insert(URL(fileURLWithPath: activePath).deletingLastPathComponent().path, at: 0)
        }
        let fallbackDirs = toolchain.searchPath
            .split(separator: ":")
            .map(String.init)
            .filter { !priorityDirs.contains($0) }

        let script = buildLauncherScript(
            command: command,
            runtime: runtime,
            title: title,
            priorityPathDirs: priorityDirs,
            fallbackPathDirs: fallbackDirs,
            keepShellOpen: keepShellOpen
        )
        let scriptURL = try writeLauncherScript(script)
        let appURL = resolveTargetTerminalAppURL(preferredAppPath: preferredAppPath)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw SystemTerminalLauncherError.terminalAppNotFound(appURL.path)
        }

        try openScript(scriptURL, inTerminalAppAt: appURL, workingDirectory: command.workingDirectory, isCustomApp: !preferredAppPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        return displayName(forAppAt: appURL)
    }

    /// Opens an interactive shell at `directoryURL` inside the system default (or selected) console app.
    @discardableResult
    public static func openWorkspaceDirectory(
        _ directoryURL: URL,
        preferredAppPath: String = ""
    ) throws -> String {
        let appURL = resolveTargetTerminalAppURL(preferredAppPath: preferredAppPath)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw SystemTerminalLauncherError.terminalAppNotFound(appURL.path)
        }

        let kind = classifyTerminalApp(at: appURL)
        switch kind {
        case .alacritty:
            try runOpenCLI(["-na", appURL.path, "--args", "--working-directory", directoryURL.path])
        case .wezterm:
            try runOpenCLI(["-na", appURL.path, "--args", "start", "--cwd", directoryURL.path])
        case .kitty:
            try runOpenCLI(["-na", appURL.path, "--args", "--directory", directoryURL.path])
        case .ghostty, .standardDotCommand:
            #if canImport(AppKit)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([directoryURL], withApplicationAt: appURL, configuration: config, completionHandler: nil)
            #else
            try runOpenCLI(["-a", appURL.path, directoryURL.path])
            #endif
        }
        return displayName(forAppAt: appURL)
    }

    // MARK: - Helpers

    private enum TerminalAppKind {
        case standardDotCommand
        case ghostty
        case alacritty
        case wezterm
        case kitty
    }

    private static func classifyTerminalApp(at appURL: URL) -> TerminalAppKind {
        let bundleID = Bundle(url: appURL)?.bundleIdentifier?.lowercased() ?? ""
        let fileName = appURL.lastPathComponent.lowercased()
        if bundleID.contains("ghostty") || fileName.contains("ghostty") { return .ghostty }
        if bundleID.contains("alacritty") || fileName.contains("alacritty") { return .alacritty }
        if bundleID.contains("wezterm") || fileName.contains("wezterm") { return .wezterm }
        if bundleID.contains("kitty") || fileName == "kitty.app" { return .kitty }
        return .standardDotCommand
    }

    private static func openScript(
        _ scriptURL: URL,
        inTerminalAppAt appURL: URL,
        workingDirectory: URL,
        isCustomApp: Bool
    ) throws {
        switch classifyTerminalApp(at: appURL) {
        case .ghostty:
            try runOpenCLI(["-na", appURL.path, "--args", "-e", scriptURL.path])
        case .alacritty:
            try runOpenCLI(["-na", appURL.path, "--args", "--working-directory", workingDirectory.path, "-e", scriptURL.path])
        case .wezterm:
            try runOpenCLI(["-na", appURL.path, "--args", "start", "--cwd", workingDirectory.path, "--", scriptURL.path])
        case .kitty:
            try runOpenCLI(["-na", appURL.path, "--args", "--directory", workingDirectory.path, scriptURL.path])
        case .standardDotCommand:
            #if canImport(AppKit)
            if isCustomApp {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.open([scriptURL], withApplicationAt: appURL, configuration: config, completionHandler: nil)
            } else {
                // Use macOS LaunchServices default `.command` handler directly
                if !NSWorkspace.shared.open(scriptURL) {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    NSWorkspace.shared.open([scriptURL], withApplicationAt: appURL, configuration: config, completionHandler: nil)
                }
            }
            #else
            try runOpenCLI(["-a", appURL.path, scriptURL.path])
            #endif
        }
    }

    private static func runOpenCLI(_ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit code \(proc.terminationStatus)"
            throw SystemTerminalLauncherError.launchFailed(errText)
        }
    }

    private static func pruneOldLaunchers(in dir: URL) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let commandFiles = urls.filter { $0.pathExtension == "command" }
        guard commandFiles.count > maxRetainedLaunchers else { return }

        let sorted = commandFiles.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate > rDate
        }
        for stale in sorted.dropFirst(maxRetainedLaunchers) {
            try? fm.removeItem(at: stale)
        }
    }

    private static func uniqueNonEmpty(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func isValidEnvKey(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter || first == "_" else { return false }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
