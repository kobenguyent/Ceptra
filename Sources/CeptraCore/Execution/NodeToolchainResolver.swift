import Foundation

public enum JSRuntimeKind: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case node
    case bun

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .node: return "Node.js"
        case .bun: return "Bun"
        }
    }

    public var shortName: String {
        switch self {
        case .node: return "Node"
        case .bun: return "Bun"
        }
    }

    public var executableName: String { rawValue }
}

public struct ResolvedToolchain: Equatable, Sendable {
    public let framework: TestFrameworkKind
    public let runtime: JSRuntimeKind
    public let nodePath: String?
    public let bunPath: String?
    public let pythonPath: String?
    public let codeceptExecutable: String
    public let prefixArguments: [String]
    public let searchPath: String
    public let resolutionSource: String

    public var runnerExecutable: String { codeceptExecutable }

    public var activeRuntimePath: String? {
        if framework == .playwrightPython {
            return pythonPath
        }
        switch runtime {
        case .node: return nodePath
        case .bun: return bunPath
        }
    }

    public var isActiveRuntimeAvailable: Bool {
        activeRuntimePath != nil
    }

    public init(
        framework: TestFrameworkKind = .codeceptJS,
        runtime: JSRuntimeKind = .node,
        nodePath: String?,
        bunPath: String? = nil,
        pythonPath: String? = nil,
        codeceptExecutable: String,
        prefixArguments: [String],
        searchPath: String,
        resolutionSource: String
    ) {
        self.framework = framework
        self.runtime = runtime
        self.nodePath = nodePath
        self.bunPath = bunPath
        self.pythonPath = pythonPath
        self.codeceptExecutable = codeceptExecutable
        self.prefixArguments = prefixArguments
        self.searchPath = searchPath
        self.resolutionSource = resolutionSource
    }
}

