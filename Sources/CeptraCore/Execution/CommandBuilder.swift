import Foundation

public struct BuiltCommand: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: URL
    public let environment: [String: String]
    public let displayCommand: String

    public init(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        displayCommand: String
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.displayCommand = displayCommand
    }
}

public enum CommandBuilder {
    public static func build(
        mode: CodeceptRunMode,
        options: RunOptions,
        workspaceRoot: URL,
        configFilePath: String? = nil,
        toolchain: ResolvedToolchain
    ) -> BuiltCommand {
        var args: [String] = toolchain.prefixArguments

        switch mode {
        case .runAll:
            args.append("run")
            appendCommonRunFlags(to: &args, options: options, configFilePath: configFilePath, allowNoColors: true)

        case .runFile(let relativePath):
            args.append("run")
            args.append(resolveTestArgument(relativePath, workspaceRoot: workspaceRoot, configFilePath: configFilePath))
            appendCommonRunFlags(to: &args, options: options, configFilePath: configFilePath, allowNoColors: true)

        case .runScenario(let relativePath, let scenarioTitle):
            args.append("run")
            if let relativePath, !relativePath.isEmpty {
                args.append(resolveTestArgument(relativePath, workspaceRoot: workspaceRoot, configFilePath: configFilePath))
            }
            appendCommonRunFlags(to: &args, options: options, configFilePath: configFilePath, allowNoColors: true, overrideGrep: escapeRegExp(scenarioTitle))

        case .runTag(let tag):
            args.append("run")
            let normalizedTag = tag.hasPrefix("@") ? tag : "@\(tag)"
            appendCommonRunFlags(to: &args, options: options, configFilePath: configFilePath, allowNoColors: true, overrideGrep: escapeRegExp(normalizedTag))

        case .runLastFailed:
            args.append("run")
            args.append("--last-failed")
            appendCommonRunFlags(to: &args, options: options, configFilePath: configFilePath, allowNoColors: true)

        case .runWorkers(let count, let strategy):
            args.append("run-workers")
            args.append(String(max(1, count)))
            args.append(contentsOf: ["--by", strategy.rawValue])
            if let configFilePath, !configFilePath.isEmpty {
                args.append(contentsOf: ["-c", configFilePath])
            }
            if options.debug { args.append("--debug") }
            if options.verbose { args.append("--verbose") }
            if options.aiEnabled { args.append("--ai") }
            if !options.profile.trimmingCharacters(in: .whitespaces).isEmpty {
                args.append(contentsOf: ["--profile", options.profile.trimmingCharacters(in: .whitespaces)])
            }
            if !options.grepPattern.trimmingCharacters(in: .whitespaces).isEmpty {
                args.append(contentsOf: ["--grep", options.grepPattern.trimmingCharacters(in: .whitespaces)])
            }
            if !options.enabledPlugins.isEmpty {
                args.append(contentsOf: ["-p", options.enabledPlugins.joined(separator: ",")])
            }

        case .dryRun(let relativePath):
            args.append("dry-run")
            if let relativePath, !relativePath.isEmpty {
                args.append(resolveTestArgument(relativePath, workspaceRoot: workspaceRoot, configFilePath: configFilePath))
            }
            if let configFilePath, !configFilePath.isEmpty {
                args.append(contentsOf: ["-c", configFilePath])
            }
            if options.showSteps { args.append("--steps") }
            if !options.grepPattern.trimmingCharacters(in: .whitespaces).isEmpty {
                args.append(contentsOf: ["--grep", options.grepPattern.trimmingCharacters(in: .whitespaces)])
            }

        case .checkEnvironment:
            args.append("check")
            if let configFilePath, !configFilePath.isEmpty {
                args.append(contentsOf: ["-c", configFilePath])
            }

        case .generateDefinitions:
            args.append("def")
            if let configFilePath, !configFilePath.isEmpty {
                args.append(contentsOf: ["-c", configFilePath])
            }

        case .listActions:
            args.append("list")
            if let configFilePath, !configFilePath.isEmpty {
                args.append(contentsOf: ["-c", configFilePath])
            }
        }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolchain.searchPath
        env["FORCE_COLOR"] = "0"
        env["NO_COLOR"] = "1"
        for (key, value) in options.environmentVariables where !key.trimmingCharacters(in: .whitespaces).isEmpty {
            env[key.trimmingCharacters(in: .whitespaces)] = value
        }

        let displayParts = [URL(fileURLWithPath: toolchain.codeceptExecutable).lastPathComponent] + args.map { displayQuote($0) }

        return BuiltCommand(
            executablePath: toolchain.codeceptExecutable,
            arguments: args,
            workingDirectory: workspaceRoot,
            environment: env,
            displayCommand: displayParts.joined(separator: " ")
        )
    }

    private static func appendCommonRunFlags(
        to args: inout [String],
        options: RunOptions,
        configFilePath: String?,
        allowNoColors: Bool,
        overrideGrep: String? = nil
    ) {
        if let configFilePath, !configFilePath.isEmpty {
            args.append(contentsOf: ["-c", configFilePath])
        }
        if options.showSteps { args.append("--steps") }
        if options.debug { args.append("--debug") }
        if options.verbose { args.append("--verbose") }
        if options.aiEnabled { args.append("--ai") }
        if options.bailOnFail { args.append("--bail") }
        if options.noTimeouts { args.append("--no-timeouts") }
        if allowNoColors { args.append("--no-colors") }

        let profile = options.profile.trimmingCharacters(in: .whitespaces)
        if !profile.isEmpty {
            args.append(contentsOf: ["--profile", profile])
        }

        let effectiveGrep = overrideGrep ?? options.grepPattern.trimmingCharacters(in: .whitespaces)
        if !effectiveGrep.isEmpty {
            args.append(contentsOf: ["--grep", effectiveGrep])
        }

        if !options.enabledPlugins.isEmpty {
            args.append(contentsOf: ["-p", options.enabledPlugins.joined(separator: ",")])
        }
    }

    /// Resolves a test file argument so CodeceptJS finds it even when `-c <config>` resides in a
    /// nested subdirectory or external directory (where CodeceptJS sets `store.codeceptDir = dirname(config)`).
    private static func resolveTestArgument(
        _ path: String,
        workspaceRoot: URL,
        configFilePath: String?
    ) -> String {
        if path.hasPrefix("/") {
            return path
        }
        guard let configFilePath, !configFilePath.isEmpty else {
            return path
        }
        let configDir = URL(fileURLWithPath: configFilePath).deletingLastPathComponent().standardizedFileURL.path
        let rootPath = workspaceRoot.standardizedFileURL.path
        if configDir == rootPath {
            return path
        }
        return workspaceRoot.appendingPathComponent(path).standardizedFileURL.path
    }

    public static func shellSingleQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func escapeRegExp(_ literal: String) -> String {
        let special: Set<Character> = ["\\", "^", "$", ".", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|"]
        var out = ""
        out.reserveCapacity(literal.count + 8)
        for c in literal {
            if special.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    private static func displayQuote(_ arg: String) -> String {
        if arg.contains(" ") || arg.contains("\"") || arg.contains("'") {
            return shellSingleQuote(arg)
        }
        return arg
    }
}
