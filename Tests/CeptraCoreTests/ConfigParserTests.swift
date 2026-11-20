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
}
