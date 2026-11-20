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
}
