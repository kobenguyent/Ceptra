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
        XCTAssertEqual(finished[0].featureTitle, "[chromium] Login")
        XCTAssertEqual(finished[0].scenarioTitle, "signs in smoothly @smoke")
        XCTAssertEqual(finished[0].filePath, "tests/login.spec.ts")
        XCTAssertEqual(finished[0].status, .passed)
        XCTAssertEqual(finished[0].durationMs, 1200)
        XCTAssertEqual(finished[0].tags, ["@smoke"])

        XCTAssertEqual(finished[1].status, .failed)
        XCTAssertEqual(finished[1].durationMs, 450)

        XCTAssertEqual(finished[2].status, .skipped)
        XCTAssertEqual(finished[2].featureTitle, "[firefox] checkout")

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
        XCTAssertEqual(sc.featureTitle, "[chromium] Login")
        XCTAssertEqual(sc.scenarioTitle, "submits login form")
        XCTAssertEqual(sc.status, .failed)
        XCTAssertEqual(sc.tags, ["@smoke"])
        XCTAssertEqual(sc.steps.count, 2)
        XCTAssertEqual(sc.steps[0].diagnostics?.pageURL, "https://example.com/login")
        XCTAssertEqual(sc.steps[1].status, .failed)
        XCTAssertEqual(sc.steps[1].diagnostics?.assertion?.passed, false)
        XCTAssertEqual(sc.steps[1].diagnostics?.assertion?.method, "toBeVisible")
        XCTAssertTrue(sc.steps[1].diagnostics?.afterScreenshotDataURI?.hasPrefix("data:image/png;base64,") == true)
        XCTAssertEqual(sc.steps[1].diagnostics?.consoleEntries.first?.level, .error)

        // Verify standalone HTML time-travel export classifies web test as "web" (not "api")
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
        XCTAssertTrue(html.contains(#"data-report-mode="web""#))
        XCTAssertFalse(html.contains(#"data-report-mode="api""#))
    }

    func testPlaywrightColorEnvHasNoNoColorConflictAndAutoEnablesTrace() throws {
        let root = try makeTempDir("pw-env-trace")
        let binDir = root.appendingPathComponent("node_modules/.bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let pwBin = binDir.appendingPathComponent("playwright")
        try "#!/usr/bin/env node\n".write(to: pwBin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pwBin.path)

        let tc = NodeToolchainResolver.resolve(workspaceRoot: root, framework: .playwright, runtime: .node)
        let traceDir = root.appendingPathComponent("test-results/.ceptra-traces/auto")

        // Default traceMode (.configDefault) with timeTravelTrace enabled must auto-append --trace=on
        let autoCmd = CommandBuilder.build(
            mode: .runFile(relativePath: "tests/example.spec.ts"),
            options: RunOptions(timeTravelTrace: true, playwrightTraceMode: .configDefault),
            workspaceRoot: root,
            toolchain: tc,
            framework: .playwright,
            traceOutputDirectory: traceDir,
            colorOutput: false
        )
        XCTAssertEqual(autoCmd.environment["FORCE_COLOR"], "0")
        XCTAssertNil(autoCmd.environment["NO_COLOR"], "NO_COLOR must be unset when FORCE_COLOR=0 to avoid Node warning")
        XCTAssertTrue(autoCmd.arguments.contains("--trace=on"))

        // Explicit .off traceMode must still be respected (no --trace=on override)
        let offCmd = CommandBuilder.build(
            mode: .runFile(relativePath: "tests/example.spec.ts"),
            options: RunOptions(timeTravelTrace: true, playwrightTraceMode: .off),
            workspaceRoot: root,
            toolchain: tc,
            framework: .playwright,
            traceOutputDirectory: traceDir,
            colorOutput: false
        )
        XCTAssertTrue(offCmd.arguments.contains("--trace=off"))
        XCTAssertFalse(offCmd.arguments.contains("--trace=on"))
    }

    func testMixedPlaywrightWebAndApiReplayClassificationAndDeduplicatedMerge() {
        let now = Date()
        // 1. Pure Playwright web test with zero screenshots and Playwright web assertions -> MUST be "web"
        let webTrace = ExecutedScenarioRecord(
            featureTitle: "[chromium] Playwright Docs",
            scenarioTitle: "has title and opens Getting Started @web",
            filePath: "/repo/tests/example.spec.ts",
            status: .passed,
            durationMs: 680,
            startedAt: now,
            finishedAt: now.addingTimeInterval(0.68),
            tags: ["@smoke", "@web"],
            steps: [
                ExecutedStepRecord(
                    text: #"Navigate to "https://playwright.dev/""#,
                    status: .passed,
                    durationMs: 320,
                    startedAt: now,
                    diagnostics: TimeTravelStepDiagnostics(pageURL: "https://playwright.dev/")
                ),
                ExecutedStepRecord(
                    text: #"Expect "toHaveTitle""#,
                    status: .passed,
                    durationMs: 12,
                    startedAt: now.addingTimeInterval(0.32),
                    diagnostics: TimeTravelStepDiagnostics(
                        pageURL: "https://playwright.dev/",
                        assertion: TimeTravelAssertionRecord(method: "toHaveTitle", passed: true)
                    )
                )
            ]
        )

        // List reporter emitted describe-level @smoke inline in scenarioTitle
        let webPrimaryFromList = ExecutedScenarioRecord(
            featureTitle: "[chromium] Playwright Docs",
            scenarioTitle: "has title and opens Getting Started @web @smoke",
            filePath: "tests/example.spec.ts",
            status: .passed,
            durationMs: 680,
            tags: ["@smoke", "@web"],
            steps: []
        )

        let mergedWebOnly = TimeTravelTraceMerger.merge(
            primaryScenarios: [webPrimaryFromList],
            traceScenarios: [webTrace],
            runStartedAt: now
        )
        XCTAssertEqual(mergedWebOnly.count, 1, "Matching [project] + stripped @tags must not duplicate scenarios")
        XCTAssertEqual(mergedWebOnly[0].steps.count, 2)

        let webReportID = UUID()
        let webOnlyReport = TestRunReport(
            id: webReportID,
            projectPath: "/repo",
            projectName: "pw-web",
            label: "Web Only",
            commandLine: "playwright test tests/example.spec.ts",
            startedAt: now,
            finishedAt: now.addingTimeInterval(1),
            exitCode: 0,
            passedCount: 1,
            failedCount: 0,
            skippedCount: 0,
            durationMs: 680,
            scenarios: [webPrimaryFromList],
            rawOutput: ""
        )
        let webOnlyHTML = TimeTravelHTMLReportBuilder.build(
            webOnlyReport,
            traceBundle: TimeTravelTraceBundle(reportID: webReportID, scenarios: [webTrace])
        )
        XCTAssertTrue(webOnlyHTML.contains(#"data-report-mode="web""#))
        XCTAssertTrue(webOnlyHTML.contains(#""scenarioKind":"web""#))
        XCTAssertFalse(webOnlyHTML.contains(#"data-report-mode="api""#))

        // 2. Mixed Web + API Playwright run -> MUST be "hybrid" with per-scenario web & api kinds
        let reqID = "pw-api-req-1"
        let apiTrace = ExecutedScenarioRecord(
            featureTitle: "[chromium] JSONPlaceholder API",
            scenarioTitle: "GET /todos/1 returns valid todo @api",
            filePath: "/repo/tests/api.spec.ts",
            status: .passed,
            durationMs: 145,
            startedAt: now.addingTimeInterval(0.7),
            finishedAt: now.addingTimeInterval(0.845),
            tags: ["@api"],
            steps: [
                ExecutedStepRecord(
                    text: #"GET "/todos/1""#,
                    status: .passed,
                    durationMs: 120,
                    startedAt: now.addingTimeInterval(0.7),
                    diagnostics: TimeTravelStepDiagnostics(
                        networkRequests: [
                            TimeTravelNetworkEntry(
                                id: reqID,
                                method: "GET",
                                url: "https://jsonplaceholder.typicode.com/todos/1",
                                resourceType: "api",
                                source: "playwright-api",
                                status: 200,
                                statusText: "OK",
                                durationMs: 120,
                                responseBody: #"{"id":1,"title":"delectus aut autem"}"#
                            )
                        ]
                    )
                ),
                ExecutedStepRecord(
                    text: #"Expect "toBeOK""#,
                    status: .passed,
                    durationMs: 2,
                    startedAt: now.addingTimeInterval(0.82),
                    diagnostics: TimeTravelStepDiagnostics(
                        assertion: TimeTravelAssertionRecord(method: "toBeOK", passed: true, relatedRequestId: reqID)
                    )
                )
            ]
        )

        let apiPrimaryFromList = ExecutedScenarioRecord(
            featureTitle: "[chromium] JSONPlaceholder API",
            scenarioTitle: "GET /todos/1 returns valid todo @api",
            filePath: "tests/api.spec.ts",
            status: .passed,
            durationMs: 145,
            tags: ["@api"],
            steps: []
        )

        let mixedReportID = UUID()
        let mixedReport = TestRunReport(
            id: mixedReportID,
            projectPath: "/repo",
            projectName: "pw-mixed",
            label: "Mixed Web + API",
            commandLine: "playwright test",
            startedAt: now,
            finishedAt: now.addingTimeInterval(1),
            exitCode: 0,
            passedCount: 2,
            failedCount: 0,
            skippedCount: 0,
            durationMs: 845,
            scenarios: [webPrimaryFromList, apiPrimaryFromList],
            rawOutput: ""
        )
        let mixedHTML = TimeTravelHTMLReportBuilder.build(
            mixedReport,
            traceBundle: TimeTravelTraceBundle(reportID: mixedReportID, scenarios: [webTrace, apiTrace])
        )
        XCTAssertTrue(mixedHTML.contains(#"data-report-mode="hybrid""#))
        XCTAssertTrue(mixedHTML.contains(#""scenarioKind":"web""#))
        XCTAssertTrue(mixedHTML.contains(#""scenarioKind":"api""#))
        XCTAssertTrue(mixedHTML.contains(#""apiCallCount":1"#))
    }

    func testPlaywrightTraceZipExtractionCapturesWebScreenshotsDOMAndAPIPayloads() throws {
        guard let nodePath = NodeToolchainResolver.findExecutable(
            named: "node",
            in: NodeToolchainResolver.buildSearchPath()
        ) else {
            throw XCTSkip("Node.js not available on host")
        }

        let workDir = try makeTempDir("pw-zip-extract")
        let traceDir = workDir.appendingPathComponent("traces", isDirectory: true)
        try FileManager.default.createDirectory(at: traceDir, withIntermediateDirectories: true)

        guard let reporterURL = PlaywrightTimeTravelReporterLoader.ensureReporterFileURL(baseDirectory: workDir) else {
            XCTFail("Failed to materialize Playwright reporter")
            return
        }

        // Build a valid DEFLATE ZIP matching Playwright's trace.zip schema and feed it to the reporter
        let driverJS = """
        const fs = require('node:fs');
        const path = require('node:path');
        const zlib = require('node:zlib');
        const Reporter = require(\(CommandBuilder.shellSingleQuote(reporterURL.path)));

        // Minimal zero-dep ZIP writer (DEFLATE) to synthesize a real Playwright trace.zip
        const crcTable = new Uint32Array(256);
        for (let n = 0; n < 256; n++) {
          let c = n;
          for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
          crcTable[n] = c >>> 0;
        }
        function crc32(buf) {
          let c = 0xffffffff;
          for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
          return (c ^ 0xffffffff) >>> 0;
        }
        function writeZip(outPath, files) {
          const locals = [];
          const centrals = [];
          let offset = 0;
          for (const [name, data] of Object.entries(files)) {
            const raw = Buffer.isBuffer(data) ? data : Buffer.from(data, 'utf8');
            const comp = zlib.deflateRawSync(raw);
            const nameBuf = Buffer.from(name, 'utf8');
            const crc = crc32(raw);

            const lh = Buffer.alloc(30);
            lh.writeUInt32LE(0x04034b50, 0);
            lh.writeUInt16LE(20, 4);
            lh.writeUInt16LE(8, 8);
            lh.writeUInt32LE(crc, 14);
            lh.writeUInt32LE(comp.length, 18);
            lh.writeUInt32LE(raw.length, 22);
            lh.writeUInt16LE(nameBuf.length, 26);
            locals.push(lh, nameBuf, comp);

            const ch = Buffer.alloc(46);
            ch.writeUInt32LE(0x02014b50, 0);
            ch.writeUInt16LE(20, 4);
            ch.writeUInt16LE(20, 6);
            ch.writeUInt16LE(8, 10);
            ch.writeUInt32LE(crc, 16);
            ch.writeUInt32LE(comp.length, 20);
            ch.writeUInt32LE(raw.length, 24);
            ch.writeUInt16LE(nameBuf.length, 28);
            ch.writeUInt32LE(offset, 42);
            centrals.push(ch, nameBuf);

            offset += lh.length + nameBuf.length + comp.length;
          }
          const cdBuf = Buffer.concat(centrals);
          const eocd = Buffer.alloc(22);
          eocd.writeUInt32LE(0x06054b50, 0);
          eocd.writeUInt16LE(Object.keys(files).length, 8);
          eocd.writeUInt16LE(Object.keys(files).length, 10);
          eocd.writeUInt32LE(cdBuf.length, 12);
          eocd.writeUInt32LE(offset, 16);
          fs.writeFileSync(outPath, Buffer.concat([...locals, cdBuf, eocd]));
        }

        const baseMs = Date.now();
        const tinyJpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0xff, 0xd9]);

        // 1. Web trace.zip with screencast-frame, frame-snapshot, input box, and browser network
        const webZip = path.join(\(CommandBuilder.shellSingleQuote(workDir.path)), 'web-trace.zip');
        const webTraceNDJSON = [
          JSON.stringify({ type: 'context-options', wallTime: baseMs, monotonicTime: 100, options: { viewport: { width: 1280, height: 720 } } }),
          JSON.stringify({ type: 'before', callId: 'call@1', apiName: 'page.goto', startTime: 110, wallTime: baseMs + 10, params: { url: 'https://playwright.dev/' } }),
          JSON.stringify({ type: 'screencast-frame', file: 'screencast/page@1-1.jpeg', width: 1280, height: 720, timestamp: 220, frameSwapWallTime: baseMs + 120 }),
          JSON.stringify({ type: 'frame-snapshot', snapshot: { callId: 'call@1', snapshotName: 'after@call@1', frameUrl: 'https://playwright.dev/', timestamp: 225, html: ['HTML', {}, ['HEAD', {}, ['TITLE', {}, 'Playwright']], ['BODY', {}, ['H1', { id: 'hero' }, 'Fast and reliable']]] } }),
          JSON.stringify({ type: 'after', callId: 'call@1', endTime: 240 }),
          JSON.stringify({ type: 'before', callId: 'call@2', apiName: 'locator.click', startTime: 260, wallTime: baseMs + 160, params: { selector: 'a.get-started' } }),
          JSON.stringify({ type: 'input', callId: 'call@2', box: { x: 100, y: 200, width: 140, height: 42 } }),
          JSON.stringify({ type: 'screencast-frame', file: 'screencast/page@1-2.jpeg', width: 1280, height: 720, timestamp: 320, frameSwapWallTime: baseMs + 220 }),
          JSON.stringify({ type: 'after', callId: 'call@2', endTime: 330 })
        ].join('\\n');
        const webNetworkNDJSON = JSON.stringify({
          type: 'resource-snapshot',
          snapshot: {
            startedDateTime: new Date(baseMs + 20).toISOString(),
            time: 85,
            request: { method: 'GET', url: 'https://playwright.dev/', headers: [{ name: 'Accept', value: 'text/html' }] },
            response: { status: 200, statusText: 'OK', headers: [{ name: 'content-type', value: 'text/html' }], content: { size: 512, mimeType: 'text/html' } }
          }
        });
        writeZip(webZip, {
          '1-trace.trace': webTraceNDJSON,
          '1-trace.network': webNetworkNDJSON,
          'screencast/page@1-1.jpeg': tinyJpeg,
          'screencast/page@1-2.jpeg': tinyJpeg
        });

        // 2. API trace.zip with _apiRequestRef, resources/*.json body, and timings
        const apiZip = path.join(\(CommandBuilder.shellSingleQuote(workDir.path)), 'api-trace.zip');
        const apiBody = JSON.stringify({ id: 1, title: 'delectus aut autem', completed: false });
        const apiNetworkNDJSON = JSON.stringify({
          type: 'resource-snapshot',
          snapshot: {
            _apiRequestRef: 'request@1',
            startedDateTime: new Date(baseMs + 1010).toISOString(),
            time: 94,
            request: {
              method: 'GET',
              url: 'https://jsonplaceholder.typicode.com/todos/1',
              headers: [
                { name: 'Authorization', value: 'Bearer super-secret' },
                { name: 'Accept', value: 'application/json' }
              ]
            },
            response: {
              status: 200,
              statusText: 'OK',
              headers: [{ name: 'content-type', value: 'application/json' }],
              content: { size: apiBody.length, mimeType: 'application/json', _file: 'resources/todo1.json' }
            },
            timings: { dns: 4, connect: 12, ssl: 18, wait: 52, receive: 8 }
          }
        });
        writeZip(apiZip, {
          '0-trace.network': apiNetworkNDJSON,
          'resources/todo1.json': apiBody
        });

        const rep = new Reporter();
        rep.onBegin({ projects: [{ name: 'chromium' }] });

        // Run Web Test
        const webTest = {
          title: 'opens home @web',
          tags: ['@web'],
          location: { file: '/repo/tests/example.spec.ts', line: 5, column: 3 },
          titlePath: () => ['', 'chromium', 'tests/example.spec.ts', 'Docs', 'opens home @web'],
          parent: { project: () => ({ name: 'chromium' }) }
        };
        rep.onTestBegin(webTest, { startTime: new Date(baseMs) });
        const noisyHook = { title: 'Before Hooks', category: 'hook', startTime: new Date(baseMs), duration: 2 };
        rep.onStepBegin(webTest, {}, noisyHook);
        rep.onStepEnd(webTest, {}, noisyHook);
        const wStep1 = { title: 'Navigate to "https://playwright.dev/"', category: 'pw:api', startTime: new Date(baseMs + 10), duration: 130 };
        rep.onStepBegin(webTest, {}, wStep1);
        rep.onStepEnd(webTest, {}, wStep1);
        const wStep2 = { title: "Click locator('a.get-started')", category: 'pw:api', startTime: new Date(baseMs + 160), duration: 70 };
        rep.onStepBegin(webTest, {}, wStep2);
        rep.onStepEnd(webTest, {}, wStep2);
        rep.onTestEnd(webTest, {
          status: 'passed',
          duration: 250,
          startTime: new Date(baseMs),
          attachments: [{ name: 'trace', contentType: 'application/zip', path: webZip }]
        });

        // Run API Test
        const apiTest = {
          title: 'fetches todo @api',
          tags: ['@api'],
          location: { file: '/repo/tests/api.spec.ts', line: 5, column: 3 },
          titlePath: () => ['', 'chromium', 'tests/api.spec.ts', 'API', 'fetches todo @api'],
          parent: { project: () => ({ name: 'chromium' }) }
        };
        rep.onTestBegin(apiTest, { startTime: new Date(baseMs + 1000) });
        const aStep1 = { title: 'GET "/todos/1"', category: 'pw:api', startTime: new Date(baseMs + 1005), duration: 110 };
        rep.onStepBegin(apiTest, {}, aStep1);
        rep.onStepEnd(apiTest, {}, aStep1);
        const aStep2 = { title: 'Expect "toBeOK"', category: 'expect', startTime: new Date(baseMs + 1120), duration: 2 };
        rep.onStepBegin(apiTest, {}, aStep2);
        rep.onStepEnd(apiTest, {}, aStep2);
        rep.onTestEnd(apiTest, {
          status: 'passed',
          duration: 130,
          startTime: new Date(baseMs + 1000),
          attachments: [{ name: 'trace', contentType: 'application/zip', path: apiZip }]
        });
        rep.onEnd({ status: 'passed' });
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
        XCTAssertEqual(traces.count, 2)

        // Verify Web test trace extraction & noisy hook filtering
        let web = traces[0]
        XCTAssertEqual(web.featureTitle, "[chromium] Docs")
        XCTAssertEqual(web.steps.count, 2, "Passing Before Hooks wrapper should be filtered out")
        XCTAssertTrue(web.steps[0].diagnostics?.afterScreenshotDataURI?.hasPrefix("data:image/jpeg;base64,") == true)
        XCTAssertEqual(web.steps[0].diagnostics?.domSnapshot?.title, "Playwright")
        XCTAssertTrue(web.steps[0].diagnostics?.domSnapshot?.html.contains("Fast and reliable") == true)
        XCTAssertEqual(web.steps[0].diagnostics?.networkRequests.first?.source, "playwright-browser")
        XCTAssertEqual(web.steps[1].diagnostics?.domSnapshot?.targetBoundingBox?.x, 100)
        XCTAssertEqual(web.steps[1].diagnostics?.domSnapshot?.targetBoundingBox?.viewportWidth, 1280)

        // Verify API test trace extraction, redaction, timings, and assertion linking
        let api = traces[1]
        XCTAssertEqual(api.featureTitle, "[chromium] API")
        XCTAssertEqual(api.steps.count, 2)
        let req = api.steps[0].diagnostics?.networkRequests.first
        XCTAssertEqual(req?.source, "playwright-api")
        XCTAssertEqual(req?.resourceType, "api")
        XCTAssertEqual(req?.status, 200)
        XCTAssertEqual(req?.requestHeaders["Authorization"], "[REDACTED]")
        XCTAssertEqual(req?.timings?.ttfbMs, 52)
        XCTAssertTrue(req?.responseBody?.contains("delectus aut autem") == true)
        XCTAssertEqual(api.steps[1].diagnostics?.assertion?.method, "toBeOK")
        XCTAssertEqual(api.steps[1].diagnostics?.assertion?.relatedRequestId, req?.id)

        // Verify mixed HTML report mode & per-scenario classification
        let reportID = UUID()
        let report = TestRunReport(
            id: reportID,
            projectPath: workDir.path,
            projectName: "pw-e2e",
            label: "Full Suite",
            commandLine: "playwright test",
            startedAt: Date(),
            finishedAt: Date(),
            exitCode: 0,
            passedCount: 2,
            failedCount: 0,
            skippedCount: 0,
            durationMs: 380,
            scenarios: traces,
            rawOutput: ""
        )
        let html = TimeTravelHTMLReportBuilder.build(report, traceBundle: TimeTravelTraceBundle(reportID: reportID, scenarios: traces))
        XCTAssertTrue(html.contains(#"data-report-mode="hybrid""#))
        XCTAssertTrue(html.contains(#""scenarioKind":"web""#))
        XCTAssertTrue(html.contains(#""scenarioKind":"api""#))
        XCTAssertTrue(html.contains("delectus aut autem"))
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

    func testPlaywrightCallbackArgsAndMemberDotCompletions() {
        // 1. Destructured Playwright fixture argument completion inside `async ({ ... })`
        let fixtureSrc = "import { test, expect } from '@playwright/test';\ntest('fetches a todo resource', async ({ req"
        XCTAssertTrue(IntelliSenseEngine.isInsideCallbackArgList("test('fetches a todo resource', async ({ req"))
        XCTAssertTrue(IntelliSenseEngine.isInsideCallbackArgList("test('fetches a todo resource', async ({ "))
        XCTAssertFalse(IntelliSenseEngine.isInsideCallbackArgList("expect(payload).toMatchObject({ id"))
        let rFixture = IntelliSenseEngine.completions(
            in: fixtureSrc,
            cursorUTF16Offset: (fixtureSrc as NSString).length,
            language: "typescript",
            sourceFileURL: nil,
            workspace: nil,
            index: WorkspaceCompletionIndex()
        )
        XCTAssertEqual(rFixture?.items.first?.label, "request")

        // 2. Empty `{ ` offers full Playwright fixture args (`page`, `request`, `context`, `browser`, ...)
        let emptyFixtureSrc = "import { test } from '@playwright/test';\ntest('api', async ({ "
        let rEmptyFixture = IntelliSenseEngine.completions(
            in: emptyFixtureSrc,
            cursorUTF16Offset: (emptyFixtureSrc as NSString).length,
            language: "typescript",
            sourceFileURL: nil,
            workspace: nil,
            index: WorkspaceCompletionIndex()
        )
        XCTAssertTrue(rEmptyFixture?.items.contains(where: { $0.label == "request" }) == true)
        XCTAssertTrue(rEmptyFixture?.items.contains(where: { $0.label == "page" }) == true)
        XCTAssertTrue(rEmptyFixture?.items.contains(where: { $0.label == "context" }) == true)
        XCTAssertTrue(rEmptyFixture?.items.contains(where: { $0.label == "browser" }) == true)

        // 3. 2nd callback argument suggests `testInfo`
        let secondParamSrc = "import { test } from '@playwright/test';\ntest('api', async ({ request }, te"
        let rSecond = IntelliSenseEngine.completions(
            in: secondParamSrc,
            cursorUTF16Offset: (secondParamSrc as NSString).length,
            language: "typescript",
            sourceFileURL: nil,
            workspace: nil,
            index: WorkspaceCompletionIndex()
        )
        XCTAssertEqual(rSecond?.items.first?.label, "testInfo")

        // 4. Typing `req` in test body completes destructured `request` arg, and `request.` lists HTTP methods
        let bodyIdentSrc = """
        import { test, expect } from '@playwright/test';
        test('fetches a todo resource', async ({ request }) => {
          await req
        """
        let rBodyIdent = IntelliSenseEngine.completions(
            in: bodyIdentSrc,
            cursorUTF16Offset: (bodyIdentSrc as NSString).length,
            language: "typescript",
            sourceFileURL: nil,
            workspace: nil,
            index: WorkspaceCompletionIndex()
        )
        XCTAssertTrue(rBodyIdent?.items.contains(where: { $0.label == "request" }) == true)

        let reqDotSrc = """
        import { test, expect } from '@playwright/test';
        test('fetches a todo resource', async ({ request }) => {
          await request.
        """
        let rReqDot = IntelliSenseEngine.completions(
            in: reqDotSrc,
            cursorUTF16Offset: (reqDotSrc as NSString).length,
            language: "typescript",
            sourceFileURL: nil,
            workspace: nil,
            index: WorkspaceCompletionIndex()
        )
        XCTAssertTrue(rReqDot?.items.contains(where: { $0.label == "get" }) == true)
        XCTAssertTrue(rReqDot?.items.contains(where: { $0.label == "post" }) == true)
        XCTAssertTrue(rReqDot?.items.contains(where: { $0.label == "delete" }) == true)

        // 5. Aliased destructured args (`{ request: api, context: ctx }, info`) + inferred APIResponse (`res.`)
        let aliasSrc = """
        import { test } from '@playwright/test';
        test('aliased', async ({ request: api, context: ctx }, info) => {
          const res = await api.get('/todos/1');
          api.
        """
        let rAlias = IntelliSenseEngine.completions(
            in: aliasSrc,
            cursorUTF16Offset: (aliasSrc as NSString).length,
            language: "typescript",
            sourceFileURL: nil,
            workspace: nil,
            index: WorkspaceCompletionIndex()
        )
        XCTAssertTrue(rAlias?.items.contains(where: { $0.label == "get" }) == true)

        let resSrc = """
        import { test } from '@playwright/test';
        test('aliased', async ({ request: api }, info) => {
          const res = await api.get('/todos/1');
          await res.
        """
        let rRes = IntelliSenseEngine.completions(
            in: resSrc,
            cursorUTF16Offset: (resSrc as NSString).length,
            language: "typescript",
            sourceFileURL: nil,
            workspace: nil,
            index: WorkspaceCompletionIndex()
        )
        XCTAssertTrue(rRes?.items.contains(where: { $0.label == "json" }) == true)
        XCTAssertTrue(rRes?.items.contains(where: { $0.label == "status" }) == true)
        XCTAssertTrue(rRes?.items.contains(where: { $0.label == "ok" }) == true)

        let infoSrc = """
        import { test } from '@playwright/test';
        test('meta', async ({ context: ctx }, info) => {
          info.
        """
        let rInfo = IntelliSenseEngine.completions(
            in: infoSrc,
            cursorUTF16Offset: (infoSrc as NSString).length,
            language: "typescript",
            sourceFileURL: nil,
            workspace: nil,
            index: WorkspaceCompletionIndex()
        )
        XCTAssertTrue(rInfo?.items.contains(where: { $0.label == "attach" }) == true)
        XCTAssertTrue(rInfo?.items.contains(where: { $0.label == "title" }) == true)

        let ctxSrc = """
        import { test } from '@playwright/test';
        test('meta', async ({ context: ctx }) => {
          await ctx.
        """
        let rCtx = IntelliSenseEngine.completions(
            in: ctxSrc,
            cursorUTF16Offset: (ctxSrc as NSString).length,
            language: "typescript",
            sourceFileURL: nil,
            workspace: nil,
            index: WorkspaceCompletionIndex()
        )
        XCTAssertTrue(rCtx?.items.contains(where: { $0.label == "newPage" }) == true)
        XCTAssertTrue(rCtx?.items.contains(where: { $0.label == "cookies" }) == true)
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
