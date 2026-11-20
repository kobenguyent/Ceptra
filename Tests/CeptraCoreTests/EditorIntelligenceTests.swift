import CeptraCore
import XCTest

final class EditorIntelligenceTests: XCTestCase {
    func testIntelliSenseCompletesActorActionsCustomStepsPageObjectsTagsAndImports() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceptra-intellisense-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pages"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("stepObjects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tests"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configJS = """
        export const config = {
          name: 'intel-demo',
          tests: './tests/*_test.ts',
          output: './output',
          helpers: { Playwright: { url: 'https://example.com' }, REST: {} },
          include: {
            I: './stepObjects/custom.steps.ts',
            loginPage: './pages/LoginPage.ts',
          }
        };
        """
        try configJS.write(to: root.appendingPathComponent("codecept.conf.ts"), atomically: true, encoding: .utf8)

        let customSteps = """
        export default function () {
          return actor({
            async getUserPerPage(page: number) {
              return this.sendGetRequest('/users?page=' + page);
            }
          });
        }
        """
        try customSteps.write(to: root.appendingPathComponent("stepObjects/custom.steps.ts"), atomically: true, encoding: .utf8)

        let loginPage = """
        export default {
          async signInWithCredentials(email: string, password: string) {
            return true;
          },
          submitForm: async () => {}
        };
        """
        try loginPage.write(to: root.appendingPathComponent("pages/LoginPage.ts"), atomically: true, encoding: .utf8)

        let testCode = """
        Feature('Auth @smoke @critical');
        Scenario('logs in', async ({ I, loginPage }) => {
          I.amOnPage('/');
        });
        """
        let testURL = root.appendingPathComponent("tests/auth_test.ts")
        try testCode.write(to: testURL, atomically: true, encoding: .utf8)

        let workspace = WorkspaceScanner.scan(rootURL: root)
        let index = IntelliSenseEngine.buildWorkspaceIndex(workspace: workspace)

        // 1. Built-in + Custom `I.` completion
        let actorSrc = "I.getUser"
        let actorResult = IntelliSenseEngine.completions(
            in: actorSrc,
            cursorUTF16Offset: (actorSrc as NSString).length,
            language: "typescript",
            sourceFileURL: testURL,
            workspace: workspace,
            index: index
        )
        XCTAssertNotNil(actorResult)
        XCTAssertEqual(actorResult?.items.first?.label, "getUserPerPage")

        // Built-in `I.seeResp` completion
        let restSrc = "I.seeResp"
        let restResult = IntelliSenseEngine.completions(
            in: restSrc,
            cursorUTF16Offset: (restSrc as NSString).length,
            language: "typescript",
            sourceFileURL: testURL,
            workspace: workspace,
            index: index
        )
        XCTAssertTrue(restResult?.items.contains { $0.label == "seeResponseCodeIsSuccessful" } == true)

        // 2. Configured PageObject member completion (`loginPage.sign`)
        let pageSrc = "loginPage.sign"
        let pageResult = IntelliSenseEngine.completions(
            in: pageSrc,
            cursorUTF16Offset: (pageSrc as NSString).length,
            language: "typescript",
            sourceFileURL: testURL,
            workspace: workspace,
            index: index
        )
        XCTAssertTrue(pageResult?.items.contains { $0.label == "signInWithCredentials" } == true)

        // 3. Tag completion (`Scenario('x @crit`)
        let tagSrc = "Scenario('x @crit"
        let tagResult = IntelliSenseEngine.completions(
            in: tagSrc,
            cursorUTF16Offset: (tagSrc as NSString).length,
            language: "typescript",
            sourceFileURL: testURL,
            workspace: workspace,
            index: index
        )
        XCTAssertTrue(tagResult?.items.contains { $0.label == "@critical" } == true)

        // 4. Relative import path completion (`import x from '../pages/`)
        let importSrc = "import LoginPage from '../pages/"
        let importResult = IntelliSenseEngine.completions(
            in: importSrc,
            cursorUTF16Offset: (importSrc as NSString).length,
            language: "typescript",
            sourceFileURL: testURL,
            workspace: workspace,
            index: index
        )
        XCTAssertTrue(importResult?.items.contains { $0.label == "../pages/LoginPage.ts" } == true)
    }

    func testImportNavigatorFollowsTSImportsSymlinksSymbolsAndCodeceptIncludes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ceptra-nav-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("fixtures"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("pages"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("tests"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("shared-target"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // TypeScript fixture file imported using `.js` ESM specifier
        let constantsURL = root.appendingPathComponent("fixtures/constants.ts")
        let constantsSource = """
        // Constants
        export const timeoutMs = 5000;
        export const defaultHeaders = { 'Accept': 'application/json' };
        """
        try constantsSource.write(to: constantsURL, atomically: true, encoding: .utf8)

        // Real filesystem symlink imported from tests/
        let realHelperURL = root.appendingPathComponent("shared-target/realHelper.ts")
        try "export function runHelper() { return 42; }\n".write(to: realHelperURL, atomically: true, encoding: .utf8)
        let symlinkURL = root.appendingPathComponent("pages/linkedHelper.ts")
        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: realHelperURL)

        let configURL = root.appendingPathComponent("codecept.conf.ts")
        try """
        export const config = {
          name: 'nav-demo',
          tests: './tests/*_test.ts',
          helpers: { REST: {} },
          include: {
            linkedHelper: './pages/linkedHelper.ts'
          }
        };
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let testURL = root.appendingPathComponent("tests/api_test.ts")
        let testSource = """
        import { defaultHeaders } from '../fixtures/constants.js';
        import { runHelper } from '../pages/linkedHelper';

        Feature('API');
        Scenario('uses imports', async ({ I, linkedHelper }) => {
          I.haveRequestHeaders(defaultHeaders);
          linkedHelper.runHelper();
        });
        """
        try testSource.write(to: testURL, atomically: true, encoding: .utf8)

