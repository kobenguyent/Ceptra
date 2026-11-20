import CeptraCore
import XCTest

final class ConfigParserTests: XCTestCase {
    func testParsesTypeScriptAndESMCodecept4Workspace() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceptra-config-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try ProjectScaffolder.createSampleWorkspace(at: tempRoot)

        let workspace = WorkspaceScanner.scan(rootURL: tempRoot)
        XCTAssertEqual(workspace.config.projectName, tempRoot.lastPathComponent)
        XCTAssertTrue(workspace.config.isESM)
        XCTAssertEqual(workspace.config.packageCodeceptVersion, "^4.0.0")
        XCTAssertEqual(workspace.config.outputDirectory, "./output")

        let helperNames = Set(workspace.config.helpers.map(\.name))
        XCTAssertTrue(helperNames.contains("Playwright"))
        XCTAssertTrue(helperNames.contains("REST"))
        XCTAssertTrue(helperNames.contains("JSONResponse"))

        let pluginMap = Dictionary(uniqueKeysWithValues: workspace.config.plugins.map { ($0.name, $0.enabled) })
        XCTAssertEqual(pluginMap["screenshot"], true)
        XCTAssertEqual(pluginMap["junitReporter"], true)
        XCTAssertEqual(pluginMap["aiTrace"], false)

