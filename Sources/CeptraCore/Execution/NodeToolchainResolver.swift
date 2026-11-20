import Foundation

public struct ResolvedToolchain: Equatable, Sendable {
    public let nodePath: String?
    public let codeceptExecutable: String
    public let prefixArguments: [String]
    public let searchPath: String
    public let resolutionSource: String

    public init(
        nodePath: String?,
        codeceptExecutable: String,
        prefixArguments: [String],
        searchPath: String,
        resolutionSource: String
    ) {
        self.nodePath = nodePath
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
            "\(home)/.volta/bin",
            "\(home)/.fnm/current/bin",
            "\(home)/.asdf/shims",
            "\(home)/.bun/bin"
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
        customNodePath: String = "",
        customCodeceptPath: String = ""
    ) -> ResolvedToolchain {
        let fm = FileManager.default
        let trimmedNode = customNodePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCodecept = customCodeceptPath.trimmingCharacters(in: .whitespacesAndNewlines)

        var extraDirs: [String] = [
            workspaceRoot.appendingPathComponent("node_modules/.bin").path
        ]
        if !trimmedNode.isEmpty {
            extraDirs.insert(URL(fileURLWithPath: trimmedNode).deletingLastPathComponent().path, at: 0)
        }

        let searchPath = buildSearchPath(extraPaths: extraDirs)
        let nodePath: String? = (!trimmedNode.isEmpty && fm.isExecutableFile(atPath: trimmedNode))
            ? trimmedNode
            : findExecutable(named: "node", in: searchPath)

        // 1. User-specified CodeceptJS path
        if !trimmedCodecept.isEmpty, fm.fileExists(atPath: trimmedCodecept) {
            if trimmedCodecept.hasSuffix(".js") || trimmedCodecept.hasSuffix(".mjs"), let nodePath {
                return ResolvedToolchain(
                    nodePath: nodePath,
                    codeceptExecutable: nodePath,
                    prefixArguments: [trimmedCodecept],
                    searchPath: searchPath,
                    resolutionSource: "Custom CodeceptJS script"
                )
            }
            return ResolvedToolchain(
                nodePath: nodePath,
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
                return ResolvedToolchain(
                    nodePath: nodePath,
                    codeceptExecutable: localBin,
                    prefixArguments: [],
                    searchPath: searchPath,
                    resolutionSource: level == 0 ? "Project node_modules" : "Workspace parent node_modules"
                )
            }
            let parent = searchDir.deletingLastPathComponent()
            if parent.path == searchDir.path { break }
            searchDir = parent
        }

        // 3. Direct CodeceptJS repository checkout (./bin/codecept.js)
        let repoBin = workspaceRoot.appendingPathComponent("bin/codecept.js").path
        if fm.fileExists(atPath: repoBin), let nodePath {
            return ResolvedToolchain(
                nodePath: nodePath,
                codeceptExecutable: nodePath,
                prefixArguments: [repoBin],
                searchPath: searchPath,
                resolutionSource: "Local bin/codecept.js"
            )
        }

        // 4. Global `codeceptjs` binary
        if let globalCodecept = findExecutable(named: "codeceptjs", in: searchPath) {
            return ResolvedToolchain(
                nodePath: nodePath,
                codeceptExecutable: globalCodecept,
                prefixArguments: [],
                searchPath: searchPath,
                resolutionSource: "Global PATH"
            )
        }

        // 5. Fallback to npx codeceptjs
        let npx = findExecutable(named: "npx", in: searchPath) ?? "/usr/bin/env"
        let prefix = npx.hasSuffix("/env") ? ["npx", "--no-install", "codeceptjs"] : ["--no-install", "codeceptjs"]
        return ResolvedToolchain(
            nodePath: nodePath,
            codeceptExecutable: npx,
            prefixArguments: prefix,
            searchPath: searchPath,
            resolutionSource: "npx fallback"
        )
    }
}
