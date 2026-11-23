import Foundation

public enum WorkspaceScanner {
    /// Heavy VCS / dependency / build artifact directories never descended into for fast tree scanning.
    private static let ignoredDirectories: Set<String> = [
        "node_modules", ".git", ".idea", ".vscode", "dist", "build",
        "coverage", ".build", ".next", ".nuxt", ".turbo", ".cache",
        "allure-report", "allure-results", "__pycache__"
    ]

    private static let ignoredFiles: Set<String> = [
        ".DS_Store", "Thumbs.db", "tsconfig.tsbuildinfo"
    ]

    private static let codeTestExtensions: Set<String> = [
        "js", "ts", "mjs", "cjs", "mts", "cts", "jsx", "tsx", "feature"
    ]

    private static let maxTreeDepth = 12

    public static func scan(
        rootURL: URL,
        customConfigPath: String? = nil
    ) -> CodeceptWorkspace {
        let standardizedRoot = rootURL.standardizedFileURL
        let discoveredConfigURLs = ConfigParser.discoverConfigFiles(in: standardizedRoot)
        let config = ConfigParser.parseWorkspaceConfig(
            rootURL: standardizedRoot,
            explicitConfigPath: customConfigPath
        )

        var discoveredConfigURLsOrdered = discoveredConfigURLs.map(\.standardizedFileURL)
        if let activeConfigPath = config.configFilePath {
            let activeURL = URL(fileURLWithPath: activeConfigPath).standardizedFileURL
            if !discoveredConfigURLsOrdered.contains(where: { $0.path == activeURL.path }) {
                discoveredConfigURLsOrdered.insert(activeURL, at: 0)
            }
        }
        let discoveredConfigPaths = discoveredConfigURLsOrdered.map(\.path)
        let knownConfigPathSet = Set(discoveredConfigPaths)
        let discoveredConfigs = ConfigParser.parseConfigFiles(
            discoveredConfigURLsOrdered,
            rootURL: standardizedRoot,
            activeConfigPath: config.configFilePath,
            isCustomOverride: config.isCustomConfigOverride
        )

        var includeAbsolutePaths = Set<String>()
        var helperAbsolutePaths = Set<String>()
        var stepDefAbsolutePaths = Set<String>()
        var resolvedOutputPaths = Set<String>()
        let allConfigsForClassification = discoveredConfigs.isEmpty ? [config] : discoveredConfigs
        for cfg in allConfigsForClassification {
            let cfgTestRoot = cfg.resolvedTestRootURL(workspaceRoot: standardizedRoot)
            for inc in cfg.includes {
                includeAbsolutePaths.insert(resolveAbsolutePath(inc.relativePath, base: cfgTestRoot))
            }
            for helper in cfg.helpers {
                if let req = helper.requirePath {
                    helperAbsolutePaths.insert(resolveAbsolutePath(req, base: cfgTestRoot))
                }
            }
            for stepDef in cfg.gherkinStepsPaths {
                stepDefAbsolutePaths.insert(resolveAbsolutePath(stepDef, base: cfgTestRoot))
            }
            resolvedOutputPaths.insert(cfg.resolvedOutputURL(rootURL: standardizedRoot).path)
            if let htmlReportURL = cfg.resolvedHTMLReportURL(rootURL: standardizedRoot) {
                resolvedOutputPaths.insert(htmlReportURL.path)
            }
        }

        let packageManager = PackageManagerSupport.detectPackageManager(in: standardizedRoot)
        let packageScripts = PackageManagerSupport.readPackageScripts(in: standardizedRoot)

        let rootPathWithSlash = standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path
            : standardizedRoot.path + "/"

        var allFiles: [WorkspaceFile] = []
        var allTags = Set<String>()

        let context = ScanContext(
            rootPathWithSlash: rootPathWithSlash,
            activeConfigPath: config.configFilePath,
            knownConfigPaths: knownConfigPathSet,
            includeAbsolutePaths: includeAbsolutePaths,
            helperAbsolutePaths: helperAbsolutePaths,
            stepDefAbsolutePaths: stepDefAbsolutePaths,
            resolvedOutputPaths: resolvedOutputPaths
        )

        var visitedDirs = Set<String>([standardizedRoot.resolvingSymlinksInPath().path])
        var rootNodes = buildChildren(
            in: standardizedRoot,
            depth: 0,
            context: context,
            visitedDirs: &visitedDirs,
            allFiles: &allFiles,
            allTags: &allTags
        )

        // If the user selected an external custom config file outside `rootURL`, surface it cleanly
        let fm = FileManager.default
        if let activeConfigPath = config.configFilePath,
           !allFiles.contains(where: { $0.path == activeConfigPath }),
           fm.fileExists(atPath: activeConfigPath) {
            let extURL = URL(fileURLWithPath: activeConfigPath).standardizedFileURL
            let extFile = WorkspaceFile(
                path: extURL.path,
                relativePath: extURL.path,
                name: extURL.lastPathComponent,
                fileExtension: extURL.pathExtension.lowercased(),
                category: .config,
                features: []
            )
            allFiles.append(extFile)
            rootNodes.insert(WorkspaceTreeNode(
                path: extFile.path,
                relativePath: extFile.relativePath,
                name: extFile.name,
                isDirectory: false,
                isHidden: false,
                isBinary: false,
                file: extFile
            ), at: 0)
        }

        allFiles.sort { lhs, rhs in
            if lhs.category != rhs.category {
                return categorySortOrder(lhs.category) < categorySortOrder(rhs.category)
            }
            if lhs.path == config.configFilePath && rhs.path != config.configFilePath { return true }
            if rhs.path == config.configFilePath && lhs.path != config.configFilePath { return false }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }

        return CodeceptWorkspace(
            rootURL: standardizedRoot,
            config: config,
            discoveredConfigPaths: discoveredConfigPaths,
            discoveredConfigs: discoveredConfigs,
            packageManager: packageManager,
            packageScripts: packageScripts,
            files: allFiles,
            rootTree: rootNodes,
            allTags: allTags.sorted()
        )
    }