        XCTAssertEqual(workspace.config.includes.first?.alias, "homePage")
        XCTAssertEqual(workspace.testFiles.count, 2) // starter_test.js + starter.feature
        XCTAssertEqual(workspace.supportFiles.count, 1) // HomePage.js
        XCTAssertTrue(workspace.allTags.contains("@smoke"))
        XCTAssertTrue(workspace.allTags.contains("@api"))
    }

    func testParsesTypeScriptTypedConfigAndNestedHelpers() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceptra-ts-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let tsConfig = """
        export const config: CodeceptJS.MainConfig = {
          tests: './*/*_test.ts',
          output: './output',
          name: 'api-ts-suite',
          helpers: {
            REST: {
              endpoint: 'http://localhost:3000/api/',
              timeout: 30_000,
            },
            CustomHelper: {
              require: './helpers/custom.ts',
            },
          },
          include: {
            I: './stepObjects/custom.steps.ts',
          },
          plugins: {
            junitReporter: {
              enabled: true,
            },
          },
        };
        """
        try tsConfig.write(to: tempRoot.appendingPathComponent("codecept.conf.ts"), atomically: true, encoding: .utf8)

        let testFile = """
        Feature('GET tests');

        Scenario('Verify a successful call', async ({ I }) => {
          await I.sendGetRequest('/users');
          I.seeResponseCodeIsSuccessful();
        });
        """
        try testFile.write(to: tempRoot.appendingPathComponent("src/GET_test.ts"), atomically: true, encoding: .utf8)

        let ws = WorkspaceScanner.scan(rootURL: tempRoot)
        XCTAssertTrue(ws.config.isTypeScript)
        XCTAssertEqual(ws.config.projectName, "api-ts-suite")
        XCTAssertEqual(ws.config.helpers.count, 2)
        XCTAssertEqual(ws.config.includes.first?.alias, "I")
        XCTAssertEqual(ws.totalScenarioCount, 1)
    }

    func testDiscoversCustomConfigNamesNestedPathsPackageScriptsAndJSON() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceptra-custom-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("e2e/configs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("e2e/pages"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Non-codecept config that must be ignored
        try "export default { rules: {} };".write(
            to: tempRoot.appendingPathComponent("eslint.config.mjs"),
            atomically: true,
            encoding: .utf8
        )

        // package.json pointing -c to a completely custom filename & JSON config
        let pkg = """
        {
          "name": "custom-config-monorepo",
          "scripts": {
            "test:staging": "codeceptjs run -c e2e/configs/staging-runner.json"
          },
          "devDependencies": {
            "codeceptjs": "^4.0.3"
          }
        }
        """
        try pkg.write(to: tempRoot.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let jsonConfig = """
        {
          "name": "staging-json-suite",
          "tests": "../tests/*_test.js",
          "output": "../artifacts",
          "helpers": {
            "REST": { "endpoint": "https://staging.example.com" }
          },
          "include": {
            "loginPage": "../pages/Login.js"
          },
          "plugins": {
            "junitReporter": { "enabled": true }
          }
        }
        """
        let jsonConfigURL = tempRoot.appendingPathComponent("e2e/configs/staging-runner.json")
        try jsonConfig.write(to: jsonConfigURL, atomically: true, encoding: .utf8)

        let altConfig = """
        export const config = {
          name: 'mobile-custom-suite',
          tests: '../tests/*_test.ts',
          output: '../mobile-output',
          helpers: {
            Playwright: { browser: 'webkit', url: 'https://m.example.com' }
          }
        };
        """
        let altConfigURL = tempRoot.appendingPathComponent("e2e/configs/mobile.conf.ts")
        try altConfig.write(to: altConfigURL, atomically: true, encoding: .utf8)
        try "export default {};".write(to: tempRoot.appendingPathComponent("e2e/pages/Login.js"), atomically: true, encoding: .utf8)

        // 1. Auto-discovery should find both staging-runner.json (via package.json -c) and mobile.conf.ts (via heuristic), ignoring eslint.config.mjs
        let discovered = ConfigParser.discoverConfigFiles(in: tempRoot)
        let discoveredNames = discovered.map(\.lastPathComponent)
        XCTAssertTrue(discoveredNames.contains("staging-runner.json"))
        XCTAssertTrue(discoveredNames.contains("mobile.conf.ts"))
        XCTAssertFalse(discoveredNames.contains("eslint.config.mjs"))

        // Primary auto-detected config is staging-runner.json (referenced via package.json -c)
        let autoWorkspace = WorkspaceScanner.scan(rootURL: tempRoot)
        XCTAssertEqual(autoWorkspace.config.projectName, "staging-json-suite")
        XCTAssertEqual(autoWorkspace.config.configFilePath, jsonConfigURL.standardizedFileURL.path)
        XCTAssertFalse(autoWorkspace.config.isCustomConfigOverride)
        // Output directory resolves relative to dirname(configFile) = e2e/configs/../artifacts -> e2e/artifacts
        XCTAssertEqual(
            autoWorkspace.config.resolvedOutputURL(rootURL: tempRoot).path,
            tempRoot.appendingPathComponent("e2e/artifacts").standardizedFileURL.path
        )
        // Page object include resolved relative to config directory
        XCTAssertEqual(autoWorkspace.supportFiles.first?.name, "Login.js")

        // 2. Explicit relative custom config override switches active config cleanly
        let overrideWorkspace = WorkspaceScanner.scan(rootURL: tempRoot, customConfigPath: "e2e/configs/mobile.conf.ts")
        XCTAssertTrue(overrideWorkspace.config.isCustomConfigOverride)
        XCTAssertEqual(overrideWorkspace.config.projectName, "mobile-custom-suite")
        XCTAssertEqual(overrideWorkspace.config.helpers.first?.name, "Playwright")
        XCTAssertEqual(
            overrideWorkspace.config.resolvedOutputURL(rootURL: tempRoot).path,
            tempRoot.appendingPathComponent("e2e/mobile-output").standardizedFileURL.path
        )

        // 3. Explicit external absolute config outside workspace root still works & surfaces in sidebar
        let externalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceptra-ext-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalDir) }

        let externalConfigURL = externalDir.appendingPathComponent("shared-ci.js")
        try "exports.config = { name: 'external-ci', output: './ci-out', helpers: { REST: {} } };"
            .write(to: externalConfigURL, atomically: true, encoding: .utf8)

        let extWorkspace = WorkspaceScanner.scan(rootURL: tempRoot, customConfigPath: externalConfigURL.path)
        XCTAssertTrue(extWorkspace.config.isCustomConfigOverride)
        XCTAssertEqual(extWorkspace.config.projectName, "external-ci")
        XCTAssertEqual(extWorkspace.config.configFilePath, externalConfigURL.standardizedFileURL.path)
        XCTAssertTrue(extWorkspace.files.contains { $0.path == externalConfigURL.standardizedFileURL.path && $0.category == .config })
    }

    func testBuildsFullHierarchicalProjectTreeWithNestedFoldersDotfilesAndFiltering() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ceptra-tree-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("src/e2e/auth"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("src/fixtures"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".github/workflows"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/fake-pkg"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try "name: CI\n".write(to: root.appendingPathComponent(".github/workflows/ci.yml"), atomically: true, encoding: .utf8)
        try #"{"email":"dev@example.com"}"#.write(to: root.appendingPathComponent("src/fixtures/user.json"), atomically: true, encoding: .utf8)
        try "# Readme\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "export const x = 1;".write(to: root.appendingPathComponent("node_modules/fake-pkg/index.js"), atomically: true, encoding: .utf8)

        let authTest = """
        Feature('Auth @smoke');
        Scenario('signs in', ({ I }) => {
          I.amOnPage('/login');
        });
        """
        let authTestURL = root.appendingPathComponent("src/e2e/auth/login_test.ts")
        try authTest.write(to: authTestURL, atomically: true, encoding: .utf8)

        let ws = WorkspaceScanner.scan(rootURL: root)

        // node_modules excluded, real folders + dotfiles + json fixtures + markdown included
        let topNames = ws.rootTree.map(\.name)
        XCTAssertFalse(topNames.contains("node_modules"))
        XCTAssertTrue(topNames.contains(".github"))
        XCTAssertTrue(topNames.contains("src"))
        XCTAssertTrue(topNames.contains("README.md"))

        // Folders come before files at root level
        let srcIdx = topNames.firstIndex(of: "src")!
        let readmeIdx = topNames.firstIndex(of: "README.md")!
        XCTAssertLessThan(srcIdx, readmeIdx)

        // Nested recursive test counts aggregate upward to `src`
        let srcNode = try XCTUnwrap(ws.rootTree.first { $0.name == "src" })
        XCTAssertEqual(srcNode.testFileCount, 1)
        XCTAssertEqual(srcNode.scenarioCount, 1)

        // Ancestor path lookup reveals nested file cleanly
        let ancestors = srcNode.ancestorDirectoryPaths(containing: authTestURL.standardizedFileURL.path)
        XCTAssertEqual(ancestors?.count, 3) // src -> src/e2e -> src/e2e/auth

        // Tag filtering prunes non-matching branches (fixtures/user.json dropped, auth/login_test.ts kept)
        let filtered = srcNode.filtered(query: "", tag: "@smoke")
        XCTAssertEqual(filtered?.children.map(\.name), ["e2e"])
        XCTAssertEqual(filtered?.testFileCount, 1)
    }

    func testParsesMultipleSuitesFromJSAndJSONConfigs() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ceptra-multiple-cfg-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let jsConfig = """
        export const config = {
          name: 'multi-suite-app',
          tests: './tests/*_test.ts',
          helpers: {
            Playwright: { browser: 'chromium', url: 'https://example.com' }
          },
          multiple: {
            basic: {
              browsers: ['chromium', 'firefox'],
            },
            smoke: {
              grep: '@smoke',
              chunks: 2,
              browsers: [
                'chromium',
                { browser: 'webkit', windowSize: 'maximize' },
              ],
            },
          },
        };
        """
        try jsConfig.write(to: root.appendingPathComponent("codecept.conf.ts"), atomically: true, encoding: .utf8)

        let jsSummary = ConfigParser.parseWorkspaceConfig(rootURL: root)
        XCTAssertEqual(jsSummary.multipleSuites.count, 2)
        let basic = try XCTUnwrap(jsSummary.multipleSuites.first { $0.name == "basic" })
        XCTAssertEqual(basic.browsers, ["chromium", "firefox"])
        XCTAssertEqual(basic.browserTargets, ["basic:chromium", "basic:firefox"])
        XCTAssertNil(basic.chunks)

        let smoke = try XCTUnwrap(jsSummary.multipleSuites.first { $0.name == "smoke" })
        XCTAssertEqual(smoke.grep, "@smoke")
        XCTAssertEqual(smoke.chunks, 2)
        XCTAssertEqual(smoke.browsers, ["chromium", "webkit"])

        // JSON config multiple parsing
        let jsonConfig = """
        {
          "name": "json-multi",
          "helpers": { "Playwright": { "browser": "chromium" } },
          "multiple": {
            "regression": {
              "grep": "@regression",
              "chunks": 4,
              "browsers": ["chromium", { "browser": "firefox", "show": false }]
            }
          }
        }
        """
        let jsonURL = root.appendingPathComponent("custom.json")
        try jsonConfig.write(to: jsonURL, atomically: true, encoding: .utf8)

        let jsonSummary = ConfigParser.parseWorkspaceConfig(rootURL: root, explicitConfigPath: "custom.json")
        XCTAssertEqual(jsonSummary.multipleSuites.count, 1)
        XCTAssertEqual(jsonSummary.multipleSuites[0].name, "regression")
        XCTAssertEqual(jsonSummary.multipleSuites[0].grep, "@regression")
        XCTAssertEqual(jsonSummary.multipleSuites[0].chunks, 4)
        XCTAssertEqual(jsonSummary.multipleSuites[0].browsers, ["chromium", "firefox"])
    }

    func testCreatesNewFoldersAndFilesAtAnyProjectLevelWithValidation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ceptra-create-any-level-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 1. Folder at workspace root & nested multi-segment folder
        let rootFolder = try ProjectScaffolder.createFolder(workspaceRoot: root, relativeDirectory: "", folderName: "fixtures")
        XCTAssertEqual(rootFolder.relativePath, "fixtures")
        XCTAssertTrue(fm.fileExists(atPath: rootFolder.url.path))

        let nestedFolder = try ProjectScaffolder.createFolder(workspaceRoot: root, relativeDirectory: "fixtures", folderName: "auth/mocks")
        XCTAssertEqual(nestedFolder.relativePath, "fixtures/auth/mocks")
        XCTAssertTrue(fm.fileExists(atPath: nestedFolder.url.path))

        // 2. Blank / custom files at root, nested directory, and via subpath in filename
        let envFile = try ProjectScaffolder.createFile(workspaceRoot: root, relativeDirectory: "", name: ".env", kind: .blankFile)
        XCTAssertEqual(envFile.relativePath, ".env")
        XCTAssertTrue(fm.fileExists(atPath: envFile.url.path))

        let nestedJSON = try ProjectScaffolder.createFile(
            workspaceRoot: root,
            relativeDirectory: "fixtures/auth/mocks",
            name: "users.json",
            kind: .blankFile
        )
        XCTAssertEqual(nestedJSON.relativePath, "fixtures/auth/mocks/users.json")

        let templateNested = try ProjectScaffolder.createFile(
            workspaceRoot: root,
            relativeDirectory: "src/e2e",
            name: "checkout/Payment",
            kind: .tsTest
        )
        XCTAssertEqual(templateNested.relativePath, "src/e2e/checkout/payment_test.ts")
        let createdBody = try String(contentsOf: templateNested.url, encoding: .utf8)
        XCTAssertTrue(createdBody.contains("Feature('Payment')"))

        // 3. Rejects duplicates and path traversal escaping workspace
        XCTAssertThrowsError(
            try ProjectScaffolder.createFile(workspaceRoot: root, relativeDirectory: "", name: ".env", kind: .blankFile)
        ) { error in
            XCTAssertEqual(error as? WorkspaceFileOperationError, .alreadyExists(".env"))
        }

        XCTAssertThrowsError(
            try ProjectScaffolder.createFolder(workspaceRoot: root, relativeDirectory: "", folderName: "../outside")
        ) { error in
            XCTAssertEqual(error as? WorkspaceFileOperationError, .invalidPath("Path segments cannot contain '.' or '..'."))
        }

        // 4. WorkspaceScanner reflects every new folder & file in rootTree and ancestorDirectoryPaths finds folder nodes
        let ws = WorkspaceScanner.scan(rootURL: root)
        let fixturesNode = try XCTUnwrap(ws.rootTree.first { $0.name == "fixtures" })
        let folderAncestors = fixturesNode.ancestorDirectoryPaths(containing: nestedFolder.url.path)
        XCTAssertEqual(folderAncestors?.count, 3) // fixtures -> fixtures/auth -> fixtures/auth/mocks
        XCTAssertEqual(ws.testFiles.count, 1)
    }
}