        let workspace = WorkspaceScanner.scan(rootURL: root)

        // 1. Navigate directly from `.js` ESM import specifier -> resolves actual `.ts` file on disk
        let importOffset = (testSource as NSString).range(of: "../fixtures/constants.js").location + 4
        let importHit = ImportNavigator.resolveTarget(
            atUTF16Offset: importOffset,
            in: testSource,
            sourceFileURL: testURL,
            workspaceRoot: root,
            config: workspace.config
        )
        XCTAssertEqual(importHit?.target.fileURL.standardizedFileURL.path, constantsURL.standardizedFileURL.path)

        // 2. Navigate from imported identifier usage `defaultHeaders` -> resolves exact declaration line 3
        let usageOffset = (testSource as NSString).range(of: "defaultHeaders", options: .backwards).location + 2
        let symbolHit = ImportNavigator.resolveTarget(
            atUTF16Offset: usageOffset,
            in: testSource,
            sourceFileURL: testURL,
            workspaceRoot: root,
            config: workspace.config
        )
        XCTAssertEqual(symbolHit?.target.fileURL.standardizedFileURL.path, constantsURL.standardizedFileURL.path)
        XCTAssertEqual(symbolHit?.target.lineNumber, 3)

        // 3. Navigate across symlinked import -> resolves symlink target & flags isSymlink == true
        let symOffset = (testSource as NSString).range(of: "../pages/linkedHelper").location + 5
        let symHit = ImportNavigator.resolveTarget(
            atUTF16Offset: symOffset,
            in: testSource,
            sourceFileURL: testURL,
            workspaceRoot: root,
            config: workspace.config
        )
        XCTAssertEqual(symHit?.target.fileURL.resolvingSymlinksInPath().path, realHelperURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(symHit?.target.isSymlink, true)

        // 4. Navigate from CodeceptJS `include` member `linkedHelper.runHelper` -> resolves method line 1
        let memberOffset = (testSource as NSString).range(of: "runHelper", options: .backwards).location + 2
        let memberHit = ImportNavigator.resolveTarget(
            atUTF16Offset: memberOffset,
            in: testSource,
            sourceFileURL: testURL,
            workspaceRoot: root,
            config: workspace.config
        )
        XCTAssertEqual(memberHit?.target.fileURL.resolvingSymlinksInPath().path, realHelperURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(memberHit?.target.lineNumber, 1)
    }

    func testExecutableTestFileFlagOnlyMatchesTestAndFeatureFiles() {
        let testFile = WorkspaceFile(path: "/a/login_test.ts", relativePath: "login_test.ts", name: "login_test.ts", fileExtension: "ts", category: .testSuite)
        let featureFile = WorkspaceFile(path: "/a/login.feature", relativePath: "login.feature", name: "login.feature", fileExtension: "feature", category: .gherkinFeature)
        let pageFile = WorkspaceFile(path: "/a/LoginPage.ts", relativePath: "LoginPage.ts", name: "LoginPage.ts", fileExtension: "ts", category: .pageObject)
        let configFile = WorkspaceFile(path: "/a/codecept.conf.ts", relativePath: "codecept.conf.ts", name: "codecept.conf.ts", fileExtension: "ts", category: .config)
        let helperFile = WorkspaceFile(path: "/a/custom_helper.ts", relativePath: "custom_helper.ts", name: "custom_helper.ts", fileExtension: "ts", category: .helper)
        let otherFile = WorkspaceFile(path: "/a/constants.ts", relativePath: "constants.ts", name: "constants.ts", fileExtension: "ts", category: .other)

        XCTAssertTrue(testFile.isExecutableTestFile)
        XCTAssertTrue(featureFile.isExecutableTestFile)
        XCTAssertFalse(pageFile.isExecutableTestFile)
        XCTAssertFalse(configFile.isExecutableTestFile)
        XCTAssertFalse(helperFile.isExecutableTestFile)
        XCTAssertFalse(otherFile.isExecutableTestFile)
    }
}
