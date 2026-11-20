import Foundation

public enum WorkspaceScanner {
    private static let ignoredDirectories: Set<String> = [
        "node_modules", ".git", ".idea", ".vscode", "dist", "build",
        "output", "_output", "coverage", ".build", ".next", "allure-report", "allure-results"
    ]

    private static let supportedExtensions: Set<String> = [
        "js", "ts", "mjs", "cjs", "mts", "cts", "feature", "json"
    ]

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

        var discoveredConfigPaths = discoveredConfigURLs.map { $0.standardizedFileURL.path }
        if let activeConfigPath = config.configFilePath,
           !discoveredConfigPaths.contains(activeConfigPath) {
            discoveredConfigPaths.insert(activeConfigPath, at: 0)
        }
        let knownConfigPathSet = Set(discoveredConfigPaths)

        let testRoot = config.resolvedTestRootURL(workspaceRoot: standardizedRoot)
        let includeAbsolutePaths = Set(config.includes.map {
            resolveAbsolutePath($0.relativePath, base: testRoot)
        })
        let helperAbsolutePaths = Set(config.helpers.compactMap { $0.requirePath }.map {
            resolveAbsolutePath($0, base: testRoot)
        })
        let stepDefAbsolutePaths = Set(config.gherkinStepsPaths.map {
            resolveAbsolutePath($0, base: testRoot)
        })
        let resolvedOutputPath = config.resolvedOutputURL(rootURL: standardizedRoot).path

        let fm = FileManager.default
        var discovered: [WorkspaceFile] = []
        var allTags = Set<String>()

        let packageManager = PackageManagerSupport.detectPackageManager(in: standardizedRoot)
        let packageScripts = PackageManagerSupport.readPackageScripts(in: standardizedRoot)

        guard let enumerator = fm.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return CodeceptWorkspace(
                rootURL: standardizedRoot,
                config: config,
                discoveredConfigPaths: discoveredConfigPaths,
                packageManager: packageManager,
                packageScripts: packageScripts,
                files: [],
                allTags: []
            )
        }

        let rootPathWithSlash = standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path
            : standardizedRoot.path + "/"

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            let fileName = fileURL.lastPathComponent
            let fullPath = fileURL.standardizedFileURL.path

            if values?.isDirectory == true {
                if ignoredDirectories.contains(fileName) || fullPath == resolvedOutputPath {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }

            if fileName == "package-lock.json" || fileName == "tsconfig.tsbuildinfo" {
                continue
            }

            let relPath = fullPath.hasPrefix(rootPathWithSlash)
                ? String(fullPath.dropFirst(rootPathWithSlash.count))
                : fileName
            let normalizedRel = normalizeRelativePath(relPath)

            if relPath.split(separator: "/").count > 6 {
                continue
            }

            let initialCategory = classifyNonTestCategory(
                fileName: fileName,
                relativePath: normalizedRel,
                ext: ext,
                fullPath: fullPath,
                activeConfigPath: config.configFilePath,
                knownConfigPaths: knownConfigPathSet,
                includeAbsolutePaths: includeAbsolutePaths,
                helperAbsolutePaths: helperAbsolutePaths,
                stepDefAbsolutePaths: stepDefAbsolutePaths
            )

            // Keep JSON files if they are standard project manifests OR a discovered/selected CodeceptJS config
            if ext == "json"
                && !["package.json", "tsconfig.json", "jsconfig.json"].contains(fileName)
                && initialCategory != .config {
                continue
            }

            // Content-verify CodeceptJS tests: a file (even named `*.TEST.ts` or `*_spec.js`) is ONLY
            // classified as `.testSuite` / `.gherkinFeature` if its content actually declares
            // CodeceptJS `Feature(...)` / `Scenario(...)` (or Gherkin `Feature:` / `Scenario:`).
            var category = initialCategory
            var features: [ParsedFeature] = []
            let fileSize = values?.fileSize ?? 0
            let canContainTests = ext == "feature"
                || (initialCategory == .other
                    && !fileName.lowercased().hasSuffix(".d.ts")
                    && ["js", "ts", "mjs", "cjs", "mts", "cts"].contains(ext)
                    && fileSize <= 512_000)

            if canContainTests, let content = try? String(contentsOf: fileURL, encoding: .utf8) {
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

            discovered.append(WorkspaceFile(
                path: fullPath,
                relativePath: relPath,
                name: fileName,
                fileExtension: ext,
                category: category,
                features: features
            ))
        }

        // If the user selected an external custom config file outside `rootURL`, still surface it in the sidebar
        if let activeConfigPath = config.configFilePath,
           !discovered.contains(where: { $0.path == activeConfigPath }),
           fm.fileExists(atPath: activeConfigPath) {
            let extURL = URL(fileURLWithPath: activeConfigPath).standardizedFileURL
            discovered.append(WorkspaceFile(
                path: extURL.path,
                relativePath: extURL.path,
                name: extURL.lastPathComponent,
                fileExtension: extURL.pathExtension.lowercased(),
                category: .config,
                features: []
            ))
        }

        discovered.sort { lhs, rhs in
            if lhs.category != rhs.category {
                return categorySortOrder(lhs.category) < categorySortOrder(rhs.category)
            }
            // Pin active config at top of config group
            if lhs.path == config.configFilePath && rhs.path != config.configFilePath { return true }
            if rhs.path == config.configFilePath && lhs.path != config.configFilePath { return false }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }

        return CodeceptWorkspace(
            rootURL: standardizedRoot,
            config: config,
            discoveredConfigPaths: discoveredConfigPaths,
            packageManager: packageManager,
            packageScripts: packageScripts,
            files: discovered,
            allTags: allTags.sorted()
        )
    }

    private static func classifyNonTestCategory(
        fileName: String,
        relativePath: String,
        ext: String,
        fullPath: String,
        activeConfigPath: String?,
        knownConfigPaths: Set<String>,
        includeAbsolutePaths: Set<String>,
        helperAbsolutePaths: Set<String>,
        stepDefAbsolutePaths: Set<String>
    ) -> WorkspaceFileCategory {
        if fullPath == activeConfigPath
            || knownConfigPaths.contains(fullPath)
            || ConfigParser.configFileNames.contains(fileName)
            || fileName == "package.json"
            || fileName == "tsconfig.json"
            || fileName == "jsconfig.json"
            || fileName == "steps.d.ts" {
            return .config
        }
        let lowerName = fileName.lowercased()
        let lowerPath = relativePath.lowercased()

        if helperAbsolutePaths.contains(fullPath) || lowerPath.contains("helper") || lowerPath.hasPrefix("helpers/") {
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
