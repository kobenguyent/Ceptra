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

    func testPyCharmStyleRootMethodNavigationAcrossBarrelsInheritanceLocalsGherkinAndUsages() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ceptra-pycharm-nav-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("pages"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("helpers"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("steps"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("step_definitions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("features"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("tests"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 1. BasePage.ts with comments & internal call site BEFORE actual method declaration
        let basePageURL = root.appendingPathComponent("pages/BasePage.ts")
        let basePageSource = """
        // BasePage comment mentioning waitForToast('ok') and formatCurrency(10)
        /* Another comment: waitForToast('banner') */
        export class BasePage {
          async openBase() {
            await this.waitForToast('ready');
          }

          async waitForToast(expectedText: string) {
            return expectedText;
          }
        }
        """
        try basePageSource.write(to: basePageURL, atomically: true, encoding: .utf8)

        // 2. CheckoutPage.ts extending BasePage + calling this.calculateTotal()
        let checkoutPageURL = root.appendingPathComponent("pages/CheckoutPage.ts")
        let checkoutPageSource = """
        import { BasePage } from './BasePage';

        export class CheckoutPage extends BasePage {
          async submitOrder(promoCode: string) {
            const total = this.calculateTotal(100);
            return total;
          }

          calculateTotal(subtotal: number) {
            return subtotal * 0.8;
          }
        }
        export default new CheckoutPage();
        """
        try checkoutPageSource.write(to: checkoutPageURL, atomically: true, encoding: .utf8)

        // 3. Barrel file pages/index.ts re-exporting CheckoutPage and default instance
        let barrelURL = root.appendingPathComponent("pages/index.ts")
        let barrelSource = """
        export { CheckoutPage, default as checkoutPage } from './CheckoutPage';
        export * from './BasePage';
        """
        try barrelSource.write(to: barrelURL, atomically: true, encoding: .utf8)

        // 4. steps.d.ts type stub AND real implementations in steps_file.ts + ApiHelper.ts
        let stepsDtsURL = root.appendingPathComponent("steps.d.ts")
        try """
        declare namespace CodeceptJS {
          interface SupportObject { I: I; }
          interface Methods {
            loginWithSso(email: string): void;
            seedOrderViaRest(orderId: string): Promise<void>;
          }
          interface I extends WithTranslation<Methods> {}
        }
        """.write(to: stepsDtsURL, atomically: true, encoding: .utf8)

        let stepsFileURL = root.appendingPathComponent("steps/steps_file.ts")
        try """
        // Custom actor steps
        export = function() {
          return actor({
            // loginWithSso('comment') should not match
            loginWithSso: async function(email: string) {
              this.amOnPage('/sso');
            }
          });
        };
        """.write(to: stepsFileURL, atomically: true, encoding: .utf8)

        let apiHelperURL = root.appendingPathComponent("helpers/ApiHelper.ts")
        try """
        import Helper from '@codeceptjs/helper';
        class ApiHelper extends Helper {
          async seedOrderViaRest(orderId: string) {
            return orderId;
          }
        }
        export = ApiHelper;
        """.write(to: apiHelperURL, atomically: true, encoding: .utf8)

        // 5. Gherkin step definition file
        let bddStepsURL = root.appendingPathComponent("step_definitions/checkout.steps.ts")
        try """
        const { I } = inject();

        Given('I have an active cart with {int} items', (count: number) => {
          I.amOnPage('/cart');
        });

        When('I apply expired promo code {string}', async (code: string) => {
          I.fillField('Promo', code);
        });
        """.write(to: bddStepsURL, atomically: true, encoding: .utf8)

        let featureURL = root.appendingPathComponent("features/promo.feature")
        let featureSource = """
        Feature: Promo Codes
          Scenario: Expired code
            Given I have an active cart with 3 items
            When I apply expired promo code "EXPIRED99"
        """
        try featureSource.write(to: featureURL, atomically: true, encoding: .utf8)

        // 6. Config
        let configURL = root.appendingPathComponent("codecept.conf.ts")
        try """
        export const config = {
          name: 'pycharm-nav',
          tests: './tests/*_test.ts',
          helpers: {
            Playwright: { url: 'https://shop.local' },
            ApiHelper: { require: './helpers/ApiHelper.ts' }
          },
          include: {
            I: './steps/steps_file.ts',
            checkoutPage: './pages/index.ts'
          },
          gherkin: {
            features: './features/*.feature',
            steps: ['./step_definitions/checkout.steps.ts']
          }
        };
        """.write(to: configURL, atomically: true, encoding: .utf8)

        // 7. Test file exercising barrel re-exports, inheritance, local `new Class()`, destructuring, same-file function, and `I.*`
        let testURL = root.appendingPathComponent("tests/checkout_test.ts")
        let testSource = """
        import { CheckoutPage } from '../pages';

        async function prepareTestFixture() {
          return 'WELCOME20';
        }

        Feature('Checkout');
        Scenario('full flow', async ({ I, checkoutPage }) => {
          const code = await prepareTestFixture();
          await I.loginWithSso('alice@example.com');
          await I.seedOrderViaRest('ORD-1');
          await checkoutPage.submitOrder(code);
          await checkoutPage.waitForToast('Order confirmed');
          const localPage = new CheckoutPage();
          await localPage.calculateTotal(50);
          const { submitOrder } = checkoutPage;
          await submitOrder('SAVE10');
        });
        """
        try testSource.write(to: testURL, atomically: true, encoding: .utf8)

        let workspace = WorkspaceScanner.scan(rootURL: root)

        // A. Same-file function call `prepareTestFixture()` -> line 3 of checkout_test.ts
        let sameFileCallOffset = (testSource as NSString).range(of: "prepareTestFixture();").location + 3
        let sameFileHit = ImportNavigator.resolveTarget(
            atUTF16Offset: sameFileCallOffset,
            in: testSource,
            sourceFileURL: testURL,
            workspaceRoot: root,
            config: workspace.config,
            workspaceFiles: workspace.files
        )
        XCTAssertEqual(sameFileHit?.target.fileURL.standardizedFileURL.path, testURL.standardizedFileURL.path)
        XCTAssertEqual(sameFileHit?.target.lineNumber, 3)

        // B. `I.loginWithSso` -> prioritizes `steps/steps_file.ts` line 5 over `steps.d.ts`!
        let ssoOffset = (testSource as NSString).range(of: "loginWithSso").location + 3
        let ssoHit = ImportNavigator.resolveTarget(
            atUTF16Offset: ssoOffset,
            in: testSource,
            sourceFileURL: testURL,
            workspaceRoot: root,
            config: workspace.config,
            workspaceFiles: workspace.files
        )
        XCTAssertEqual(ssoHit?.target.fileURL.standardizedFileURL.path, stepsFileURL.standardizedFileURL.path)
        XCTAssertEqual(ssoHit?.target.lineNumber, 5)

        // C. `I.seedOrderViaRest` -> prioritizes custom helper `helpers/ApiHelper.ts` line 3 over `steps.d.ts`!
        let helperStepOffset = (testSource as NSString).range(of: "seedOrderViaRest").location + 3
        let helperStepHit = ImportNavigator.resolveTarget(
            atUTF16Offset: helperStepOffset,
            in: testSource,
            sourceFileURL: testURL,
            workspaceRoot: root,
            config: workspace.config,
            workspaceFiles: workspace.files
        )
        XCTAssertEqual(helperStepHit?.target.fileURL.standardizedFileURL.path, apiHelperURL.standardizedFileURL.path)
        XCTAssertEqual(helperStepHit?.target.lineNumber, 3)

        // D. Barrel re-export hop: `checkoutPage.submitOrder(code)` (where include points to `./pages/index.ts`) -> hops to `pages/CheckoutPage.ts` line 4!
        let submitOffset = (testSource as NSString).range(of: "submitOrder(code)").location + 3
        let submitHit = ImportNavigator.resolveTarget(
            atUTF16Offset: submitOffset,
            in: testSource,
            sourceFileURL: testURL,
            workspaceRoot: root,
            config: workspace.config,
            workspaceFiles: workspace.files
        )
        XCTAssertEqual(submitHit?.target.fileURL.standardizedFileURL.path, checkoutPageURL.standardizedFileURL.path)
        XCTAssertEqual(submitHit?.target.lineNumber, 4)

        // E. Class inheritance + comment/call-site immunity: `checkoutPage.waitForToast(...)` -> hops through index.ts -> CheckoutPage -> extends BasePage -> BasePage.ts line 8 (skipping comment lines 1-2 and call site line 5!)
        let toastOffset = (testSource as NSString).range(of: "waitForToast").location + 3
        let toastHit = ImportNavigator.resolveTarget(
            atUTF16Offset: toastOffset,
            in: testSource,
            sourceFileURL: testURL,
            workspaceRoot: root,
            config: workspace.config,
            workspaceFiles: workspace.files
        )
        XCTAssertEqual(toastHit?.target.fileURL.standardizedFileURL.path, basePageURL.standardizedFileURL.path)
        XCTAssertEqual(toastHit?.target.lineNumber, 8)

        // F. Local instance `const localPage = new CheckoutPage(); await localPage.calculateTotal(50)` -> hops through barrel import `../pages` to `CheckoutPage.ts` line 9!
        let localInstOffset = (testSource as NSString).range(of: "calculateTotal(50)").location + 3
        let localInstHit = ImportNavigator.resolveTarget(
            atUTF16Offset: localInstOffset,
            in: testSource,
            sourceFileURL: testURL,
            workspaceRoot: root,
            config: workspace.config,
            workspaceFiles: workspace.files
        )
        XCTAssertEqual(localInstHit?.target.fileURL.standardizedFileURL.path, checkoutPageURL.standardizedFileURL.path)
        XCTAssertEqual(localInstHit?.target.lineNumber, 9)

        // G. Destructured method `const { submitOrder } = checkoutPage; await submitOrder('SAVE10')` -> resolves to `CheckoutPage.ts` line 4!
        let destructuredOffset = (testSource as NSString).range(of: "submitOrder('SAVE10')").location + 3
        let destructuredHit = ImportNavigator.resolveTarget(
            atUTF16Offset: destructuredOffset,
            in: testSource,
            sourceFileURL: testURL,
            workspaceRoot: root,
            config: workspace.config,
            workspaceFiles: workspace.files
        )
        XCTAssertEqual(destructuredHit?.target.fileURL.standardizedFileURL.path, checkoutPageURL.standardizedFileURL.path)
        XCTAssertEqual(destructuredHit?.target.lineNumber, 4)

        // H. `this.calculateTotal(100)` inside `CheckoutPage.ts` -> resolves to line 9 of `CheckoutPage.ts`!
        let thisCallOffset = (checkoutPageSource as NSString).range(of: "calculateTotal(100)").location + 3
        let thisCallHit = ImportNavigator.resolveTarget(
            atUTF16Offset: thisCallOffset,
            in: checkoutPageSource,
            sourceFileURL: checkoutPageURL,
            workspaceRoot: root,
            config: workspace.config,
            workspaceFiles: workspace.files
        )
        XCTAssertEqual(thisCallHit?.target.fileURL.standardizedFileURL.path, checkoutPageURL.standardizedFileURL.path)
        XCTAssertEqual(thisCallHit?.target.lineNumber, 9)

        // I. Gherkin `.feature` step line `When I apply expired promo code "EXPIRED99"` -> resolves to `step_definitions/checkout.steps.ts` line 7!
        let gherkinOffset = (featureSource as NSString).range(of: "apply expired promo code").location + 3
        let gherkinHit = ImportNavigator.resolveTarget(
            atUTF16Offset: gherkinOffset,
            in: featureSource,
            sourceFileURL: featureURL,
            workspaceRoot: root,
            config: workspace.config,
            workspaceFiles: workspace.files
        )
        XCTAssertEqual(gherkinHit?.target.fileURL.standardizedFileURL.path, bddStepsURL.standardizedFileURL.path)
        XCTAssertEqual(gherkinHit?.target.lineNumber, 7)

        // J. Reverse Navigation (Declaration -> Call-Site Usages): clicking `submitOrder` on its declaration line 4 in `CheckoutPage.ts` finds usages in `tests/checkout_test.ts`!
        let declOffset = (checkoutPageSource as NSString).range(of: "submitOrder(promoCode").location + 3
        let usagesHit = ImportNavigator.resolveTarget(
            atUTF16Offset: declOffset,
            in: checkoutPageSource,
            sourceFileURL: checkoutPageURL,
            workspaceRoot: root,
            config: workspace.config,
            workspaceFiles: workspace.files
        )
        XCTAssertEqual(usagesHit?.kind, .usage)
        XCTAssertTrue(usagesHit?.targets.contains(where: {
            $0.fileURL.standardizedFileURL.path == testURL.standardizedFileURL.path && $0.lineNumber == 12
        }) == true)
    }

    func testExecutableTestFileFlagOnlyMatchesTestAndFeatureFilesWithDeclarations() throws {
        let sampleFeature = ParsedFeature(title: "Login", filePath: "/a/login_test.ts", lineNumber: 1, scenarios: [])
        let testFile = WorkspaceFile(path: "/a/login_test.ts", relativePath: "login_test.ts", name: "login_test.ts", fileExtension: "ts", category: .testSuite, features: [sampleFeature])
        let emptyTestFile = WorkspaceFile(path: "/a/empty.TEST.ts", relativePath: "empty.TEST.ts", name: "empty.TEST.ts", fileExtension: "ts", category: .testSuite, features: [])
        let featureFile = WorkspaceFile(path: "/a/login.feature", relativePath: "login.feature", name: "login.feature", fileExtension: "feature", category: .gherkinFeature, features: [sampleFeature])
        let pageFile = WorkspaceFile(path: "/a/LoginPage.ts", relativePath: "LoginPage.ts", name: "LoginPage.ts", fileExtension: "ts", category: .pageObject)
        let configFile = WorkspaceFile(path: "/a/codecept.conf.ts", relativePath: "codecept.conf.ts", name: "codecept.conf.ts", fileExtension: "ts", category: .config)
        let helperFile = WorkspaceFile(path: "/a/custom_helper.ts", relativePath: "custom_helper.ts", name: "custom_helper.ts", fileExtension: "ts", category: .helper)
        let otherFile = WorkspaceFile(path: "/a/constants.ts", relativePath: "constants.ts", name: "constants.ts", fileExtension: "ts", category: .other)

        XCTAssertTrue(testFile.isExecutableTestFile)
        XCTAssertFalse(emptyTestFile.isExecutableTestFile)
        XCTAssertTrue(featureFile.isExecutableTestFile)
        XCTAssertFalse(pageFile.isExecutableTestFile)
        XCTAssertFalse(configFile.isExecutableTestFile)
        XCTAssertFalse(helperFile.isExecutableTestFile)
        XCTAssertFalse(otherFile.isExecutableTestFile)

        // End-to-end WorkspaceScanner check: `*.TEST.ts` without Feature()/Scenario() MUST NOT be classified as testSuite
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceptra-test-content-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeTestContent = """
        // Feature('Commented out feature should be ignored')
        /* Scenario('Commented out scenario') */
        export const mockPayload = { status: 'ok' };
        describe('unit test', () => {
          it('is not codeceptjs', () => {});
        });
        """
        try fakeTestContent.write(to: root.appendingPathComponent("payload.TEST.ts"), atomically: true, encoding: .utf8)

        let realTestContent = """
        Feature('Real Suite');
        Scenario('runs properly', ({ I }) => {
          I.amOnPage('/');
        });
        """
        try realTestContent.write(to: root.appendingPathComponent("real.TEST.ts"), atomically: true, encoding: .utf8)

        let ws = WorkspaceScanner.scan(rootURL: root)
        let fakeFile = ws.files.first { $0.name == "payload.TEST.ts" }
        let realFile = ws.files.first { $0.name == "real.TEST.ts" }

        XCTAssertNotNil(fakeFile)
        XCTAssertEqual(fakeFile?.category, .other)
        XCTAssertEqual(fakeFile?.isExecutableTestFile, false)
        XCTAssertFalse(ws.testFiles.contains { $0.name == "payload.TEST.ts" })

        XCTAssertNotNil(realFile)
        XCTAssertEqual(realFile?.category, .testSuite)
        XCTAssertEqual(realFile?.isExecutableTestFile, true)
        XCTAssertTrue(ws.testFiles.contains { $0.name == "real.TEST.ts" })
    }
}
