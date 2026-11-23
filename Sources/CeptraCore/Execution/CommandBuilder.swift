import Foundation

public struct BuiltCommand: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: URL
    public let environment: [String: String]
    public let environmentOverrides: [String: String]
    public let displayCommand: String

    public init(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        environmentOverrides: [String: String] = [:],
        displayCommand: String
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.environmentOverrides = environmentOverrides
        self.displayCommand = displayCommand
    }
}

public enum CommandBuilder {
    public static func build(
        mode: CodeceptRunMode,
        options: RunOptions,
        workspaceRoot: URL,
        configFilePath: String? = nil,
        toolchain: ResolvedToolchain,
        framework: TestFrameworkKind? = nil,
        debugOptions: DebugLaunchOptions? = nil,
        traceOutputDirectory: URL? = nil,
        colorOutput: Bool = false,
        secretEnvironmentOverrides: [String: String] = [:]
    ) -> BuiltCommand {
        let effectiveFramework = framework ?? toolchain.framework
        if effectiveFramework == .playwright {
            return buildPlaywright(
                mode: mode,
                options: options,
                workspaceRoot: workspaceRoot,
                configFilePath: configFilePath,
                toolchain: toolchain,
                debugOptions: debugOptions,
                traceOutputDirectory: traceOutputDirectory,
                colorOutput: colorOutput,
                secretEnvironmentOverrides: secretEnvironmentOverrides
            )
        }

        var args: [String] = toolchain.prefixArguments
        let allowNoColors = !colorOutput

        switch mode {
        case .runAll:
            args.append("run")
            appendCommonRunFlags(to: &args, options: options, configFilePath: configFilePath, allowNoColors: allowNoColors)

        case .runFile(let relativePath):
            args.append("run")
            args.append(resolveTestArgument(relativePath, workspaceRoot: workspaceRoot, configFilePath: configFilePath))
            appendCommonRunFlags(to: &args, options: options, configFilePath: configFilePath, allowNoColors: allowNoColors)

        case .runScenario(let relativePath, let scenarioTitle):
            args.append("run")
            if let relativePath, !relativePath.isEmpty {
                args.append(resolveTestArgument(relativePath, workspaceRoot: workspaceRoot, configFilePath: configFilePath))
            }
            appendCommonRunFlags(to: &args, options: options, configFilePath: configFilePath, allowNoColors: allowNoColors, overrideGrep: escapeRegExp(scenarioTitle))

        case .runTag(let tag):
            args.append("run")
            let normalizedTag = tag.hasPrefix("@") ? tag : "@\(tag)"
            appendCommonRunFlags(to: &args, options: options, configFilePath: configFilePath, allowNoColors: allowNoColors, overrideGrep: escapeRegExp(normalizedTag))

        case .runLastFailed:
            args.append("run")
            args.append("--last-failed")
            appendCommonRunFlags(to: &args, options: options, configFilePath: configFilePath, allowNoColors: allowNoColors)

        case .runWorkers(let count, let strategy, let selectedRuns, let serialPattern, let lastFailed):
            args.append("run-workers")
            args.append(String(max(1, count)))
            let cleanRuns = selectedRuns
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !cleanRuns.isEmpty {
                args.append(contentsOf: cleanRuns)
            }
            args.append(contentsOf: ["--by", strategy.rawValue])
            if let serialPattern {
                let cleanSerial = serialPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanSerial.isEmpty {
                    args.append(contentsOf: ["--serial", cleanSerial])
                }
            }
            if lastFailed {
                args.append("--last-failed")
            }
            if let configFilePath, !configFilePath.isEmpty {
                args.append(contentsOf: ["-c", configFilePath])
            }
            if options.debug { args.append("--debug") }
            if options.verbose { args.append("--verbose") }
            if options.aiEnabled { args.append("--ai") }
            let workerProfile = options.profile.trimmingCharacters(in: .whitespaces)
            if !workerProfile.isEmpty {
                args.append(contentsOf: ["--profile", workerProfile])
            }
            let workerGrep = options.grepPattern.trimmingCharacters(in: .whitespaces)
            if !workerGrep.isEmpty {
                args.append(contentsOf: ["--grep", workerGrep])
                if options.invertGrep { args.append("--invert") }
            }
            if !options.enabledPlugins.isEmpty {
                args.append(contentsOf: ["-p", options.enabledPlugins.joined(separator: ",")])
            }

        case .runMultiple(let suites, let runAll):
            args.append("run-multiple")
            let cleanSuites = suites
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if runAll || cleanSuites.isEmpty {
                args.append("--all")
            } else {
                args.append(contentsOf: cleanSuites)
            }
            if let configFilePath, !configFilePath.isEmpty {
                args.append(contentsOf: ["-c", configFilePath])
            }
            if options.showSteps { args.append("--steps") }
            if options.debug { args.append("--debug") }
            if options.verbose { args.append("--verbose") }
            if options.aiEnabled { args.append("--ai") }
            let multipleProfile = options.profile.trimmingCharacters(in: .whitespaces)
            if !multipleProfile.isEmpty {
                args.append(contentsOf: ["--profile", multipleProfile])
            }
            let multipleGrep = options.grepPattern.trimmingCharacters(in: .whitespaces)
            if !multipleGrep.isEmpty {
                args.append(contentsOf: ["--grep", multipleGrep])
                if options.invertGrep { args.append("--invert") }
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

        case .playwrightCodegen(let url):
            args.append("codegen")
            if let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                args.append(url.trimmingCharacters(in: .whitespacesAndNewlines))
            }

        case .playwrightShowReport(let reportDir):
            args.append("show-report")
            if let reportDir, !reportDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                args.append(reportDir.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

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
        for (key, value) in options.environmentVariables where !key.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmedKey = key.trimmingCharacters(in: .whitespaces)
            env[trimmedKey] = value
            envOverrides[trimmedKey] = value
        }
        // Secret env overrides (e.g., Keychain AI bridge) are injected ONLY into the child Process
        // `environment` — NEVER into `environmentOverrides` (used by SystemTerminalLauncher) or `displayCommand`.
        for (key, value) in secretEnvironmentOverrides where !key.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmedKey = key.trimmingCharacters(in: .whitespaces)
            env[trimmedKey] = value
        }
        if toolchain.runtime == .node,
           options.esmCjsCompat,
           let preloadURL = NodeCompatLoader.ensurePreloadFileURL() {
            env["NODE_OPTIONS"] = NodeCompatLoader.mergedNodeOptions(
                existing: env["NODE_OPTIONS"],
                preloadFileURL: preloadURL
            )
            envOverrides["NODE_OPTIONS"] = NodeCompatLoader.mergedNodeOptions(
                existing: envOverrides["NODE_OPTIONS"],
                preloadFileURL: preloadURL
            )
        }

        if let debugOptions, debugOptions.enabled, mode.supportsInteractiveDebugging {
            if !args.contains("--no-timeouts") {
                args.append("--no-timeouts")
            }
            let existingNodeOpts = (env["NODE_OPTIONS"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let inspectFlag = "--inspect-brk=127.0.0.1:0"
            if !existingNodeOpts.contains("--inspect") {
                env["NODE_OPTIONS"] = existingNodeOpts.isEmpty ? inspectFlag : "\(existingNodeOpts) \(inspectFlag)"
            }
            let existingOverrideOpts = (envOverrides["NODE_OPTIONS"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !existingOverrideOpts.contains("--inspect") {
                envOverrides["NODE_OPTIONS"] = existingOverrideOpts.isEmpty ? inspectFlag : "\(existingOverrideOpts) \(inspectFlag)"
            }
            if debugOptions.headedBrowser && env["HEADLESS"] == nil {
                env["HEADLESS"] = "false"
                envOverrides["HEADLESS"] = "false"
            }
        }

        if let traceOutputDirectory,
           options.timeTravelTrace,
           supportsTimeTravelTrace(mode),
           let pluginURL = TimeTravelRecorderLoader.ensurePluginFileURL() {
            env["CEPTRA_TIME_TRAVEL_DIR"] = traceOutputDirectory.path
            envOverrides["CEPTRA_TIME_TRAVEL_DIR"] = traceOutputDirectory.path
            args.append(contentsOf: ["-o", TimeTravelRecorderLoader.overrideJSONArgument(pluginFileURL: pluginURL)])
        }

        let rootPrefixes: [String] = [
            workspaceRoot.standardizedFileURL.path,
            workspaceRoot.resolvingSymlinksInPath().path
        ].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let displayArgs = args.enumerated().map { idx, arg -> String in
            if idx < toolchain.prefixArguments.count {
                for prefix in rootPrefixes where arg.hasPrefix(prefix) {
                    return displayQuote(String(arg.dropFirst(prefix.count)))
                }
            }
            return displayQuote(arg)
        }
        let execDisplayName = URL(fileURLWithPath: toolchain.codeceptExecutable).lastPathComponent
        let displayParts = (execDisplayName == "env" && !displayArgs.isEmpty)
            ? displayArgs
            : ([execDisplayName] + displayArgs)

        return BuiltCommand(
            executablePath: toolchain.codeceptExecutable,
            arguments: args,
            workingDirectory: workspaceRoot,
            environment: env,
            environmentOverrides: envOverrides,
            displayCommand: displayParts.joined(separator: " ")
        )
    }

    // MARK: - Playwright Test (@playwright/test) Command Builder

    private static func buildPlaywright(
        mode: CodeceptRunMode,
        options: RunOptions,
        workspaceRoot: URL,
        configFilePath: String?,
        toolchain: ResolvedToolchain,
        debugOptions: DebugLaunchOptions?,
        traceOutputDirectory: URL?,
        colorOutput: Bool,
        secretEnvironmentOverrides: [String: String]
    ) -> BuiltCommand {
        var args: [String] = toolchain.prefixArguments
        var isTestExecution = false
        var explicitProjectsOverridden = false
        var explicitWorkersSet = false

        switch mode {
        case .runAll:
            args.append("test")
            isTestExecution = true
            appendPlaywrightCommonFlags(to: &args, options: options, configFilePath: configFilePath)

        case .runFile(let relativePath):
            args.append("test")
            args.append(resolvePlaywrightTestArgument(relativePath, workspaceRoot: workspaceRoot))
            isTestExecution = true
            appendPlaywrightCommonFlags(to: &args, options: options, configFilePath: configFilePath)

        case .runScenario(let relativePath, let scenarioTitle):
            args.append("test")
            if let relativePath, !relativePath.isEmpty {
                args.append(resolvePlaywrightTestArgument(relativePath, workspaceRoot: workspaceRoot))
            }
            isTestExecution = true
            appendPlaywrightCommonFlags(
                to: &args,
                options: options,
                configFilePath: configFilePath,
                overrideGrep: escapeRegExp(scenarioTitle)
            )

        case .runTag(let tag):
            args.append("test")
            let normalizedTag = tag.hasPrefix("@") ? tag : "@\(tag)"
            isTestExecution = true
            appendPlaywrightCommonFlags(
                to: &args,
                options: options,
                configFilePath: configFilePath,
                overrideGrep: escapeRegExp(normalizedTag)
            )

        case .runLastFailed:
            args.append("test")
            args.append("--last-failed")
            isTestExecution = true
            appendPlaywrightCommonFlags(to: &args, options: options, configFilePath: configFilePath)

        case .runWorkers(let count, _, let selectedRuns, _, let lastFailed):
            args.append("test")
            args.append("--workers=\(max(1, count))")
            explicitWorkersSet = true
            let cleanProjects = selectedRuns
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !cleanProjects.isEmpty {
                explicitProjectsOverridden = true
                for project in cleanProjects {
                    args.append("--project=\(project)")
                }
            }
            if lastFailed {
                args.append("--last-failed")
            }
            isTestExecution = true
            appendPlaywrightCommonFlags(
                to: &args,
                options: options,
                configFilePath: configFilePath,
                skipSelectedProjects: explicitProjectsOverridden
            )

        case .runMultiple(let suites, let runAll):
            args.append("test")
            let cleanProjects = suites
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !runAll && !cleanProjects.isEmpty {
                explicitProjectsOverridden = true
                for project in cleanProjects {
                    args.append("--project=\(project)")
                }
            } else {
                explicitProjectsOverridden = true
            }
            isTestExecution = true
            appendPlaywrightCommonFlags(
                to: &args,
                options: options,
                configFilePath: configFilePath,
                skipSelectedProjects: explicitProjectsOverridden
            )

        case .dryRun(let relativePath):
            args.append("test")
            if let relativePath, !relativePath.isEmpty {
                args.append(resolvePlaywrightTestArgument(relativePath, workspaceRoot: workspaceRoot))
            }
            args.append("--list")
            if let configFilePath, !configFilePath.isEmpty {
                args.append(contentsOf: ["-c", configFilePath])
            }
            let grep = options.grepPattern.trimmingCharacters(in: .whitespaces)
            if !grep.isEmpty {
                args.append(contentsOf: [options.invertGrep ? "--grep-invert" : "--grep", grep])
            }

        case .checkEnvironment:
            args.append("--version")

        case .generateDefinitions:
            args.append("codegen")

        case .listActions:
            args.append("test")
            args.append("--list")
            if let configFilePath, !configFilePath.isEmpty {
                args.append(contentsOf: ["-c", configFilePath])
            }

        case .playwrightCodegen(let url):
            args.append("codegen")
            if let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                args.append(url.trimmingCharacters(in: .whitespacesAndNewlines))
            }

        case .playwrightShowReport(let reportDir):
            args.append("show-report")
            if let reportDir, !reportDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                args.append(reportDir.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        var env = ProcessInfo.processInfo.environment
        var envOverrides: [String: String] = [:]
        env["PATH"] = toolchain.searchPath
        if !colorOutput {
            env["FORCE_COLOR"] = "0"
            env["NO_COLOR"] = "1"
            // Never block Built-in Console runs waiting for Ctrl+C on Playwright's HTML report server
            env["PLAYWRIGHT_HTML_OPEN"] = "never"
        } else {
            env.removeValue(forKey: "NO_COLOR")
            if env["FORCE_COLOR"] == "0" {
                env.removeValue(forKey: "FORCE_COLOR")
            }
        }
        for (key, value) in options.environmentVariables where !key.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmedKey = key.trimmingCharacters(in: .whitespaces)
            env[trimmedKey] = value
            envOverrides[trimmedKey] = value
        }
        for (key, value) in secretEnvironmentOverrides where !key.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmedKey = key.trimmingCharacters(in: .whitespaces)
            env[trimmedKey] = value
        }

        let isCDPDebug = (debugOptions?.enabled == true) && mode.supportsInteractiveDebugging
        if isCDPDebug {
            if !explicitWorkersSet && !args.contains(where: { $0.hasPrefix("--workers") }) {
                args.append("--workers=1")
            }
            if !args.contains(where: { $0.hasPrefix("--timeout") }) {
                args.append("--timeout=0")
            }
            if debugOptions?.headedBrowser == true && !args.contains("--headed") {
                args.append("--headed")
            }
            let existingNodeOpts = (env["NODE_OPTIONS"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let inspectFlag = "--inspect-brk=127.0.0.1:0"
            if !existingNodeOpts.contains("--inspect") {
                env["NODE_OPTIONS"] = existingNodeOpts.isEmpty ? inspectFlag : "\(existingNodeOpts) \(inspectFlag)"
            }
            let existingOverrideOpts = (envOverrides["NODE_OPTIONS"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !existingOverrideOpts.contains("--inspect") {
                envOverrides["NODE_OPTIONS"] = existingOverrideOpts.isEmpty ? inspectFlag : "\(existingOverrideOpts) \(inspectFlag)"
            }
        } else if isTestExecution && options.debug {
            // Playwright Inspector interactive debug mode (`PWDEBUG=1`)
            env["PWDEBUG"] = "1"
            envOverrides["PWDEBUG"] = "1"
            if !explicitWorkersSet && !args.contains(where: { $0.hasPrefix("--workers") }) {
                args.append("--workers=1")
            }
            if !args.contains(where: { $0.hasPrefix("--timeout") }) {
                args.append("--timeout=0")
            }
        }

        // Built-in Console reporter wiring: deterministic `list` output + zero-config Ceptra Time-Travel reporter
        if isTestExecution && !colorOutput {
            if let traceOutputDirectory,
               options.timeTravelTrace,
               supportsTimeTravelTrace(mode),
               let reporterURL = PlaywrightTimeTravelReporterLoader.ensureReporterFileURL() {
                env["CEPTRA_TIME_TRAVEL_DIR"] = traceOutputDirectory.path
                envOverrides["CEPTRA_TIME_TRAVEL_DIR"] = traceOutputDirectory.path
                args.append("--reporter=list,\(reporterURL.path)")
            } else {
                args.append("--reporter=list")
            }
        }

        let rootPrefixes: [String] = [
            workspaceRoot.standardizedFileURL.path,
            workspaceRoot.resolvingSymlinksInPath().path
        ].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let displayArgs = args.enumerated().map { idx, arg -> String in
            if idx < toolchain.prefixArguments.count {
                for prefix in rootPrefixes where arg.hasPrefix(prefix) {
                    return displayQuote(String(arg.dropFirst(prefix.count)))
                }
            }
            return displayQuote(arg)
        }
        let execDisplayName = URL(fileURLWithPath: toolchain.codeceptExecutable).lastPathComponent
        let displayParts = (execDisplayName == "env" && !displayArgs.isEmpty)
            ? displayArgs
            : ([execDisplayName] + displayArgs)

        return BuiltCommand(
            executablePath: toolchain.codeceptExecutable,
            arguments: args,
            workingDirectory: workspaceRoot,
            environment: env,
            environmentOverrides: envOverrides,
            displayCommand: displayParts.joined(separator: " ")
        )
    }

    private static func appendPlaywrightCommonFlags(
        to args: inout [String],
        options: RunOptions,
        configFilePath: String?,
        overrideGrep: String? = nil,
        skipSelectedProjects: Bool = false
    ) {
        if let configFilePath, !configFilePath.isEmpty {
            args.append(contentsOf: ["-c", configFilePath])
        }
        if options.playwrightHeaded {
            args.append("--headed")
        }
        if options.bailOnFail {
            args.append("--max-failures=1")
        }
        if options.noTimeouts {
            args.append("--timeout=0")
        }
        if options.playwrightUpdateSnapshots {
            args.append("--update-snapshots")
        }
        if options.playwrightTraceMode != .configDefault {
            args.append("--trace=\(options.playwrightTraceMode.rawValue)")
        }
        if let retries = options.playwrightRetries, retries >= 0 {
            args.append("--retries=\(retries)")
        }
        if !skipSelectedProjects && !options.playwrightSelectedProjects.isEmpty {
            for project in options.playwrightSelectedProjects {
                let clean = project.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    args.append("--project=\(clean)")
                }
            }
        }

        if let overrideGrep, !overrideGrep.isEmpty {
            args.append(contentsOf: ["--grep", overrideGrep])
        } else {
            let grep = options.grepPattern.trimmingCharacters(in: .whitespaces)
            if !grep.isEmpty {
                args.append(contentsOf: [options.invertGrep ? "--grep-invert" : "--grep", grep])
            }
        }
    }

    /// Normalizes a Playwright file target relative to `workspaceRoot` (the working directory).
    private static func resolvePlaywrightTestArgument(_ path: String, workspaceRoot: URL) -> String {
        let stdRoot = workspaceRoot.standardizedFileURL.path
        let prefix = stdRoot.hasSuffix("/") ? stdRoot : stdRoot + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
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
            if overrideGrep == nil && options.invertGrep {
                args.append("--invert")
            }
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

    private static func supportsTimeTravelTrace(_ mode: CodeceptRunMode) -> Bool {
        switch mode {
        case .runAll, .runFile, .runScenario, .runTag, .runLastFailed, .runWorkers, .runMultiple:
            return true
        case .dryRun, .checkEnvironment, .generateDefinitions, .listActions, .playwrightCodegen, .playwrightShowReport:
            return false
        }
    }

    private static func displayQuote(_ arg: String) -> String {
        if arg.contains(" ") || arg.contains("\"") || arg.contains("'") {
            return shellSingleQuote(arg)
        }
        return arg
    }
}