    private struct ScanContext {
        let rootPathWithSlash: String
        let activeConfigPath: String?
        let knownConfigPaths: Set<String>
        let includeAbsolutePaths: Set<String>
        let helperAbsolutePaths: Set<String>
        let stepDefAbsolutePaths: Set<String>
        let resolvedOutputPaths: Set<String>
    }

    private static func buildChildren(
        in directoryURL: URL,
        depth: Int,
        context: ScanContext,
        visitedDirs: inout Set<String>,
        allFiles: inout [WorkspaceFile],
        allTags: inout Set<String>
    ) -> [WorkspaceTreeNode] {
        guard depth <= maxTreeDepth else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else {
            return []
        }

        var folderNodes: [WorkspaceTreeNode] = []
        var fileNodes: [WorkspaceTreeNode] = []

        for entryURL in entries {
            let name = entryURL.lastPathComponent
            if ignoredFiles.contains(name) { continue }

            let values = try? entryURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            let stdURL = entryURL.standardizedFileURL
            let fullPath = stdURL.path
            let relPath = fullPath.hasPrefix(context.rootPathWithSlash)
                ? String(fullPath.dropFirst(context.rootPathWithSlash.count))
                : name
            let isHidden = name.hasPrefix(".")

            // Follow directory check safely (even for symlinks pointing to directories)
            var isDirObjC: ObjCBool = false
            let exists = fm.fileExists(atPath: fullPath, isDirectory: &isDirObjC)
            guard exists else { continue }
            let isDir = isDirObjC.boolValue

            if isDir {
                if ignoredDirectories.contains(name) {
                    continue
                }
                // Keep CodeceptJS/Playwright output directories visible in the tree as leaf folders without scanning generated artifacts as tests
                let isOutputDir = context.resolvedOutputPaths.contains(fullPath)
                    || name == "output"
                    || name == "_output"
                    || name == "test-results"
                    || name == "playwright-report"
                    || name == "blob-report"
                let realDirPath = stdURL.resolvingSymlinksInPath().path
                let children: [WorkspaceTreeNode]
                if isOutputDir {
                    children = buildShallowFileNodes(in: stdURL, context: context)
                } else if visitedDirs.insert(realDirPath).inserted {
                    children = buildChildren(
                        in: stdURL,
                        depth: depth + 1,
                        context: context,
                        visitedDirs: &visitedDirs,
                        allFiles: &allFiles,
                        allTags: &allTags
                    )
                } else {
                    children = []
                }
                let testCount = children.reduce(0) { $0 + $1.testFileCount }
                let scenarioCount = children.reduce(0) { $0 + $1.scenarioCount }
                folderNodes.append(WorkspaceTreeNode(
                    path: fullPath,
                    relativePath: relPath,
                    name: name,
                    isDirectory: true,
                    isHidden: isHidden,
                    isBinary: false,
                    file: nil,
                    children: children,
                    testFileCount: testCount,
                    scenarioCount: scenarioCount
                ))
            } else {
                let ext = stdURL.pathExtension.lowercased()
                let normalizedRel = normalizeRelativePath(relPath)
                let initialCategory = classifyNonTestCategory(
                    fileName: name,
                    relativePath: normalizedRel,
                    fullPath: fullPath,
                    activeConfigPath: context.activeConfigPath,
                    knownConfigPaths: context.knownConfigPaths,
                    includeAbsolutePaths: context.includeAbsolutePaths,
                    helperAbsolutePaths: context.helperAbsolutePaths,
                    stepDefAbsolutePaths: context.stepDefAbsolutePaths
                )

                var category = initialCategory
                var features: [ParsedFeature] = []
                let fileSize = values?.fileSize ?? 0
                let canContainTests = ext == "feature"
                    || (initialCategory == .other
                        && !name.lowercased().hasSuffix(".d.ts")
                        && codeTestExtensions.contains(ext)
                        && fileSize <= 512_000)

                if canContainTests, let content = try? String(contentsOf: stdURL, encoding: .utf8) {
                    let parsed = TestFileParser.parse(content: content, filePath: fullPath)
                    if !parsed.isEmpty {
                        features = parsed
                        category = (ext == "feature") ? .gherkinFeature : .testSuite
                        for feature in features {
                            allTags.formUnion(feature.tags)
                            for scenario in feature.scenarios {
                                allTags.formUnion(scenario.tags)
                            }
                        }
                    } else if ext == "feature" {
                        category = .other
                    }
                }

                let workspaceFile = WorkspaceFile(
                    path: fullPath,
                    relativePath: relPath,
                    name: name,
                    fileExtension: ext,
                    category: category,
                    features: features
                )
                allFiles.append(workspaceFile)

                let isExec = workspaceFile.isExecutableTestFile
                let scCount = features.reduce(0) { $0 + $1.scenarios.count }

                fileNodes.append(WorkspaceTreeNode(
                    path: fullPath,
                    relativePath: relPath,
                    name: name,
                    isDirectory: false,
                    isHidden: isHidden,
                    isBinary: workspaceFile.isBinaryFile,
                    file: workspaceFile,
                    children: [],
                    testFileCount: isExec ? 1 : 0,
                    scenarioCount: isExec ? scCount : 0
                ))
            }
        }

        folderNodes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        fileNodes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return folderNodes + fileNodes
    }

