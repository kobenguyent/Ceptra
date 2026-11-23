import CeptraCore
import Foundation
import XCTest

final class PlaywrightSupportTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir(_ suffix: String = "pw") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceptra-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    // MARK: - Config Discovery & Parsing

    func testDiscoversAndParsesPlaywrightConfigTS() throws {
        let root = try makeTempDir("pw-config")
        try ProjectScaffolder.createSamplePlaywrightWorkspace(at: root)

        let discovered = ConfigParser.discoverConfigFiles(in: root)
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered.first?.lastPathComponent, "playwright.config.ts")

        let workspace = WorkspaceScanner.scan(rootURL: root)
        XCTAssertEqual(workspace.config.framework, .playwright)
        XCTAssertEqual(workspace.config.outputDirectory, "./test-results")
        XCTAssertEqual(workspace.config.htmlReportDirectory, "playwright-report")
        XCTAssertEqual(workspace.config.baseURL, "https://playwright.dev")
        XCTAssertEqual(workspace.config.playwrightProjects, ["chromium", "firefox", "webkit"])
        XCTAssertEqual(workspace.config.multipleSuites.map(\.name), ["chromium", "firefox", "webkit"])
        XCTAssertEqual(workspace.config.packageCodeceptVersion, "^1.50.0")
        XCTAssertTrue(workspace.config.isTypeScript)

        // Discovered test suites & tags
        XCTAssertEqual(workspace.testFiles.count, 2)
        XCTAssertTrue(workspace.allTags.contains("@smoke"))
        XCTAssertTrue(workspace.allTags.contains("@web"))
        XCTAssertTrue(workspace.allTags.contains("@api"))
        XCTAssertTrue(workspace.supportFiles.contains(where: { $0.name == "HomePage.ts" }))
    }

    func testMixedCodeceptAndPlaywrightMonorepoPerFileResolution() throws {
        let root = try makeTempDir("mixed-monorepo")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("e2e-codecept/tests"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("e2e-playwright/specs"), withIntermediateDirectories: true)

        try """
        export const config = {
          name: 'codecept-suite',
          tests: './tests/*_test.ts',
          output: './output',
          helpers: { REST: { endpoint: 'http://localhost:3000' } }
        };
        """.write(to: root.appendingPathComponent("e2e-codecept/codecept.conf.ts"), atomically: true, encoding: .utf8)

        try """
        Feature('API Health');
        Scenario('returns 200', async ({ I }) => {
          await I.sendGetRequest('/health');
        });
        """.write(to: root.appendingPathComponent("e2e-codecept/tests/health_test.ts"), atomically: true, encoding: .utf8)

        try """
        import { defineConfig } from '@playwright/test';
        export default defineConfig({
          testDir: './specs',
          outputDir: './test-results',
          projects: [{ name: 'chromium' }],
        });
        """.write(to: root.appendingPathComponent("e2e-playwright/playwright.config.ts"), atomically: true, encoding: .utf8)

        try """
        import { test, expect } from '@playwright/test';
        test('loads home', async ({ page }) => {
          await page.goto('/');
          await expect(page).toHaveTitle(/Home/);
        });
        """.write(to: root.appendingPathComponent("e2e-playwright/specs/home.spec.ts"), atomically: true, encoding: .utf8)

        let ws = WorkspaceScanner.scan(rootURL: root)
        XCTAssertEqual(ws.discoveredConfigs.count, 2)

        let codeceptCfg = ws.resolvedConfig(forFilePath: "e2e-codecept/tests/health_test.ts")
        XCTAssertEqual(codeceptCfg.framework, .codeceptJS)
        XCTAssertTrue(codeceptCfg.configFilePath?.hasSuffix("e2e-codecept/codecept.conf.ts") == true)

        let playwrightCfg = ws.resolvedConfig(forFilePath: "e2e-playwright/specs/home.spec.ts")
        XCTAssertEqual(playwrightCfg.framework, .playwright)
        XCTAssertTrue(playwrightCfg.configFilePath?.hasSuffix("e2e-playwright/playwright.config.ts") == true)
    }

    // MARK: - Playwright Test File Parsing

    func testParsesPlaywrightDescribeTestsHooksTagsAndSteps() {
        let source = """
        import { test, expect } from '@playwright/test';

        test.describe('Authentication', { tag: ['@auth', '@smoke'] }, () => {
          test.beforeEach(async ({ page }) => {
            await page.goto('/login');
          });

          test('signs in with valid credentials @critical', async ({ page }) => {
            await test.step('Fill credentials', async () => {
              await page.getByLabel('Email').fill('qa@example.com');
              await page.getByRole('button', { name: 'Sign in' }).click();
            });
            await expect(page).toHaveURL(/dashboard/);
          });

          test.skip('legacy OAuth flow', { tag: '@legacy' }, async ({ page }) => {
            await page.goto('/oauth');
          });

          test.only('fetches profile via API', async ({ request }) => {
            const res = await request.get('/api/me');
            await expect(res).toBeOK();
          });
        });
        """

        let features = TestFileParser.parse(content: source, filePath: "/tmp/tests/auth.spec.ts")
        XCTAssertEqual(features.count, 1)
        let suite = features[0]
        XCTAssertEqual(suite.title, "Authentication")
        XCTAssertEqual(suite.tags, ["@auth", "@smoke"])
        XCTAssertEqual(suite.hooks.count, 1)
        XCTAssertEqual(suite.hooks[0].kind, "beforeEach")
        XCTAssertEqual(suite.hooks[0].steps.first?.action, "goto")
        XCTAssertEqual(suite.hooks[0].steps.first?.category, .navigation)

        XCTAssertEqual(suite.scenarios.count, 3)
        XCTAssertEqual(suite.scenarios[0].cleanTitle, "signs in with valid credentials")
        XCTAssertTrue(suite.scenarios[0].tags.contains("@critical"))
        XCTAssertTrue(suite.scenarios[0].tags.contains("@smoke"))
        XCTAssertTrue(suite.scenarios[0].steps.contains(where: { $0.actor == "test" && $0.action == "step" && $0.category == .control }))
        XCTAssertTrue(suite.scenarios[0].steps.contains(where: { $0.actor == "expect" && $0.action == "toHaveURL" && $0.category == .assertion }))

        XCTAssertEqual(suite.scenarios[1].modifier, .skip)
        XCTAssertTrue(suite.scenarios[1].tags.contains("@legacy"))

        XCTAssertEqual(suite.scenarios[2].modifier, .only)
        XCTAssertTrue(suite.scenarios[2].steps.contains(where: { $0.actor == "request" && $0.action == "get" && $0.category == .network }))
        XCTAssertTrue(suite.scenarios[2].steps.contains(where: { $0.actor == "expect" && $0.action == "toBeOK" && $0.category == .assertion }))
    }

    func testDoesNotFalsePositiveOnPlainNonTestJSFile() {
        let helperSource = """
        export function runHelper(input: string) {
          const test = (x: string) => x.trim();
          return test(input);
        }
        """
        XCTAssertTrue(TestFileParser.parse(content: helperSource, filePath: "/tmp/utils/strings.ts").isEmpty)
    }

    // MARK: - Toolchain & Command Builder

    func testPlaywrightToolchainResolutionAndCommandBuilder() throws {
        let root = try makeTempDir("pw-cmd")
        let binDir = root.appendingPathComponent("node_modules/.bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let pwBin = binDir.appendingPathComponent("playwright")
        try "#!/usr/bin/env node\nconsole.log('pw');\n".write(to: pwBin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pwBin.path)

        let tc = NodeToolchainResolver.resolve(workspaceRoot: root, framework: .playwright, runtime: .node)
        XCTAssertEqual(tc.framework, .playwright)
        XCTAssertEqual(tc.runnerExecutable, pwBin.path)
        XCTAssertEqual(tc.resolutionSource, "Project node_modules")

        var opts = RunOptions()
        opts.playwrightHeaded = true
        opts.playwrightTraceMode = .retainOnFailure
        opts.playwrightUpdateSnapshots = true
        opts.bailOnFail = true
        opts.noTimeouts = true
        opts.grepPattern = "@smoke"
        opts.invertGrep = true
        opts.playwrightSelectedProjects = ["chromium"]

        let traceDir = root.appendingPathComponent("test-results/.ceptra-traces/1")
        let cmd = CommandBuilder.build(
            mode: .runFile(relativePath: "tests/example.spec.ts"),
            options: opts,
            workspaceRoot: root,
            configFilePath: root.appendingPathComponent("playwright.config.ts").path,
            toolchain: tc,
            framework: .playwright,
            traceOutputDirectory: traceDir,
            colorOutput: false
        )

        XCTAssertEqual(cmd.arguments.first, "test")
        XCTAssertTrue(cmd.arguments.contains("tests/example.spec.ts"))
        XCTAssertTrue(cmd.arguments.contains("-c"))
        XCTAssertTrue(cmd.arguments.contains("--headed"))
        XCTAssertTrue(cmd.arguments.contains("--max-failures=1"))
        XCTAssertTrue(cmd.arguments.contains("--timeout=0"))
        XCTAssertTrue(cmd.arguments.contains("--update-snapshots"))
        XCTAssertTrue(cmd.arguments.contains("--trace=retain-on-failure"))
        XCTAssertTrue(cmd.arguments.contains("--project=chromium"))
        XCTAssertTrue(cmd.arguments.contains("--grep-invert"))
        XCTAssertTrue(cmd.arguments.contains("@smoke"))
        XCTAssertEqual(cmd.environment["PLAYWRIGHT_HTML_OPEN"], "never")
        XCTAssertEqual(cmd.environment["CEPTRA_TIME_TRAVEL_DIR"], traceDir.path)
        XCTAssertTrue(cmd.arguments.contains(where: { $0.hasPrefix("--reporter=list,") && $0.contains("ceptra-pw-time-travel-reporter.cjs") }))
        // Never injects CodeceptJS NodeCompatLoader into Playwright
        XCTAssertFalse((cmd.environment["NODE_OPTIONS"] ?? "").contains("ceptra-node-compat"))

        // Workers & Projects modes
        let workersCmd = CommandBuilder.build(
            mode: .runWorkers(count: 4, strategy: .pool, selectedRuns: ["firefox"], lastFailed: true),
            options: RunOptions(timeTravelTrace: false),
            workspaceRoot: root,
            toolchain: tc,
            framework: .playwright
        )
        XCTAssertTrue(workersCmd.arguments.contains("--workers=4"))
        XCTAssertTrue(workersCmd.arguments.contains("--project=firefox"))
        XCTAssertTrue(workersCmd.arguments.contains("--last-failed"))

        // CDP Debug mode
        let debugCmd = CommandBuilder.build(
            mode: .runScenario(relativePath: "tests/example.spec.ts", scenarioTitle: "has title"),
            options: RunOptions(timeTravelTrace: false),
            workspaceRoot: root,
            toolchain: tc,
            framework: .playwright,
            debugOptions: DebugLaunchOptions(enabled: true, headedBrowser: true)
        )
        XCTAssertTrue(debugCmd.arguments.contains("--workers=1"))
        XCTAssertTrue(debugCmd.arguments.contains("--timeout=0"))
        XCTAssertTrue(debugCmd.arguments.contains("--headed"))
        XCTAssertTrue((debugCmd.environment["NODE_OPTIONS"] ?? "").contains("--inspect-brk=127.0.0.1:0"))

        // Codegen & List & Version
        let codegenCmd = CommandBuilder.build(
            mode: .playwrightCodegen(url: "https://playwright.dev"),
            options: RunOptions(),
            workspaceRoot: root,
            toolchain: tc,
            framework: .playwright
        )
        XCTAssertEqual(codegenCmd.arguments, ["codegen", "https://playwright.dev"])

        let uiCmd = CodeceptUIServerManager.buildStartCommand(
            workspaceRoot: root,
            port: 49210,
            customConfigPath: "playwright.config.ts",
            toolchain: tc,
            framework: .playwright
        )
        XCTAssertEqual(uiCmd.arguments, ["test", "--ui-host=127.0.0.1", "--ui-port=49210", "-c", "playwright.config.ts"])
    }

    // MARK: - Live Output Parser (Playwright List Reporter)

    func testParsesPlaywrightListReporterOutput() {
        let parser = LiveOutputParser()
        let lines = [
            "Running 4 tests using 2 workers",
            "  ✓  1 [chromium] › tests/login.spec.ts:5:5 › Login › signs in smoothly @smoke (1.2s)",
            "  ✘  2 [chromium] › tests/login.spec.ts:18:5 › Login › rejects bad password (450ms)",
            "  -  3 [firefox] › tests/checkout.spec.ts:9:5 › skips legacy flow",
            "  ±  4 [webkit] › tests/api.spec.ts:3:5 › fetches user (120ms)",
            "",
            "  1 failed",
            "  1 flaky",
            "  1 skipped",
            "  1 passed (3.4s)"
        ]

        var finished: [ExecutedScenarioRecord] = []
        for line in lines {
            for ev in parser.feed(line: line) {
                if case .scenarioFinished(let rec) = ev {
                    finished.append(rec)
                }
            }
        }

        XCTAssertEqual(finished.count, 4)
        XCTAssertEqual(finished[0].featureTitle, "Login")
        XCTAssertEqual(finished[0].scenarioTitle, "signs in smoothly @smoke")
        XCTAssertEqual(finished[0].filePath, "tests/login.spec.ts")
        XCTAssertEqual(finished[0].status, .passed)
        XCTAssertEqual(finished[0].durationMs, 1200)
        XCTAssertEqual(finished[0].tags, ["@smoke"])

        XCTAssertEqual(finished[1].status, .failed)
        XCTAssertEqual(finished[1].durationMs, 450)

        XCTAssertEqual(finished[2].status, .skipped)
        XCTAssertEqual(finished[2].featureTitle, "checkout")

        XCTAssertEqual(finished[3].status, .passed)
        XCTAssertEqual(finished[3].durationMs, 120)

        XCTAssertEqual(parser.summaryPassed, 2) // 1 passed + 1 flaky
        XCTAssertEqual(parser.summaryFailed, 1)
        XCTAssertEqual(parser.summarySkipped, 1)
    }

    // MARK: - Zero-Config Playwright Time-Travel Reporter (Live Node.js Execution)

    func testPlaywrightTimeTravelReporterProducesValidCeptraTraceAndHTML() throws {
        guard let nodePath = NodeToolchainResolver.findExecutable(
            named: "node",
            in: NodeToolchainResolver.buildSearchPath()
        ) else {
            throw XCTSkip("Node.js not available on host")
        }

        let workDir = try makeTempDir("pw-reporter")
        let traceDir = workDir.appendingPathComponent("traces", isDirectory: true)
        try FileManager.default.createDirectory(at: traceDir, withIntermediateDirectories: true)

        guard let reporterURL = PlaywrightTimeTravelReporterLoader.ensureReporterFileURL(baseDirectory: workDir) else {
            XCTFail("Failed to materialize Playwright time-travel reporter")
            return
        }

        // Write a tiny 1x1 PNG attachment to verify screenshot embedding
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aU3kAAAAASUVORK5CYII="
        let shotURL = workDir.appendingPathComponent("failure.png")
        try Data(base64Encoded: pngBase64)!.write(to: shotURL)

        let driverJS = """
        const Reporter = require(\(CommandBuilder.shellSingleQuote(reporterURL.path)));
        const rep = new Reporter();
        rep.onBegin({ projects: [{ name: 'chromium' }] });
        const testObj = {
          title: 'submits login form',
          tags: ['@smoke'],
          location: { file: '/repo/tests/login.spec.ts', line: 5, column: 5 },
          titlePath: () => ['', 'chromium', 'tests/login.spec.ts', 'Login', 'submits login form'],
          parent: { project: () => ({ name: 'chromium' }) }
        };
        const start = new Date();
        rep.onTestBegin(testObj, { startTime: start });
        const step1 = { title: "page.goto('https://example.com/login')", category: 'pw:api', startTime: start, duration: 180 };
        rep.onStepBegin(testObj, {}, step1);
        rep.onStepEnd(testObj, {}, step1);
        const step2 = {
          title: "expect(locator('#welcome')).toBeVisible()",
          category: 'expect',
          startTime: new Date(start.getTime() + 180),
          duration: 320,
          error: { message: '\\u001b[31mTimed out waiting for #welcome\\u001b[0m' }
        };
        rep.onStepBegin(testObj, {}, step2);
        rep.onStdErr('Console error: 500 Internal Server Error', testObj);
        rep.onStepEnd(testObj, {}, step2);
        rep.onTestEnd(testObj, {
          status: 'failed',
          duration: 500,
          startTime: start,
          error: { message: 'Timed out waiting for #welcome', stack: 'Error: Timed out\\n  at login.spec.ts:12' },
          attachments: [
            { name: 'screenshot', contentType: 'image/png', path: \(CommandBuilder.shellSingleQuote(shotURL.path)) }
          ]
        });
        rep.onEnd({ status: 'failed' });
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = ["-e", driverJS]
        var env = ProcessInfo.processInfo.environment
        env["CEPTRA_TIME_TRAVEL_DIR"] = traceDir.path
        proc.environment = env
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        let traces = TimeTravelTraceMerger.loadWorkerTraces(from: traceDir)
        XCTAssertEqual(traces.count, 1)
        let sc = traces[0]
        XCTAssertEqual(sc.featureTitle, "Login")
        XCTAssertEqual(sc.scenarioTitle, "submits login form")
        XCTAssertEqual(sc.status, .failed)
        XCTAssertEqual(sc.tags, ["@smoke"])
        XCTAssertEqual(sc.steps.count, 2)
        XCTAssertEqual(sc.steps[0].diagnostics?.pageURL, "https://example.com/login")
        XCTAssertEqual(sc.steps[1].status, .failed)
        XCTAssertEqual(sc.steps[1].diagnostics?.assertion?.passed, false)
        XCTAssertTrue(sc.steps[1].diagnostics?.afterScreenshotDataURI?.hasPrefix("data:image/png;base64,") == true)
        XCTAssertEqual(sc.steps[1].diagnostics?.consoleEntries.first?.level, .error)

        // Verify standalone HTML time-travel export succeeds cleanly
        let reportID = UUID()
        let bundle = TimeTravelTraceBundle(reportID: reportID, scenarios: traces)
        let report = TestRunReport(
            id: reportID,
            projectPath: workDir.path,
            projectName: "pw-demo",
            label: "Run login.spec.ts",
            commandLine: "playwright test tests/login.spec.ts",
            startedAt: Date(),
            finishedAt: Date(),
            exitCode: 1,
            passedCount: 0,
            failedCount: 1,
            skippedCount: 0,
            durationMs: 500,
            scenarios: traces,
            rawOutput: ""
        )
        let html = ReportExporter.toHTML(report, traceBundle: bundle)
        XCTAssertTrue(html.contains("submits login form"))
        XCTAssertTrue(html.contains("iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB"))
    }

    // MARK: - IntelliSense, AI Prompt & Backward Compatibility

    func testPlaywrightIntelliSenseCompletions() {
        let src1 = "import { test, expect } from '@playwright/test';\nawait page.getBy"
        let r1 = IntelliSenseEngine.completions(
            in: src1,
            cursorUTF16Offset: (src1 as NSString).length,
            language: "typescript",
            sourceFileURL: URL(fileURLWithPath: "/tmp/tests/a.spec.ts"),
            workspace: nil,
            index: WorkspaceCompletionIndex()
        )
        XCTAssertTrue(r1?.items.contains(where: { $0.label == "getByRole" }) == true)
        XCTAssertTrue(r1?.items.contains(where: { $0.label == "getByTestId" }) == true)

        let src2 = "await expect(page.getByRole('button')).toBe"
        let r2 = IntelliSenseEngine.completions(
            in: src2,
            cursorUTF16Offset: (src2 as NSString).length,
            language: "typescript",
            sourceFileURL: nil,
            workspace: nil,
            index: WorkspaceCompletionIndex()
        )
        XCTAssertTrue(r2?.items.contains(where: { $0.label == "toBeVisible" }) == true)
        XCTAssertTrue(r2?.items.contains(where: { $0.label == "toBeOK" }) == true)

        let srcChain = "await page.getByRole('button', { name: 'Save' }).cl"
        let rChain = IntelliSenseEngine.completions(
            in: srcChain,
            cursorUTF16Offset: (srcChain as NSString).length,
            language: "typescript",
            sourceFileURL: nil,
            workspace: nil,
            index: WorkspaceCompletionIndex()
        )
        XCTAssertTrue(rChain?.items.contains(where: { $0.label == "click" }) == true)
        XCTAssertTrue(rChain?.items.contains(where: { $0.label == "clear" }) == true)

        let src3 = "await request.po"
        let r3 = IntelliSenseEngine.completions(
            in: src3,
            cursorUTF16Offset: (src3 as NSString).length,
            language: "typescript",
            sourceFileURL: nil,
            workspace: nil,
            index: WorkspaceCompletionIndex()
        )
        XCTAssertTrue(r3?.items.contains(where: { $0.label == "post" }) == true)
    }

    func testAIContextAssemblerAdaptsToPlaywright() {
        let prompt = AIContextAssembler.buildSystemPrompt(
            helperDisplayName: "Playwright · chromium",
            framework: .playwright
        )
        XCTAssertTrue(prompt.contains("@playwright/test"))
        XCTAssertTrue(prompt.contains("page.getByRole"))
        XCTAssertFalse(prompt.contains("Feature`, `Scenario"))
    }

    func testLegacyPersistedSettingsAndRunOptionsDecodeCleanly() throws {
        let legacyJSON = #"{"showSteps":true,"workerCount":3}"#
        let opts = try JSONDecoder().decode(RunOptions.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(opts.workerCount, 3)
        XCTAssertFalse(opts.playwrightHeaded)
        XCTAssertEqual(opts.playwrightTraceMode, .configDefault)
        XCTAssertTrue(opts.playwrightSelectedProjects.isEmpty)

        let legacyConfigJSON = #"{"projectName":"old-suite"}"#
        let cfg = try JSONDecoder().decode(CodeceptConfigSummary.self, from: Data(legacyConfigJSON.utf8))
        XCTAssertEqual(cfg.framework, .codeceptJS)
        XCTAssertTrue(cfg.playwrightProjects.isEmpty)
    }
}