public enum NodeToolchainResolver {
    public static func buildSearchPath(extraPaths: [String] = []) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = extraPaths + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.pyenv/shims",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/.fnm/current/bin",
            "\(home)/.asdf/shims",
            "\(home)/.local/share/mise/shims",
            "\(home)/.mise/shims"
        ]

        // Discover latest nvm node bin if present
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            let sorted = versions.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            for v in sorted.prefix(3) {
                candidates.append("\(nvmDir)/\(v)/bin")
            }
        }

        if let existing = ProcessInfo.processInfo.environment["PATH"], !existing.isEmpty {
            candidates.append(contentsOf: existing.split(separator: ":").map(String.init))
        }
        candidates.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])

        var seen = Set<String>()
        let unique = candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
        return unique.joined(separator: ":")
    }

    public static func findExecutable(named name: String, in searchPath: String) -> String? {
        let fm = FileManager.default
        for dir in searchPath.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public static func resolve(
        workspaceRoot: URL,
        framework: TestFrameworkKind = .codeceptJS,
        runtime: JSRuntimeKind = .node,
        customNodePath: String = "",
        customBunPath: String = "",
        customCodeceptPath: String = "",
        customPlaywrightPath: String = "",
        customPythonPath: String = ""
    ) -> ResolvedToolchain {
        let fm = FileManager.default
        let trimmedNode = customNodePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBun = customBunPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCodecept = customCodeceptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPlaywright = customPlaywrightPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPython = customPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)

        if framework == .playwrightPython {
            return resolvePlaywrightPythonToolchain(
                workspaceRoot: workspaceRoot,
                trimmedPython: trimmedPython,
                trimmedNode: trimmedNode,
                trimmedBun: trimmedBun
            )
        }

        var extraDirs: [String] = [
            workspaceRoot.appendingPathComponent("node_modules/.bin").path
        ]
        let customNodeDir = trimmedNode.isEmpty ? nil : URL(fileURLWithPath: trimmedNode).deletingLastPathComponent().path
        let customBunDir = trimmedBun.isEmpty ? nil : URL(fileURLWithPath: trimmedBun).deletingLastPathComponent().path

        if runtime == .bun {
            if let customBunDir { extraDirs.insert(customBunDir, at: 0) }
            if let customNodeDir { extraDirs.append(customNodeDir) }
        } else {
            if let customNodeDir { extraDirs.insert(customNodeDir, at: 0) }
            if let customBunDir { extraDirs.append(customBunDir) }
        }

        let searchPath = buildSearchPath(extraPaths: extraDirs)
        let nodePath: String? = (!trimmedNode.isEmpty && fm.isExecutableFile(atPath: trimmedNode))
            ? trimmedNode
            : findExecutable(named: "node", in: searchPath)
        let bunPath: String? = (!trimmedBun.isEmpty && fm.isExecutableFile(atPath: trimmedBun))
            ? trimmedBun
            : findExecutable(named: "bun", in: searchPath)

        func makeBunInvocation(scriptPath: String, source: String) -> ResolvedToolchain {
            let target = resolvedEntryScriptPath(scriptPath)
            if let bunPath {
                return ResolvedToolchain(
                    framework: framework,
                    runtime: .bun,
                    nodePath: nodePath,
                    bunPath: bunPath,
                    codeceptExecutable: bunPath,
                    prefixArguments: [target],
                    searchPath: searchPath,
                    resolutionSource: "\(source) via Bun"
                )
            }
            return ResolvedToolchain(
                framework: framework,
                runtime: .bun,
                nodePath: nodePath,
                bunPath: nil,
                codeceptExecutable: "/usr/bin/env",
                prefixArguments: ["bun", target],
                searchPath: searchPath,
                resolutionSource: "\(source) via Bun (bun not found in PATH)"
            )
        }

        if framework == .playwright {
            return resolvePlaywrightToolchain(
                workspaceRoot: workspaceRoot,
                runtime: runtime,
                trimmedNode: trimmedNode,
                trimmedPlaywright: trimmedPlaywright,
                nodePath: nodePath,
                bunPath: bunPath,
                searchPath: searchPath,
                makeBunInvocation: makeBunInvocation
            )
        }

        // 1. User-specified CodeceptJS path
        if !trimmedCodecept.isEmpty, fm.fileExists(atPath: trimmedCodecept) {
            if runtime == .bun {
                if isJavaScriptEntry(trimmedCodecept) {
                    return makeBunInvocation(scriptPath: trimmedCodecept, source: "Custom CodeceptJS")
                }
                return ResolvedToolchain(
                    runtime: .bun,
                    nodePath: nodePath,
                    bunPath: bunPath,
                    codeceptExecutable: trimmedCodecept,
                    prefixArguments: [],
                    searchPath: searchPath,
                    resolutionSource: "Custom CodeceptJS binary"
                )
            }

            if (trimmedCodecept.hasSuffix(".js") || trimmedCodecept.hasSuffix(".mjs") || trimmedCodecept.hasSuffix(".cjs")),
               let nodePath {
                return ResolvedToolchain(
                    runtime: .node,
                    nodePath: nodePath,
                    bunPath: bunPath,
                    codeceptExecutable: nodePath,
                    prefixArguments: [trimmedCodecept],
                    searchPath: searchPath,
                    resolutionSource: "Custom CodeceptJS script"
                )
            }
            return ResolvedToolchain(
                runtime: .node,
                nodePath: nodePath,
                bunPath: bunPath,
                codeceptExecutable: trimmedCodecept,
                prefixArguments: [],
                searchPath: searchPath,
                resolutionSource: "Custom CodeceptJS binary"
            )
        }

        // 2. Local project or parent monorepo ./node_modules/.bin/codeceptjs (walks up to 4 levels)
        var searchDir = workspaceRoot.standardizedFileURL
        for level in 0...4 {
            let localBin = searchDir.appendingPathComponent("node_modules/.bin/codeceptjs").path
            if fm.isExecutableFile(atPath: localBin) {
                let sourceBase = level == 0 ? "Project node_modules" : "Workspace parent node_modules"
                if runtime == .bun {
                    return makeBunInvocation(scriptPath: localBin, source: sourceBase)
                }
                // If the user explicitly pointed to a non-standard Node binary name (e.g. `node22`),
                // invoke it directly so `#!/usr/bin/env node` does not bypass their override.
                if !trimmedNode.isEmpty,
                   let nodePath,
                   URL(fileURLWithPath: nodePath).lastPathComponent != "node",
                   isJavaScriptEntry(localBin) {
                    return ResolvedToolchain(
                        runtime: .node,
                        nodePath: nodePath,
                        bunPath: bunPath,
                        codeceptExecutable: nodePath,
                        prefixArguments: [resolvedEntryScriptPath(localBin)],
                        searchPath: searchPath,
                        resolutionSource: sourceBase
                    )
                }
                return ResolvedToolchain(
                    runtime: .node,
                    nodePath: nodePath,
                    bunPath: bunPath,
                    codeceptExecutable: localBin,
                    prefixArguments: [],
                    searchPath: searchPath,
                    resolutionSource: sourceBase
                )
            }
            let parent = searchDir.deletingLastPathComponent()
            if parent.path == searchDir.path { break }
            searchDir = parent
        }

        // 3. Direct CodeceptJS repository checkout (./bin/codecept.js)
        let repoBin = workspaceRoot.appendingPathComponent("bin/codecept.js").path
        if fm.fileExists(atPath: repoBin) {
            if runtime == .bun {
                return makeBunInvocation(scriptPath: repoBin, source: "Local bin/codecept.js")
            }
            if let nodePath {
                return ResolvedToolchain(
                    runtime: .node,
                    nodePath: nodePath,
                    bunPath: bunPath,
                    codeceptExecutable: nodePath,
                    prefixArguments: [repoBin],
                    searchPath: searchPath,
                    resolutionSource: "Local bin/codecept.js"
                )
            }
        }

        // 4. Global `codeceptjs` binary
        if let globalCodecept = findExecutable(named: "codeceptjs", in: searchPath) {
            if runtime == .bun && isJavaScriptEntry(globalCodecept) {
                return makeBunInvocation(scriptPath: globalCodecept, source: "Global PATH")
            }
            return ResolvedToolchain(
                runtime: runtime,
                nodePath: nodePath,
                bunPath: bunPath,
                codeceptExecutable: globalCodecept,
                prefixArguments: [],
                searchPath: searchPath,
                resolutionSource: "Global PATH"
            )
        }

        // 5. Fallback to bun x --bun codeceptjs (Bun) or npx --no-install codeceptjs (Node)
        if runtime == .bun {
            if let bunPath {
                return ResolvedToolchain(
                    runtime: .bun,
                    nodePath: nodePath,
                    bunPath: bunPath,
                    codeceptExecutable: bunPath,
                    prefixArguments: ["x", "--bun", "codeceptjs"],
                    searchPath: searchPath,
                    resolutionSource: "bunx fallback"
                )
            }
            return ResolvedToolchain(
                runtime: .bun,
                nodePath: nodePath,
                bunPath: nil,
                codeceptExecutable: "/usr/bin/env",
                prefixArguments: ["bun", "x", "--bun", "codeceptjs"],
                searchPath: searchPath,
                resolutionSource: "bunx fallback (bun not found in PATH)"
            )
        }

        let npx = findExecutable(named: "npx", in: searchPath) ?? "/usr/bin/env"
        let prefix = npx.hasSuffix("/env") ? ["npx", "--no-install", "codeceptjs"] : ["--no-install", "codeceptjs"]
        return ResolvedToolchain(
            framework: .codeceptJS,
            runtime: .node,
            nodePath: nodePath,
            bunPath: bunPath,
            codeceptExecutable: npx,
            prefixArguments: prefix,
            searchPath: searchPath,
            resolutionSource: "npx fallback"
        )
    }

    private static func resolvePlaywrightToolchain(
        workspaceRoot: URL,
        runtime: JSRuntimeKind,
        trimmedNode: String,
        trimmedPlaywright: String,
        nodePath: String?,
        bunPath: String?,
        searchPath: String,
        makeBunInvocation: (String, String) -> ResolvedToolchain
    ) -> ResolvedToolchain {
        let fm = FileManager.default

        // 1. User-specified Playwright binary or CLI script
        if !trimmedPlaywright.isEmpty, fm.fileExists(atPath: trimmedPlaywright) {
            if runtime == .bun {
                if isJavaScriptEntry(trimmedPlaywright) {
                    return makeBunInvocation(trimmedPlaywright, "Custom Playwright")
                }
                return ResolvedToolchain(
                    framework: .playwright,
                    runtime: .bun,
                    nodePath: nodePath,
                    bunPath: bunPath,
                    codeceptExecutable: trimmedPlaywright,
                    prefixArguments: [],
                    searchPath: searchPath,
                    resolutionSource: "Custom Playwright binary"
                )
            }
            if (trimmedPlaywright.hasSuffix(".js") || trimmedPlaywright.hasSuffix(".mjs") || trimmedPlaywright.hasSuffix(".cjs")),
               let nodePath {
                return ResolvedToolchain(
                    framework: .playwright,
                    runtime: .node,
                    nodePath: nodePath,
                    bunPath: bunPath,
                    codeceptExecutable: nodePath,
                    prefixArguments: [trimmedPlaywright],
                    searchPath: searchPath,
                    resolutionSource: "Custom Playwright script"
                )
            }
            return ResolvedToolchain(
                framework: .playwright,
                runtime: .node,
                nodePath: nodePath,
                bunPath: bunPath,
                codeceptExecutable: trimmedPlaywright,
                prefixArguments: [],
                searchPath: searchPath,
                resolutionSource: "Custom Playwright binary"
            )
        }

        // 2. Local project or parent monorepo ./node_modules/.bin/playwright (walks up to 4 levels)
        var searchDir = workspaceRoot.standardizedFileURL
        for level in 0...4 {
            let localBin = searchDir.appendingPathComponent("node_modules/.bin/playwright").path
            if fm.isExecutableFile(atPath: localBin) {
                let sourceBase = level == 0 ? "Project node_modules" : "Workspace parent node_modules"
                if runtime == .bun {
                    return makeBunInvocation(localBin, sourceBase)
                }
                if !trimmedNode.isEmpty,
                   let nodePath,
                   URL(fileURLWithPath: nodePath).lastPathComponent != "node",
                   isJavaScriptEntry(localBin) {
                    return ResolvedToolchain(
                        framework: .playwright,
                        runtime: .node,
                        nodePath: nodePath,
                        bunPath: bunPath,
                        codeceptExecutable: nodePath,
                        prefixArguments: [resolvedEntryScriptPath(localBin)],
                        searchPath: searchPath,
                        resolutionSource: sourceBase
                    )
                }
                return ResolvedToolchain(
                    framework: .playwright,
                    runtime: .node,
                    nodePath: nodePath,
                    bunPath: bunPath,
                    codeceptExecutable: localBin,
                    prefixArguments: [],
                    searchPath: searchPath,
                    resolutionSource: sourceBase
                )
            }
            let parent = searchDir.deletingLastPathComponent()
            if parent.path == searchDir.path { break }
            searchDir = parent
        }

        // 3. Global `playwright` binary
        if let globalPW = findExecutable(named: "playwright", in: searchPath) {
            if runtime == .bun && isJavaScriptEntry(globalPW) {
                return makeBunInvocation(globalPW, "Global PATH")
            }
            return ResolvedToolchain(
                framework: .playwright,
                runtime: runtime,
                nodePath: nodePath,
                bunPath: bunPath,
                codeceptExecutable: globalPW,
                prefixArguments: [],
                searchPath: searchPath,
                resolutionSource: "Global PATH"
            )
        }

        // 4. Fallback to bun x playwright (Bun) or npx --no-install playwright (Node)
        if runtime == .bun {
            if let bunPath {
                return ResolvedToolchain(
                    framework: .playwright,
                    runtime: .bun,
                    nodePath: nodePath,
                    bunPath: bunPath,
                    codeceptExecutable: bunPath,
                    prefixArguments: ["x", "playwright"],
                    searchPath: searchPath,
                    resolutionSource: "bunx fallback"
                )
            }
            return ResolvedToolchain(
                framework: .playwright,
                runtime: .bun,
                nodePath: nodePath,
                bunPath: nil,
                codeceptExecutable: "/usr/bin/env",
                prefixArguments: ["bun", "x", "playwright"],
                searchPath: searchPath,
                resolutionSource: "bunx fallback (bun not found in PATH)"
            )
        }

        let npx = findExecutable(named: "npx", in: searchPath) ?? "/usr/bin/env"
        let prefix = npx.hasSuffix("/env") ? ["npx", "--no-install", "playwright"] : ["--no-install", "playwright"]
        return ResolvedToolchain(
            framework: .playwright,
            runtime: .node,
            nodePath: nodePath,
            bunPath: bunPath,
            codeceptExecutable: npx,
            prefixArguments: prefix,
            searchPath: searchPath,
            resolutionSource: "npx fallback"
        )
    }

    // MARK: - Playwright Python (pytest-playwright) Toolchain Resolution

    private static func resolvePlaywrightPythonToolchain(
        workspaceRoot: URL,
        trimmedPython: String,
        trimmedNode: String,
        trimmedBun: String
    ) -> ResolvedToolchain {
        let fm = FileManager.default
        var extraDirs: [String] = []

        if !trimmedPython.isEmpty {
            extraDirs.append(URL(fileURLWithPath: trimmedPython).deletingLastPathComponent().path)
        }

        // Collect candidate virtualenvs walking up to 4 levels
        var venvDirs: [(binDir: String, label: String)] = []
        var searchDir = workspaceRoot.standardizedFileURL
        for level in 0...4 {
            for venvName in [".venv", "venv", ".env_venv"] {
                let binDir = searchDir.appendingPathComponent("\(venvName)/bin").path
                if fm.fileExists(atPath: binDir) {
                    let label = level == 0 ? "Project \(venvName)" : "Parent \(venvName)"
                    venvDirs.append((binDir, label))
                    extraDirs.append(binDir)
                }
            }
            let parent = searchDir.deletingLastPathComponent()
            if parent.path == searchDir.path { break }
            searchDir = parent
        }

        let searchPath = buildSearchPath(extraPaths: extraDirs)
        let nodePath: String? = (!trimmedNode.isEmpty && fm.isExecutableFile(atPath: trimmedNode))
            ? trimmedNode
            : findExecutable(named: "node", in: searchPath)
        let bunPath: String? = (!trimmedBun.isEmpty && fm.isExecutableFile(atPath: trimmedBun))
            ? trimmedBun
            : findExecutable(named: "bun", in: searchPath)

        // 1. User-specified custom Python or pytest binary
        if !trimmedPython.isEmpty, fm.isExecutableFile(atPath: trimmedPython) {
            let name = URL(fileURLWithPath: trimmedPython).lastPathComponent.lowercased()
            if name.contains("pytest") {
                let dir = URL(fileURLWithPath: trimmedPython).deletingLastPathComponent().path
                let siblingPy = ["python3", "python"].map { "\(dir)/\($0)" }.first(where: { fm.isExecutableFile(atPath: $0) })
                    ?? findExecutable(named: "python3", in: searchPath)
                return ResolvedToolchain(
                    framework: .playwrightPython,
                    runtime: .node,
                    nodePath: nodePath,
                    bunPath: bunPath,
                    pythonPath: siblingPy,
                    codeceptExecutable: trimmedPython,
                    prefixArguments: [],
                    searchPath: searchPath,
                    resolutionSource: "Custom pytest binary"
                )
            }
            return ResolvedToolchain(
                framework: .playwrightPython,
                runtime: .node,
                nodePath: nodePath,
                bunPath: bunPath,
                pythonPath: trimmedPython,
                codeceptExecutable: trimmedPython,
                prefixArguments: ["-m", "pytest"],
                searchPath: searchPath,
                resolutionSource: "Custom Python interpreter"
            )
        }

        // 2. Local project / monorepo virtualenv (.venv / venv)
        for (binDir, label) in venvDirs {
            let venvPython = ["python", "python3"].map { "\(binDir)/\($0)" }.first(where: { fm.isExecutableFile(atPath: $0) })
            let venvPytest = "\(binDir)/pytest"
            if fm.isExecutableFile(atPath: venvPytest) {
                return ResolvedToolchain(
                    framework: .playwrightPython,
                    runtime: .node,
                    nodePath: nodePath,
                    bunPath: bunPath,
                    pythonPath: venvPython ?? findExecutable(named: "python3", in: searchPath),
                    codeceptExecutable: venvPytest,
                    prefixArguments: [],
                    searchPath: searchPath,
                    resolutionSource: label
                )
            }
            if let venvPython {
                return ResolvedToolchain(
                    framework: .playwrightPython,
                    runtime: .node,
                    nodePath: nodePath,
                    bunPath: bunPath,
                    pythonPath: venvPython,
                    codeceptExecutable: venvPython,
                    prefixArguments: ["-m", "pytest"],
                    searchPath: searchPath,
                    resolutionSource: "\(label) (python -m pytest)"
                )
            }
        }

        let detectedPython = findExecutable(named: "python3", in: searchPath) ?? findExecutable(named: "python", in: searchPath)

        // 3. `uv run pytest` when project uses uv (`uv.lock` or `pyproject.toml`)
        if fm.fileExists(atPath: workspaceRoot.appendingPathComponent("uv.lock").path),
           let uvBin = findExecutable(named: "uv", in: searchPath) {
            return ResolvedToolchain(
                framework: .playwrightPython,
                runtime: .node,
                nodePath: nodePath,
                bunPath: bunPath,
                pythonPath: detectedPython ?? uvBin,
                codeceptExecutable: uvBin,
                prefixArguments: ["run", "pytest"],
                searchPath: searchPath,
                resolutionSource: "uv project"
            )
        }

        // 4. `poetry run pytest` when project uses Poetry (`poetry.lock`)
        if fm.fileExists(atPath: workspaceRoot.appendingPathComponent("poetry.lock").path),
           let poetryBin = findExecutable(named: "poetry", in: searchPath) {
            return ResolvedToolchain(
                framework: .playwrightPython,
                runtime: .node,
                nodePath: nodePath,
                bunPath: bunPath,
                pythonPath: detectedPython ?? poetryBin,
                codeceptExecutable: poetryBin,
                prefixArguments: ["run", "pytest"],
                searchPath: searchPath,
                resolutionSource: "Poetry environment"
            )
        }

        // 5. Global `pytest` on PATH
        if let globalPytest = findExecutable(named: "pytest", in: searchPath) {
            return ResolvedToolchain(
                framework: .playwrightPython,
                runtime: .node,
                nodePath: nodePath,
                bunPath: bunPath,
                pythonPath: detectedPython,
                codeceptExecutable: globalPytest,
                prefixArguments: [],
                searchPath: searchPath,
                resolutionSource: "Global PATH"
            )
        }

        // 6. Fallback `python3 -m pytest`
        if let detectedPython {
            return ResolvedToolchain(
                framework: .playwrightPython,
                runtime: .node,
                nodePath: nodePath,
                bunPath: bunPath,
                pythonPath: detectedPython,
                codeceptExecutable: detectedPython,
                prefixArguments: ["-m", "pytest"],
                searchPath: searchPath,
                resolutionSource: "python3 -m pytest fallback"
            )
        }

        return ResolvedToolchain(
            framework: .playwrightPython,
            runtime: .node,
            nodePath: nodePath,
            bunPath: bunPath,
            pythonPath: nil,
            codeceptExecutable: "/usr/bin/env",
            prefixArguments: ["python3", "-m", "pytest"],
            searchPath: searchPath,
            resolutionSource: "python3 fallback (not found in PATH)"
        )
    }

    /// Resolves the `playwright` CLI binary for Python workspaces (`codegen`, `show-trace`, `install`).
    public static func resolvePlaywrightPythonCLI(
        toolchain: ResolvedToolchain
    ) -> (executable: String, prefixArguments: [String]) {
        let fm = FileManager.default
        if let pyPath = toolchain.pythonPath {
            let pyDir = URL(fileURLWithPath: pyPath).deletingLastPathComponent().path
            let siblingPW = "\(pyDir)/playwright"
            if fm.isExecutableFile(atPath: siblingPW) {
                return (siblingPW, [])
            }
            return (pyPath, ["-m", "playwright"])
        }
        if let globalPW = findExecutable(named: "playwright", in: toolchain.searchPath) {
            return (globalPW, [])
        }
        return ("/usr/bin/env", ["playwright"])
    }

    /// Resolves symlinks (e.g. `node_modules/.bin/codeceptjs` -> `node_modules/codeceptjs/bin/codecept.js`)
    /// so runtimes like Bun see the underlying `.js` entry script directly.
    private static func resolvedEntryScriptPath(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return FileManager.default.fileExists(atPath: resolved) ? resolved : path
    }

    private static func isJavaScriptEntry(_ path: String) -> Bool {
        let target = resolvedEntryScriptPath(path)
        let ext = URL(fileURLWithPath: target).pathExtension.lowercased()
        if ["js", "mjs", "cjs", "ts", "mts", "cts"].contains(ext) {
            return true
        }
        guard let handle = FileHandle(forReadingAtPath: target) else { return false }
        defer { try? handle.close() }
        let prefixData = handle.readData(ofLength: 128)
        guard let head = String(data: prefixData, encoding: .utf8),
              let firstLine = head.split(separator: "\n", maxSplits: 1).first else {
            return false
        }
        let lower = firstLine.lowercased()
        return lower.hasPrefix("#!") && (lower.contains("node") || lower.contains("bun"))
    }
}