    /// Shows output/ artifact files in the tree without indexing them into code/test lists.
    private static func buildShallowFileNodes(in directoryURL: URL, context: ScanContext) -> [WorkspaceTreeNode] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries.prefix(50).compactMap { entryURL in
            let std = entryURL.standardizedFileURL
            let name = std.lastPathComponent
            if ignoredFiles.contains(name) { return nil }
            let fullPath = std.path
            let relPath = fullPath.hasPrefix(context.rootPathWithSlash)
                ? String(fullPath.dropFirst(context.rootPathWithSlash.count))
                : name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { return nil }
            if isDir.boolValue {
                return WorkspaceTreeNode(path: fullPath, relativePath: relPath, name: name, isDirectory: true, isHidden: false)
            }
            let ext = std.pathExtension.lowercased()
            let file = WorkspaceFile(path: fullPath, relativePath: relPath, name: name, fileExtension: ext, category: .other)
            return WorkspaceTreeNode(path: fullPath, relativePath: relPath, name: name, isDirectory: false, isBinary: file.isBinaryFile, file: file)
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func classifyNonTestCategory(
        fileName: String,
        relativePath: String,
        fullPath: String,
        activeConfigPath: String?,
        knownConfigPaths: Set<String>,
        includeAbsolutePaths: Set<String>,
        helperAbsolutePaths: Set<String>,
        stepDefAbsolutePaths: Set<String>
    ) -> WorkspaceFileCategory {
        if fullPath == activeConfigPath
            || knownConfigPaths.contains(fullPath)
            || ConfigParser.allStandardConfigFileNames.contains(fileName)
            || fileName == "package.json"
            || fileName == "tsconfig.json"
            || fileName == "jsconfig.json"
            || fileName == "steps.d.ts" {
            return .config
        }
        let lowerName = fileName.lowercased()
        let lowerPath = relativePath.lowercased()

        if helperAbsolutePaths.contains(fullPath)
            || lowerPath.contains("helper")
            || lowerPath.hasPrefix("helpers/")
            || lowerPath.contains("fixtures/")
            || lowerPath.hasPrefix("fixtures/") {
            return .helper
        }
        if stepDefAbsolutePaths.contains(fullPath) || lowerPath.contains("step_definitions/") || lowerPath.contains("stepdefinitions/") {
            return .stepDefinition
        }
        if includeAbsolutePaths.contains(fullPath)
            || lowerPath.contains("pages/")
            || lowerPath.contains("fragments/")
            || lowerPath.contains("stepobjects/")
            || lowerPath.contains("steps_file")
            || lowerName.contains("page.")
            || lowerName.contains("steps.") {
            return .pageObject
        }
        return .other
    }

    private static func resolveAbsolutePath(_ path: String, base: URL) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        return base.appendingPathComponent(trimmed).standardizedFileURL.path
    }

    private static func normalizeRelativePath(_ raw: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.hasPrefix("./") {
            p.removeFirst(2)
        }
        return p
    }

    private static func categorySortOrder(_ category: WorkspaceFileCategory) -> Int {
        switch category {
        case .testSuite: return 0
        case .gherkinFeature: return 1
        case .pageObject: return 2
        case .stepDefinition: return 3
        case .helper: return 4
        case .config: return 5
        case .other: return 6
        }
    }
}
