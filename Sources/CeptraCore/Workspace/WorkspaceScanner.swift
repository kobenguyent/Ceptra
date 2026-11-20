import Foundation

public enum WorkspaceScanner {
    private static let ignoredDirectories: Set<String> = [
        "node_modules", ".git", ".idea", ".vscode", "dist", "build",
        "output", "_output", "coverage", ".build", ".next", "allure-report", "allure-results"
    ]

    private static let supportedExtensions: Set<String> = [
        "js", "ts", "mjs", "cjs", "mts", "cts", "feature", "json"
    ]

    public static func scan(rootURL: URL) -> CodeceptWorkspace {
        let standardizedRoot = rootURL.standardizedFileURL
        let config = ConfigParser.parseWorkspaceConfig(rootURL: standardizedRoot)
        let includePaths = Set(config.includes.map { normalizeRelativePath($0.relativePath) })
        let helperRequirePaths = Set(config.helpers.compactMap { $0.requirePath }.map { normalizeRelativePath($0) })
        let stepDefPaths = Set(config.gherkinStepsPaths.map { normalizeRelativePath($0) })
        let outputDirName = URL(fileURLWithPath: config.outputDirectory).lastPathComponent

        var ignored = ignoredDirectories
        if !outputDirName.isEmpty && outputDirName != "." {
            ignored.insert(outputDirName)
        }

        let fm = FileManager.default
        var discovered: [WorkspaceFile] = []
        var allTags = Set<String>()

        guard let enumerator = fm.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return CodeceptWorkspace(rootURL: standardizedRoot, config: config, files: [], allTags: [])
        }

        let rootPathWithSlash = standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path
            : standardizedRoot.path + "/"

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let fileName = fileURL.lastPathComponent

            if values?.isDirectory == true {
                if ignored.contains(fileName) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }

            // Skip noisy lockfiles
            if fileName == "package-lock.json" || fileName == "tsconfig.tsbuildinfo" {
                continue
            }

            let fullPath = fileURL.standardizedFileURL.path
            let relPath = fullPath.hasPrefix(rootPathWithSlash)
                ? String(fullPath.dropFirst(rootPathWithSlash.count))
                : fileName
            let normalizedRel = normalizeRelativePath(relPath)

            // Skip deeply nested files beyond depth 6 for fast minimalist UX
            if relPath.split(separator: "/").count > 6 {
                continue
            }

            let category = classify(
                fileName: fileName,
                relativePath: normalizedRel,
                ext: ext,
                configPath: config.configFilePath,
                fullPath: fullPath,
                includePaths: includePaths,
                helperPaths: helperRequirePaths,
                stepDefPaths: stepDefPaths
            )

            // Keep JSON only for package.json / jsconfig.json / tsconfig.json
            if ext == "json" && !["package.json", "tsconfig.json", "jsconfig.json"].contains(fileName) {
                continue
            }

            var features: [ParsedFeature] = []
            if category == .testSuite || category == .gherkinFeature {
                if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    features = TestFileParser.parse(content: content, filePath: fullPath)
                    for feature in features {
                        allTags.formUnion(feature.tags)
                        for scenario in feature.scenarios {
                            allTags.formUnion(scenario.tags)
                        }
                    }
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

        discovered.sort { lhs, rhs in
            if lhs.category != rhs.category {
                return categorySortOrder(lhs.category) < categorySortOrder(rhs.category)
            }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }

        return CodeceptWorkspace(
            rootURL: standardizedRoot,
            config: config,
            files: discovered,
            allTags: allTags.sorted()
        )
    }

    private static func classify(
        fileName: String,
        relativePath: String,
        ext: String,
        configPath: String?,
        fullPath: String,
        includePaths: Set<String>,
        helperPaths: Set<String>,
        stepDefPaths: Set<String>
    ) -> WorkspaceFileCategory {
        if fullPath == configPath || ConfigParser.configFileNames.contains(fileName) || fileName == "package.json" || fileName == "tsconfig.json" || fileName == "jsconfig.json" || fileName == "steps.d.ts" {
            return .config
        }
        if ext == "feature" {
            return .gherkinFeature
        }
        let lowerName = fileName.lowercased()
        let lowerPath = relativePath.lowercased()

        if lowerName.contains("_test.") || lowerName.contains(".test.") || lowerName.contains("_spec.") || lowerName.contains(".spec.") {
            return .testSuite
        }
        if helperPaths.contains(relativePath) || lowerPath.contains("helper") || lowerPath.hasPrefix("helpers/") {
            return .helper
        }
        if stepDefPaths.contains(relativePath) || lowerPath.contains("step_definitions/") || lowerPath.contains("stepdefinitions/") {
            return .stepDefinition
        }
        if includePaths.contains(relativePath)
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
