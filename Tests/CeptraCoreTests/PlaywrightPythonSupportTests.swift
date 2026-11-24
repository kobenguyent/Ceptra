import CeptraCore
import Foundation
import XCTest

final class PlaywrightPythonSupportTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir(_ suffix: String = "pw-py") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceptra-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    // MARK: - 1. Config Discovery, Sample Workspace & Polyglot Monorepo Resolution

    func testDiscoversAndParsesSamplePlaywrightPythonWorkspace() throws {
        let root = try makeTempDir("pw-py-sample")
        try ProjectScaffolder.createSamplePlaywrightPythonWorkspace(at: root)

        // Create a decoy .venv directory to verify Scanner & ConfigParser ignore virtualenvs completely
        let venvTests = root.appendingPathComponent(".venv/lib/python3.12/site-packages/pytest_playwright", isDirectory: true)
        try FileManager.default.createDirectory(at: venvTests, withIntermediateDirectories: true)
        try "def test_should_be_ignored(page):\n    pass\n".write(
            to: venvTests.appendingPathComponent("test_internal.py"),
            atomically: true,
            encoding: .utf8
        )

        let discovered = ConfigParser.discoverConfigFiles(in: root)
        XCTAssertTrue(discovered.contains(where: { $0.lastPathComponent == "pytest.ini" }))
        XCTAssertFalse(discovered.contains(where: { $0.path.contains(".venv") }))

        let workspace = WorkspaceScanner.scan(rootURL: root)
        XCTAssertEqual(workspace.config.framework, .playwrightPython)
        XCTAssertTrue(workspace.config.framework.isPlaywrightFamily)
        XCTAssertTrue(workspace.config.framework.isPython)
        XCTAssertEqual(workspace.config.baseURL, "https://playwright.dev")
        XCTAssertEqual(workspace.config.outputDirectory, "test-results")
        XCTAssertTrue(workspace.config.playwrightProjects.contains("chromium"))
        XCTAssertEqual(workspace.config.packageCodeceptVersion, "0.7.0")

        // Verify test files, tags, page objects, conftest, and venv exclusion
        XCTAssertEqual(workspace.testFiles.count, 2)
        XCTAssertFalse(workspace.files.contains(where: { $0.relativePath.contains(".venv") }))
        XCTAssertTrue(workspace.allTags.contains("@smoke"))
        XCTAssertTrue(workspace.allTags.contains("@web"))
        XCTAssertTrue(workspace.allTags.contains("@api"))
        XCTAssertTrue(workspace.supportFiles.contains(where: { $0.name == "home_page.py" && $0.category == .pageObject }))
        XCTAssertTrue(workspace.configAndHelperFiles.contains(where: { $0.name == "conftest.py" && $0.category == .helper }))

        // Verify pytest.ini configures pythonpath = . for `from pages.home_page import HomePage`
        let iniText = try String(contentsOf: root.appendingPathComponent("pytest.ini"), encoding: .utf8)
        XCTAssertTrue(iniText.contains("pythonpath = ."))

        // Verify PackageManagerSupport bootstraps `.venv` cleanly when no venv exists yet
        let emptyProject = try makeTempDir("pw-py-novenv")
        try ProjectScaffolder.createSamplePlaywrightPythonWorkspace(at: emptyProject)
        let freshTc = NodeToolchainResolver.resolve(workspaceRoot: emptyProject, framework: .playwrightPython)
        let installCmd = PackageManagerSupport.buildCommand(
            action: .install,
            packageManager: .npm,
            workspaceRoot: emptyProject,
            toolchain: freshTc
        )
        XCTAssertTrue(installCmd.displayCommand.contains("-m venv .venv"))
        XCTAssertTrue(installCmd.displayCommand.contains("-r requirements.txt"))
    }

    func testPolyglotMonorepoResolvesCodeceptPlaywrightTSAndPlaywrightPythonPerFile() throws {
        let root = try makeTempDir("polyglot-monorepo")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("e2e-codecept/tests"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("e2e-pw-ts/specs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("e2e-pw-py/tests"), withIntermediateDirectories: true)

        try """
        export const config = {
          name: 'codecept-suite',
          tests: './tests/*_test.ts',
          output: './output',
          helpers: { REST: { endpoint: 'http://localhost:3000' } }
        };
        """.write(to: root.appendingPathComponent("e2e-codecept/codecept.conf.ts"), atomically: true, encoding: .utf8)
        try "Feature('Health');\nScenario('ok', async ({ I }) => { await I.sendGetRequest('/health'); });\n"
            .write(to: root.appendingPathComponent("e2e-codecept/tests/health_test.ts"), atomically: true, encoding: .utf8)

        try """
        import { defineConfig } from '@playwright/test';
        export default defineConfig({ testDir: './specs', projects: [{ name: 'chromium' }] });
        """.write(to: root.appendingPathComponent("e2e-pw-ts/playwright.config.ts"), atomically: true, encoding: .utf8)
        try "import { test, expect } from '@playwright/test';\ntest('home', async ({ page }) => { await page.goto('/'); });\n"
            .write(to: root.appendingPathComponent("e2e-pw-ts/specs/home.spec.ts"), atomically: true, encoding: .utf8)

        try """
        [pytest]
        testpaths = tests
        addopts = --browser chromium --browser firefox
        """.write(to: root.appendingPathComponent("e2e-pw-py/pytest.ini"), atomically: true, encoding: .utf8)
        try "pytest-playwright>=0.7.0\n"
            .write(to: root.appendingPathComponent("e2e-pw-py/requirements.txt"), atomically: true, encoding: .utf8)
        try """
        from playwright.sync_api import Page, expect
        def test_python_home(page: Page):
            page.goto("/")
            expect(page).to_have_title("Home")
        """.write(to: root.appendingPathComponent("e2e-pw-py/tests/test_home.py"), atomically: true, encoding: .utf8)

        let ws = WorkspaceScanner.scan(rootURL: root)
        XCTAssertEqual(ws.discoveredConfigs.count, 3)

        let codeceptCfg = ws.resolvedConfig(forFilePath: "e2e-codecept/tests/health_test.ts")
        XCTAssertEqual(codeceptCfg.framework, .codeceptJS)

        let pwTSCfg = ws.resolvedConfig(forFilePath: "e2e-pw-ts/specs/home.spec.ts")
        XCTAssertEqual(pwTSCfg.framework, .playwright)

        let pwPyCfg = ws.resolvedConfig(forFilePath: "e2e-pw-py/tests/test_home.py")
        XCTAssertEqual(pwPyCfg.framework, .playwrightPython)
        XCTAssertEqual(pwPyCfg.playwrightProjects, ["chromium", "firefox"])
    }

    // MARK: - 2. Python Test File Parsing

    func testParsesPlaywrightPythonFunctionsClassesDecoratorsFixturesAndSteps() {
        let source = """
        import re
        import pytest
        from playwright.sync_api import Page, APIRequestContext, expect


        @pytest.fixture
        def signed_in_page(page: Page):
            page.goto("/login")
            page.get_by_label("Email").fill("qa@example.com")
            return page


        @pytest.mark.smoke
        @pytest.mark.web
        def test_checkout_flow(page: Page):
            page.goto("/shop")
            page.get_by_role("button", name="Add to cart").click()
            expect(page.get_by_text("1 item")).to_be_visible()


        @pytest.mark.skip(reason="Pending backend flag")
        def test_legacy_coupon(page: Page):
            page.goto("/coupon")


        class TestOrderAPI:
            @pytest.mark.api
            @pytest.mark.parametrize("order_id", [1, 2])
            async def test_get_order(self, api_request_context: APIRequestContext, order_id: int):
                res = await api_request_context.get(f"/orders/{order_id}")
                await expect(res).to_be_ok()
                assert res.status == 200
        """

        let features = TestFileParser.parse(content: source, filePath: "/repo/tests/test_checkout.py")
        XCTAssertEqual(features.count, 2)

        let moduleFeature = features[0]
        XCTAssertEqual(moduleFeature.hooks.count, 1)
        XCTAssertEqual(moduleFeature.hooks[0].kind, "fixture(signed_in_page)")
        XCTAssertEqual(moduleFeature.scenarios.count, 2)

        let checkout = moduleFeature.scenarios[0]
        XCTAssertEqual(checkout.cleanTitle, "test_checkout_flow")
        XCTAssertTrue(checkout.tags.contains("@smoke"))
        XCTAssertTrue(checkout.tags.contains("@web"))
        XCTAssertEqual(checkout.modifier, .standard)
        XCTAssertGreaterThanOrEqual(checkout.steps.count, 3)
        XCTAssertEqual(checkout.steps[0].category, .navigation)
        XCTAssertEqual(checkout.steps[1].category, .interaction)
        XCTAssertEqual(checkout.steps[2].category, .assertion)

        let skipped = moduleFeature.scenarios[1]
        XCTAssertEqual(skipped.cleanTitle, "test_legacy_coupon")
        XCTAssertEqual(skipped.modifier, .skip)

        let classFeature = features[1]
        XCTAssertEqual(classFeature.title, "TestOrderAPI")
        XCTAssertEqual(classFeature.scenarios.count, 1)
        XCTAssertEqual(classFeature.scenarios[0].cleanTitle, "test_get_order")
        XCTAssertTrue(classFeature.scenarios[0].tags.contains("@api"))
        XCTAssertEqual(classFeature.scenarios[0].modifier, .dataDriven)
        XCTAssertTrue(classFeature.scenarios[0].steps.contains(where: { $0.category == .network }))
        XCTAssertTrue(classFeature.scenarios[0].steps.contains(where: { $0.category == .assertion }))
    }

    // MARK: - 3. Python Toolchain Resolution & Command Building

    func testResolvesVenvPytestAndPlaywrightCLI() throws {
        let root = try makeTempDir("pw-py-venv")
        let venvBin = root.appendingPathComponent(".venv/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: venvBin, withIntermediateDirectories: true)

        let fakePython = venvBin.appendingPathComponent("python")
        let fakePytest = venvBin.appendingPathComponent("pytest")
        let fakePlaywright = venvBin.appendingPathComponent("playwright")
        for script in [fakePython, fakePytest, fakePlaywright] {
            try "#!/bin/sh\necho ok\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }

        let tc = NodeToolchainResolver.resolve(workspaceRoot: root, framework: .playwrightPython)
        XCTAssertEqual(tc.framework, .playwrightPython)
        XCTAssertEqual(tc.runnerExecutable, fakePytest.path)
        XCTAssertEqual(tc.pythonPath, fakePython.path)
        XCTAssertTrue(tc.resolutionSource.contains(".venv"))
        XCTAssertTrue(tc.isActiveRuntimeAvailable)

        let cli = NodeToolchainResolver.resolvePlaywrightPythonCLI(toolchain: tc)
        XCTAssertEqual(cli.executable, fakePlaywright.path)
        XCTAssertTrue(cli.prefixArguments.isEmpty)

        // Custom Python path override
        let customTc = NodeToolchainResolver.resolve(
            workspaceRoot: root,
            framework: .playwrightPython,
            customPythonPath: fakePython.path
        )
        XCTAssertEqual(customTc.runnerExecutable, fakePython.path)
        XCTAssertEqual(customTc.prefixArguments, ["-m", "pytest"])
        XCTAssertTrue(customTc.resolutionSource.lowercased().contains("custom python"))
    }

    func testBuildsPytestPlaywrightCommandsWithTimeTravelAndZeroColorWarning() throws {
        let root = try makeTempDir("pw-py-cmd")
        let traceDir = root.appendingPathComponent(".ceptra-traces/run1", isDirectory: true)
        let configPath = root.appendingPathComponent("pytest.ini").path
        let tc = ResolvedToolchain(
            framework: .playwrightPython,
            runtime: .node,
            nodePath: nil,
            bunPath: nil,
            pythonPath: "/opt/venv/bin/python",
            codeceptExecutable: "/opt/venv/bin/pytest",
            prefixArguments: [],
            searchPath: "/opt/venv/bin:/usr/bin:/bin",
            resolutionSource: "local .venv"
        )

        var opts = RunOptions()
        opts.playwrightHeaded = true
        opts.bailOnFail = true
        opts.playwrightSelectedProjects = ["firefox"]
        opts.timeTravelTrace = true
        opts.playwrightTraceMode = .on

        // 1. Single scenario run with Time-Travel plugin
        let scenarioCmd = CommandBuilder.build(
            mode: .runScenario(relativePath: "tests/test_example.py", scenarioTitle: "test_has_title"),
            options: opts,
            workspaceRoot: root,
            configFilePath: configPath,
            toolchain: tc,
            framework: .playwrightPython,
            traceOutputDirectory: traceDir
        )
        XCTAssertEqual(scenarioCmd.executablePath, "/opt/venv/bin/pytest")
        XCTAssertTrue(scenarioCmd.arguments.contains("tests/test_example.py"))
        XCTAssertTrue(scenarioCmd.arguments.contains("-v"))
        XCTAssertTrue(scenarioCmd.arguments.contains("--color=no"))
        XCTAssertTrue(scenarioCmd.arguments.contains("-k"))
        XCTAssertTrue(scenarioCmd.arguments.contains("test_has_title"))
        XCTAssertTrue(scenarioCmd.arguments.contains("--headed"))
        XCTAssertTrue(scenarioCmd.arguments.contains("-x"))
        XCTAssertTrue(scenarioCmd.arguments.contains("--browser"))
        XCTAssertTrue(scenarioCmd.arguments.contains("firefox"))
        XCTAssertTrue(scenarioCmd.arguments.contains("--tracing=on"))
        XCTAssertTrue(scenarioCmd.arguments.contains("-p"))
        XCTAssertTrue(scenarioCmd.arguments.contains(PlaywrightPythonTimeTravelLoader.pluginModuleName))
        XCTAssertEqual(scenarioCmd.environment["CEPTRA_TIME_TRAVEL_DIR"], traceDir.path)
        XCTAssertEqual(scenarioCmd.environment["PYTHONUNBUFFERED"], "1")
        XCTAssertNotNil(scenarioCmd.environment["PYTHONPATH"])
        // Never set both FORCE_COLOR and NO_COLOR
        XCTAssertEqual(scenarioCmd.environment["FORCE_COLOR"], "0")
        XCTAssertNil(scenarioCmd.environment["NO_COLOR"])

        // 2. Tag/marker run (`-m`)
        let tagCmd = CommandBuilder.build(
            mode: .runTag(tag: "@smoke"),
            options: RunOptions(),
            workspaceRoot: root,
            configFilePath: configPath,
            toolchain: tc,
            framework: .playwrightPython
        )
        XCTAssertTrue(tagCmd.arguments.contains("-m"))
        XCTAssertTrue(tagCmd.arguments.contains("smoke"))

        // 3. Parallel workers (`-n 4`) & last failed (`--lf`)
        let workersCmd = CommandBuilder.build(
            mode: .runWorkers(count: 4, strategy: .pool, selectedRuns: ["chromium", "webkit"], serialPattern: nil, lastFailed: true),
            options: RunOptions(),
            workspaceRoot: root,
            configFilePath: configPath,
            toolchain: tc,
            framework: .playwrightPython
        )
        XCTAssertTrue(workersCmd.arguments.contains("-n"))
        XCTAssertTrue(workersCmd.arguments.contains("4"))
        XCTAssertTrue(workersCmd.arguments.contains("--lf"))
        XCTAssertTrue(workersCmd.arguments.contains("chromium"))
        XCTAssertTrue(workersCmd.arguments.contains("webkit"))

        // 4. Dry run (`--co -q`)
        let dryCmd = CommandBuilder.build(
            mode: .dryRun(relativePath: nil),
            options: RunOptions(),
            workspaceRoot: root,
            configFilePath: configPath,
            toolchain: tc,
            framework: .playwrightPython
        )
        XCTAssertTrue(dryCmd.arguments.contains("--co"))
        XCTAssertTrue(dryCmd.arguments.contains("-q"))

        // 5. Codegen (`--target python-pytest`)
        let codegenCmd = CommandBuilder.build(
            mode: .playwrightCodegen(url: "https://playwright.dev"),
            options: RunOptions(),
            workspaceRoot: root,
            configFilePath: configPath,
            toolchain: tc,
            framework: .playwrightPython
        )
        XCTAssertTrue(codegenCmd.arguments.contains("codegen"))
        XCTAssertTrue(codegenCmd.arguments.contains("--target"))
        XCTAssertTrue(codegenCmd.arguments.contains("python-pytest"))
        XCTAssertTrue(codegenCmd.arguments.contains("https://playwright.dev"))
    }

    // MARK: - 4. Live pytest -v Output Parsing & 1:1 Deduplicated Trace Merge

    func testParsesPytestVerboseOutputAndDeduplicatesWithTraceRecords() {
        let lines = [
            "============================= test session starts ==============================",
            "collected 3 items",
            "tests/test_example.py::test_has_title[chromium] PASSED                   [ 33%]",
            "tests/test_example.py::TestAuth::test_invalid_login[firefox] FAILED      [ 66%]",
            "tests/test_api.py::test_fetches_todo SKIPPED                             [100%]",
            "==================== 1 failed, 1 passed, 1 skipped in 2.41s ===================="
        ]

        let parser = LiveOutputParser()
        var finished: [ExecutedScenarioRecord] = []
        var summary: (Int, Int, Int)? = nil

        for line in lines {
            for event in parser.feed(line: line, isStderr: false) {
                switch event {
                case .scenarioFinished(let rec):
                    finished.append(rec)
                case .summary(let p, let f, let s, _):
                    summary = (p, f, s)
                default:
                    break
                }
            }
        }

        XCTAssertEqual(finished.count, 3)
        XCTAssertEqual(finished[0].featureTitle, "[chromium] test_example")
        XCTAssertEqual(finished[0].scenarioTitle, "test_has_title")
        XCTAssertEqual(finished[0].status, .passed)

        XCTAssertEqual(finished[1].featureTitle, "[firefox] TestAuth")
        XCTAssertEqual(finished[1].scenarioTitle, "test_invalid_login")
        XCTAssertEqual(finished[1].status, .failed)

        XCTAssertEqual(finished[2].featureTitle, "test_api")
        XCTAssertEqual(finished[2].scenarioTitle, "test_fetches_todo")
        XCTAssertEqual(finished[2].status, .skipped)

        XCTAssertEqual(summary?.0, 1)
        XCTAssertEqual(summary?.1, 1)
        XCTAssertEqual(summary?.2, 1)

        // Verify 1:1 merge with matching trace scenarios creates zero duplicates
        let traceScenarios = [
            ExecutedScenarioRecord(
                featureTitle: "[chromium] test_example",
                scenarioTitle: "test_has_title",
                filePath: "tests/test_example.py",
                status: .passed,
                durationMs: 420,
                steps: [
                    ExecutedStepRecord(
                        text: "page.goto(\"https://playwright.dev\")",
                        status: .passed,
                        durationMs: 280,
                        diagnostics: TimeTravelStepDiagnostics(
                            pageURL: "https://playwright.dev",
                            afterScreenshotDataURI: "data:image/jpeg;base64,/9j/4AAQSkZJRg=="
                        )
                    )
                ]
            )
        ]

        let merged = TimeTravelTraceMerger.merge(
            primaryScenarios: finished,
            traceScenarios: traceScenarios,
            runStartedAt: Date()
        )
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].steps.count, 1)
        XCTAssertNotNil(merged[0].steps[0].diagnostics?.afterScreenshotDataURI)
    }

    // MARK: - 5. Live Python 3 Execution of Ceptra Pytest Plugin Against Real Synthesized trace.zip

    func testLivePythonPluginParsesRealTraceZipIntoHybridWebAndAPIReplayReport() throws {
        let pythonExec = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: pythonExec) else {
            throw XCTSkip("python3 not installed on host")
        }

        let root = try makeTempDir("pw-py-live")
        let pluginDir = try XCTUnwrap(PlaywrightPythonTimeTravelLoader.ensurePluginDirectoryURL(baseDirectory: root))
        let traceOutputDir = root.appendingPathComponent("ceptra-traces", isDirectory: true)
        let pwResultsDir = root.appendingPathComponent("test-results", isDirectory: true)
        try FileManager.default.createDirectory(at: traceOutputDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pwResultsDir, withIntermediateDirectories: true)

        // Drive ceptra_pw_time_travel.py directly in python3 using two realistic synthesized trace.zip archives:
        // 1) Web test with screencast JPEGs, DOM frame-snapshot, target bounding box, and console error
        // 2) API test with APIRequestContext `_apiRequestRef`, Authorization header redaction, and JSON response body
        let driverScript = #"""
        import json, os, sys, time, zipfile
        from pathlib import Path

        sys.path.insert(0, sys.argv[1])
        import ceptra_pw_time_travel as mod

        trace_out = sys.argv[2]
        pw_out = sys.argv[3]
        now_ms = int(time.time() * 1000)

        # 1. Build Web trace.zip
        web_dir = Path(pw_out) / "tests-test-example-py-test-has-title-chromium"
        web_dir.mkdir(parents=True, exist_ok=True)
        web_zip = web_dir / "trace.zip"
        with zipfile.ZipFile(web_zip, "w", zipfile.ZIP_DEFLATED) as zf:
            trace_lines = [
                json.dumps({"type": "context-options", "wallTime": now_ms, "monotonicTime": 100, "options": {"viewport": {"width": 1280, "height": 720}}}),
                json.dumps({"type": "screencast-frame", "sha1": "frame_before.jpeg", "timestamp": 110, "width": 1280, "height": 720}),
                json.dumps({"type": "before", "callId": "call@1", "startTime": 120, "apiName": "page.goto", "params": {"url": "https://playwright.dev/python"}, "beforeSnapshot": "snap@0"}),
                json.dumps({"type": "after", "callId": "call@1", "endTime": 300, "afterSnapshot": "snap@1"}),
                json.dumps({"type": "before", "callId": "call@2", "startTime": 310, "apiName": "locator.click", "params": {"selector": "role=link[name=\"Get started\"]"}, "beforeSnapshot": "snap@1"}),
                json.dumps({"type": "input", "callId": "call@2", "point": {"x": 240, "y": 180}}),
                json.dumps({"type": "console", "messageType": "warning", "text": "Hydration notice", "time": 340, "location": {"url": "https://playwright.dev/app.js", "lineNumber": 42}}),
                json.dumps({"type": "after", "callId": "call@2", "endTime": 420, "afterSnapshot": "snap@2"}),
                json.dumps({"type": "screencast-frame", "sha1": "frame_after.jpeg", "timestamp": 415, "width": 1280, "height": 720}),
                json.dumps({"type": "frame-snapshot", "snapshot": {
                    "snapshotName": "snap@2",
                    "frameUrl": "https://playwright.dev/python/docs/intro",
                    "html": ["HTML", {}, ["HEAD", {}, ["TITLE", {}, "Installation | Playwright Python"]], ["BODY", {}, ["H1", {"id": "install"}, "Installation"]]]
                }})
            ]
            zf.writestr("0-trace.trace", "\n".join(trace_lines))
            zf.writestr("resources/frame_before.jpeg", b"\xff\xd8\xff\xe0BEFORE_JPEG")
            zf.writestr("resources/frame_after.jpeg", b"\xff\xd8\xff\xe0AFTER_JPEG")

        # 2. Build API trace.zip
        api_dir = Path(pw_out) / "tests-test-api-py-test-fetches-todo"
        api_dir.mkdir(parents=True, exist_ok=True)
        api_zip = api_dir / "trace.zip"
        with zipfile.ZipFile(api_zip, "w", zipfile.ZIP_DEFLATED) as zf:
            api_trace_lines = [
                json.dumps({"type": "context-options", "wallTime": now_ms, "monotonicTime": 500, "options": {}}),
                json.dumps({"type": "before", "callId": "api@1", "startTime": 510, "apiName": "apiRequestContext.fetch", "params": {"method": "GET", "url": "https://jsonplaceholder.typicode.com/todos/1"}}),
                json.dumps({"type": "after", "callId": "api@1", "endTime": 620, "result": {"fetchUid": "req-uid-1"}}),
                json.dumps({"type": "before", "callId": "api@2", "startTime": 625, "apiName": "expect.toBeOK", "params": {}}),
                json.dumps({"type": "after", "callId": "api@2", "endTime": 630})
            ]
            api_net_lines = [
                json.dumps({
                    "type": "resource-snapshot",
                    "snapshot": {
                        "_apiRequestRef": "req-uid-1",
                        "startedDateTime": "2026-11-24T12:00:00.510Z",
                        "time": 110,
                        "request": {
                            "method": "GET",
                            "url": "https://jsonplaceholder.typicode.com/todos/1",
                            "headers": [
                                {"name": "Accept", "value": "application/json"},
                                {"name": "Authorization", "value": "Bearer super-secret-token"}
                            ]
                        },
                        "response": {
                            "status": 200,
                            "statusText": "OK",
                            "headers": [{"name": "Content-Type", "value": "application/json"}],
                            "content": {"_sha1": "todo1.json", "mimeType": "application/json", "size": 42}
                        },
                        "timings": {"dns": 5, "connect": 10, "ssl": 15, "wait": 65, "receive": 15}
                    }
                })
            ]
            zf.writestr("0-trace.trace", "\n".join(api_trace_lines))
            zf.writestr("0-trace.network", "\n".join(api_net_lines))
            zf.writestr("resources/todo1.json", json.dumps({"id": 1, "title": "ship python support", "completed": True}))

        # 3. Drive plugin lifecycle hooks
        class FakeMarker:
            def __init__(self, name):
                self.name = name

        class FakeItem:
            def __init__(self, nodeid, fspath, markers):
                self.nodeid = nodeid
                self.fspath = fspath
                self._markers = [FakeMarker(m) for m in markers]
            def iter_markers(self):
                return self._markers

        class FakeReport:
            def __init__(self, nodeid, when, outcome, duration=0.35):
                self.nodeid = nodeid
                self.when = when
                self.outcome = outcome
                self.passed = (outcome == "passed")
                self.failed = (outcome == "failed")
                self.skipped = (outcome == "skipped")
                self.duration = duration
                self.longrepr = None
                self.capstdout = ""
                self.capstderr = ""
                self.wasxfail = None

        plugin = mod.CeptraPytestPlaywrightPlugin(trace_out, pw_out)

        web_item = FakeItem("tests/test_example.py::test_has_title[chromium]", "tests/test_example.py", ["smoke", "web"])
        plugin.pytest_runtest_setup(web_item)
        plugin.pytest_runtest_logreport(FakeReport(web_item.nodeid, "call", "passed", 0.42))

        api_item = FakeItem("tests/test_api.py::test_fetches_todo", "tests/test_api.py", ["api"])
        plugin.pytest_runtest_setup(api_item)
        plugin.pytest_runtest_logreport(FakeReport(api_item.nodeid, "call", "passed", 0.14))

        plugin.pytest_sessionfinish(None, 0)
        print("OK")
        """#

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonExec)
        proc.arguments = ["-c", driverScript, pluginDir.path, traceOutputDir.path, pwResultsDir.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(proc.terminationStatus, 0, "Python driver failed: \(errStr)")

        // Load via Ceptra's native TimeTravelTraceMerger
        let loaded = TimeTravelTraceMerger.loadWorkerTraces(from: traceOutputDir)
        XCTAssertEqual(loaded.count, 2)

        // Verify Web scenario telemetry
        let webScenario = try XCTUnwrap(loaded.first(where: { $0.scenarioTitle == "test_has_title" }))
        XCTAssertEqual(webScenario.featureTitle, "[chromium] test_example")
        XCTAssertTrue(webScenario.tags.contains("@smoke"))
        XCTAssertTrue(webScenario.tags.contains("@web"))
        XCTAssertEqual(webScenario.steps.count, 2)

        let clickStep = webScenario.steps[1]
        XCTAssertTrue(clickStep.text.contains("locator.click"))
        XCTAssertNotNil(clickStep.diagnostics?.beforeScreenshotDataURI)
        XCTAssertNotNil(clickStep.diagnostics?.afterScreenshotDataURI)
        XCTAssertEqual(clickStep.diagnostics?.domSnapshot?.title, "Installation | Playwright Python")
        XCTAssertTrue(clickStep.diagnostics?.domSnapshot?.html.contains("<h1 id=\"install\">Installation</h1>") == true)
        XCTAssertNotNil(clickStep.diagnostics?.domSnapshot?.targetBoundingBox)
        XCTAssertEqual(clickStep.diagnostics?.consoleEntries.first?.level, .warn)

        // Verify API scenario telemetry + auth redaction + assertion linking
        let apiScenario = try XCTUnwrap(loaded.first(where: { $0.scenarioTitle == "test_fetches_todo" }))
        XCTAssertEqual(apiScenario.featureTitle, "test_api")
        XCTAssertEqual(apiScenario.steps.count, 2)

        let reqEntry = try XCTUnwrap(apiScenario.steps[0].diagnostics?.networkRequests.first)
        XCTAssertEqual(reqEntry.source, "playwright-python-api")
        XCTAssertTrue(reqEntry.isApiExchange)
        XCTAssertEqual(reqEntry.status, 200)
        XCTAssertEqual(reqEntry.requestHeaders["Authorization"], "[REDACTED]")
        XCTAssertEqual(reqEntry.requestHeaders["Accept"], "application/json")
        XCTAssertTrue(reqEntry.responseBody?.contains("ship python support") == true)
        XCTAssertEqual(reqEntry.timings?.ttfbMs, 65)

        let assertRec = try XCTUnwrap(apiScenario.steps[1].diagnostics?.assertion)
        XCTAssertTrue(assertRec.passed)
        XCTAssertTrue(assertRec.isApiAssertion)
        XCTAssertEqual(assertRec.relatedRequestId, reqEntry.id)

        // Build interactive HTML report and confirm Hybrid mode + Playwright (Py) copy button
        let report = TestRunReport(
            projectPath: root.path,
            projectName: "py-playwright-demo",
            label: "Run All Tests",
            commandLine: "pytest -v",
            startedAt: Date().addingTimeInterval(-1),
            finishedAt: Date(),
            exitCode: 0,
            passedCount: 2,
            failedCount: 0,
            skippedCount: 0,
            durationMs: 600,
            scenarios: loaded,
            rawOutput: "2 passed in 0.60s"
        )
        let bundle = TimeTravelTraceBundle(reportID: report.id, scenarios: loaded)
        let html = TimeTravelHTMLReportBuilder.build(report, traceBundle: bundle)
        XCTAssertTrue(html.contains("\"reportMode\":\"hybrid\""))
        XCTAssertTrue(html.contains("\"scenarioKind\":\"web\""))
        XCTAssertTrue(html.contains("\"scenarioKind\":\"api\""))
        XCTAssertTrue(html.contains("Playwright (Py)"))
        XCTAssertTrue(html.contains("buildPlaywrightPythonSnippet"))
        XCTAssertFalse(html.contains("super-secret-token"))
    }

    func testLivePythonPluginHydratesTeardownTraceZipWithPlaywright160DeltaDOMAndInProcessAPICapture() throws {
        let pythonExec = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: pythonExec) else {
            throw XCTSkip("python3 not installed on host")
        }

        let root = try makeTempDir("pw-py-teardown")
        let pluginDir = try XCTUnwrap(PlaywrightPythonTimeTravelLoader.ensurePluginDirectoryURL(baseDirectory: root))
        let traceOutputDir = root.appendingPathComponent("ceptra-traces", isDirectory: true)
        let pwResultsDir = root.appendingPathComponent("test-results", isDirectory: true)
        try FileManager.default.createDirectory(at: traceOutputDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pwResultsDir, withIntermediateDirectories: true)

        // Simulates REAL pytest-playwright 0.7 / Playwright 1.60 lifecycle:
        // - `trace.zip` DOES NOT EXIST during `call`; it is written during `teardown` fixture cleanup!
        // - Events use `class` + `method` (NO `apiName`), `BrowserContext.newPage` setup noise,
        //   incremental delta DOM refs `[[offset, nodeIdx]]`, and `__playwright_target__` attribute.
        // - Pure API test has NO `trace.zip`, only live in-process APIRequestContext + expect(res).to_be_ok() steps.
        let driverScript = #"""
        import json, os, sys, time, zipfile
        from pathlib import Path

        sys.path.insert(0, sys.argv[1])
        import ceptra_pw_time_travel as mod

        trace_out = sys.argv[2]
        pw_out = sys.argv[3]
        now_ms = int(time.time() * 1000)

        class FakeMarker:
            def __init__(self, name):
                self.name = name

        class FakeItem:
            def __init__(self, nodeid, fspath, markers):
                self.nodeid = nodeid
                self.fspath = fspath
                self._markers = [FakeMarker(m) for m in markers]
            def iter_markers(self):
                return self._markers

        class FakeReport:
            def __init__(self, nodeid, when, outcome, duration=0.35):
                self.nodeid = nodeid
                self.when = when
                self.outcome = outcome
                self.passed = (outcome == "passed")
                self.failed = (outcome == "failed")
                self.skipped = (outcome == "skipped")
                self.duration = duration
                self.longrepr = None
                self.capstdout = ""
                self.capstderr = ""
                self.wasxfail = None

        plugin = mod.CeptraPytestPlaywrightPlugin(trace_out, pw_out)

        # 1. Web test: call happens BEFORE trace.zip exists on disk!
        web_item = FakeItem("tests/test_example.py::test_has_title_and_opens_getting_started[chromium]", "tests/test_example.py", ["smoke", "web"])
        plugin.pytest_runtest_setup(web_item)
        plugin.pytest_runtest_logreport(FakeReport(web_item.nodeid, "call", "passed", 0.55))

        # Now simulate pytest-playwright `context` fixture teardown writing trace.zip AFTER call!
        web_dir = Path(pw_out) / "tests-test-example-py-test-has-title-and-opens-getting-started-chromium"
        web_dir.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(web_dir / "trace.zip", "w", zipfile.ZIP_DEFLATED) as zf:
            lines = [
                json.dumps({"type": "context-options", "wallTime": now_ms, "monotonicTime": 1000.0, "options": {"baseURL": "https://playwright.dev", "viewport": {"width": 1280, "height": 720}}}),
                json.dumps({"type": "before", "callId": "call@7", "class": "BrowserContext", "method": "newPage", "startTime": 1002.0, "params": {}}),
                json.dumps({"type": "after", "callId": "call@7", "endTime": 1020.0}),
                json.dumps({"type": "before", "callId": "call@9", "class": "Frame", "method": "goto", "startTime": 1025.0, "params": {"url": "/"}, "beforeSnapshot": "before@call@9"}),
                json.dumps({"type": "frame-snapshot", "snapshot": {
                    "snapshotName": "before@call@9", "frameId": "frame@main", "frameUrl": "about:blank", "timestamp": 1025.5,
                    "html": ["HTML", {}, ["HEAD", {}], ["BODY", {}]]
                }}),
                json.dumps({"type": "after", "callId": "call@9", "endTime": 1200.0, "afterSnapshot": "after@call@9"}),
                json.dumps({"type": "screencast-frame", "sha1": "shot_goto.jpeg", "timestamp": 1200.5, "frameSwapWallTime": now_ms + 199.0, "width": 1280, "height": 720}),
                json.dumps({"type": "frame-snapshot", "snapshot": {
                    "snapshotName": "after@call@9", "frameId": "frame@main", "frameUrl": "https://playwright.dev/", "timestamp": 1201.0,
                    "html": ["HTML", {}, ["HEAD", {}, ["TITLE", {}, "Fast and reliable | Playwright"]], ["BODY", {}, ["A", {"href": "/docs/intro", "__playwright_target__": "call@13"}, "Get started"]]]
                }}),
                json.dumps({"type": "before", "callId": "call@11", "class": "Frame", "method": "expect", "title": "Expect \"to_have_title\"", "startTime": 1210.0, "params": {"expression": "to.have.title", "expectedText": [{"regexSource": "Playwright"}]}}),
                json.dumps({"type": "after", "callId": "call@11", "endTime": 1225.0, "afterSnapshot": "after@call@11"}),
                # Root-level delta reference pointing to `HTML` (last node index 6) in previous snapshot `after@call@9` (offset 1)
                json.dumps({"type": "frame-snapshot", "snapshot": {
                    "snapshotName": "after@call@11", "frameId": "frame@main", "frameUrl": "https://playwright.dev/", "timestamp": 1225.5,
                    "html": [[1, 6]]
                }}),
                json.dumps({"type": "before", "callId": "call@13", "class": "Frame", "method": "click", "startTime": 1230.0, "params": {"selector": "internal:role=link[name=\"Get started\"i]"}}),
                json.dumps({"type": "input", "callId": "call@13", "point": {"x": 152.9, "y": 509.0}, "inputSnapshot": "input@call@13"}),
                # Subtree delta referencing `HEAD` (node index 2) from `after@call@9` (offset 2) while updating BODY
                json.dumps({"type": "frame-snapshot", "snapshot": {
                    "snapshotName": "input@call@13", "frameId": "frame@main", "frameUrl": "https://playwright.dev/", "timestamp": 1240.0,
                    "html": ["HTML", {}, [[2, 2]], ["BODY", {}, ["A", {"href": "/docs/intro", "__playwright_target__": "call@13"}, "Get started"]]]
                }}),
                json.dumps({"type": "after", "callId": "call@13", "endTime": 1255.0, "afterSnapshot": "after@call@13"}),
                json.dumps({"type": "screencast-frame", "sha1": "shot_click.jpeg", "timestamp": 1258.0, "frameSwapWallTime": now_ms + 258.0, "width": 1280, "height": 720}),
                json.dumps({"type": "frame-snapshot", "snapshot": {
                    "snapshotName": "after@call@13", "frameId": "frame@main", "frameUrl": "https://playwright.dev/docs/intro", "timestamp": 1260.0,
                    "html": ["HTML", {}, ["HEAD", {}, ["TITLE", {}, "Installation | Playwright"]], ["BODY", {}, ["H1", {}, "Installation"]]]
                }}),
                json.dumps({"type": "before", "callId": "call@15", "class": "Frame", "method": "expect", "title": "Expect \"to_be_visible\"", "startTime": 1262.0, "params": {"selector": "internal:role=heading[name=\"Installation\"i]", "expression": "to.be.visible"}}),
                json.dumps({"type": "after", "callId": "call@15", "endTime": 1290.0, "afterSnapshot": "after@call@15", "result": {"received": {"value": {"s": "visible"}, "ariaSnapshot": "- heading \"Installation\" [level=1]"}}}),
                json.dumps({"type": "screencast-frame", "sha1": "shot_final.jpeg", "timestamp": 1295.0, "frameSwapWallTime": now_ms + 295.0, "width": 1280, "height": 720}),
                json.dumps({"type": "frame-snapshot", "snapshot": {
                    "snapshotName": "after@call@15", "frameId": "frame@main", "frameUrl": "https://playwright.dev/docs/intro", "timestamp": 1291.0,
                    "html": [[1, 5]]
                }})
            ]
            zf.writestr("trace.trace", "\n".join(lines))
            zf.writestr("resources/shot_goto.jpeg", b"\xff\xd8\xff\xe0GOTO")
            zf.writestr("resources/shot_click.jpeg", b"\xff\xd8\xff\xe0CLICK")
            zf.writestr("resources/shot_final.jpeg", b"\xff\xd8\xff\xe0FINAL")

        # Fire PASSING teardown — plugin MUST hydrate trace.zip now!
        plugin.pytest_runtest_logreport(FakeReport(web_item.nodeid, "teardown", "passed", 0.05))

        # 2. Pure API test with NO trace.zip: record live steps directly via plugin._record_live_step
        api_item = FakeItem("tests/test_api.py::test_fetches_todo_resource", "tests/test_api.py", ["api"])
        plugin.pytest_runtest_setup(api_item)
        req_id = "live-api-req-1"
        req_diag = mod._empty_diagnostics()
        req_diag["networkRequests"].append({
            "id": req_id,
            "method": "GET",
            "url": "https://jsonplaceholder.typicode.com/todos/1",
            "resourceType": "api",
            "source": "playwright-python-api",
            "status": 200,
            "statusText": "OK",
            "startedAt": mod._iso_from_ms(now_ms + 400),
            "durationMs": 82,
            "requestSizeBytes": None,
            "responseSizeBytes": 54,
            "timings": {"dnsMs": None, "connectMs": None, "tlsMs": None, "ttfbMs": None, "downloadMs": None, "totalMs": 82},
            "requestHeaders": mod._redact_headers({"Accept": "application/json", "Authorization": "Bearer secret-api-key"}),
            "responseHeaders": {"content-type": "application/json"},
            "requestBody": None,
            "responseBody": json.dumps({"id": 1, "title": "delectus aut autem", "completed": False}),
            "errorText": None,
        })
        plugin._record_live_step({
            "text": "GET https://jsonplaceholder.typicode.com/todos/1",
            "depth": 0,
            "status": "passed",
            "durationMs": 82,
            "startedAt": mod._iso_from_ms(now_ms + 400),
            "finishedAt": mod._iso_from_ms(now_ms + 482),
            "targetSelector": None,
            "errorMessage": None,
            "diagnostics": req_diag,
        })
        assert_diag = mod._empty_diagnostics()
        assert_diag["assertion"] = {
            "method": "to_be_ok",
            "passed": True,
            "expected": "status in 200..299",
            "actual": "HTTP 200",
            "message": None,
            "relatedRequestId": req_id,
        }
        plugin._record_live_step({
            "text": "expect(response).to_be_ok()",
            "depth": 0,
            "status": "passed",
            "durationMs": 1,
            "startedAt": mod._iso_from_ms(now_ms + 483),
            "finishedAt": mod._iso_from_ms(now_ms + 484),
            "targetSelector": None,
            "errorMessage": None,
            "diagnostics": assert_diag,
        })
        plugin.pytest_runtest_logreport(FakeReport(api_item.nodeid, "call", "passed", 0.09))
        plugin.pytest_runtest_logreport(FakeReport(api_item.nodeid, "teardown", "passed", 0.01))
        plugin.pytest_sessionfinish(None, 0)
        print("OK")
        """#

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonExec)
        proc.arguments = ["-c", driverScript, pluginDir.path, traceOutputDir.path, pwResultsDir.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(proc.terminationStatus, 0, "Python teardown driver failed: \(errStr)")

        let loaded = TimeTravelTraceMerger.loadWorkerTraces(from: traceOutputDir)
        XCTAssertEqual(loaded.count, 2)

        // Verify Web scenario hydrated DURING teardown has 4 clean steps (BrowserContext.newPage filtered out!)
        let web = try XCTUnwrap(loaded.first(where: { $0.scenarioTitle == "test_has_title_and_opens_getting_started" }))
        XCTAssertEqual(web.steps.count, 4)
        XCTAssertEqual(web.steps[0].text, "page.goto(\"/\")")
        XCTAssertEqual(web.steps[0].diagnostics?.pageURL, "https://playwright.dev/")
        XCTAssertNotNil(web.steps[0].diagnostics?.afterScreenshotDataURI)
        XCTAssertEqual(web.steps[0].diagnostics?.domSnapshot?.title, "Fast and reliable | Playwright")

        // Step 2: delta root snapshot `[[1, 6]]` resolved completely!
        XCTAssertTrue(web.steps[1].text.contains("Expect \"to_have_title\""))
        XCTAssertEqual(web.steps[1].diagnostics?.assertion?.method, "to_have_title")
        XCTAssertEqual(web.steps[1].diagnostics?.assertion?.isApiAssertion, false)
        XCTAssertEqual(web.steps[1].diagnostics?.domSnapshot?.title, "Fast and reliable | Playwright")

        // Step 3: click with cleaned selector, bounding box, targetOuterHTML from inputSnapshot, before & after shots
        XCTAssertTrue(web.steps[2].text.contains("locator.click"))
        XCTAssertFalse(web.steps[2].text.contains("internal:"))
        XCTAssertNotNil(web.steps[2].diagnostics?.beforeScreenshotDataURI)
        XCTAssertNotNil(web.steps[2].diagnostics?.afterScreenshotDataURI)
        XCTAssertNotNil(web.steps[2].diagnostics?.domSnapshot?.targetBoundingBox)
        XCTAssertTrue(web.steps[2].diagnostics?.domSnapshot?.targetOuterHTML?.contains("Get started") == true)
        XCTAssertEqual(web.steps[2].diagnostics?.domSnapshot?.title, "Installation | Playwright")

        // Step 4: delta root snapshot `[[1, 5]]` resolved completely!
        XCTAssertTrue(web.steps[3].text.contains("Expect \"to_be_visible\""))
        XCTAssertEqual(web.steps[3].diagnostics?.assertion?.method, "to_be_visible")
        XCTAssertEqual(web.steps[3].diagnostics?.assertion?.actual, "visible")
        XCTAssertEqual(web.steps[3].diagnostics?.assertion?.isApiAssertion, false)
        XCTAssertTrue(web.steps[3].diagnostics?.domSnapshot?.html.contains("<h1>Installation</h1>") == true)

        // Verify pure API scenario captured without trace.zip!
        let api = try XCTUnwrap(loaded.first(where: { $0.scenarioTitle == "test_fetches_todo_resource" }))
        XCTAssertEqual(api.steps.count, 2)
        let apiReq = try XCTUnwrap(api.steps[0].diagnostics?.networkRequests.first)
        XCTAssertEqual(apiReq.source, "playwright-python-api")
        XCTAssertEqual(apiReq.status, 200)
        XCTAssertEqual(apiReq.requestHeaders["Authorization"], "[REDACTED]")
        XCTAssertTrue(apiReq.responseBody?.contains("delectus aut autem") == true)
        XCTAssertEqual(api.steps[1].diagnostics?.assertion?.relatedRequestId, apiReq.id)
        XCTAssertEqual(api.steps[1].diagnostics?.assertion?.isApiAssertion, true)

        // Build final HTML report and verify hybrid classification & zero leaked secret
        let report = TestRunReport(
            projectPath: root.path,
            projectName: "my-playwright-python-tests",
            label: "Run All Tests",
            commandLine: "pytest -v --tracing=on",
            startedAt: Date().addingTimeInterval(-1),
            finishedAt: Date(),
            exitCode: 0,
            passedCount: 2,
            failedCount: 0,
            skippedCount: 0,
            durationMs: 650,
            scenarios: loaded,
            rawOutput: "2 passed"
        )
        let html = TimeTravelHTMLReportBuilder.build(report, traceBundle: TimeTravelTraceBundle(reportID: report.id, scenarios: loaded))
        XCTAssertTrue(html.contains("\"reportMode\":\"hybrid\""))
        XCTAssertTrue(html.contains("\"scenarioKind\":\"web\""))
        XCTAssertTrue(html.contains("\"scenarioKind\":\"api\""))
        XCTAssertFalse(html.contains("secret-api-key"))
    }

    // MARK: - 6. Python IntelliSense, Folding, Code Snapshot & AI Prompt

    func testPythonPlaywrightIntelliSenseFixturesDecoratorsMembersAndInference() throws {
        let index = WorkspaceCompletionIndex(workspaceTags: ["@checkout", "@smoke"])

        // 1. Fixture parameter completion inside `def test_login(`
        let sigSource = "def test_login(pa"
        XCTAssertTrue(IntelliSenseEngine.isInsideCallbackArgList(sigSource))
        let sigRes = IntelliSenseEngine.completions(
            in: sigSource,
            cursorUTF16Offset: (sigSource as NSString).length,
            language: "python",
            sourceFileURL: nil,
            workspace: nil,
            index: index
        )
        XCTAssertTrue(sigRes?.items.contains(where: { $0.label == "page" && $0.insertText == "page: Page" }) == true)

        // 2. Type annotation completion after `:`
        let typeSource = "def test_api(api_ctx: API"
        let typeRes = IntelliSenseEngine.completions(
            in: typeSource,
            cursorUTF16Offset: (typeSource as NSString).length,
            language: "python",
            sourceFileURL: nil,
            workspace: nil,
            index: index
        )
        XCTAssertTrue(typeRes?.items.contains(where: { $0.label == "APIRequestContext" }) == true)

        // 3. Pytest decorator completion
        let decSource = "@pytest.mark.ch"
        let decRes = IntelliSenseEngine.completions(
            in: decSource,
            cursorUTF16Offset: (decSource as NSString).length,
            language: "python",
            sourceFileURL: nil,
            workspace: nil,
            index: index
        )
        XCTAssertTrue(decRes?.items.contains(where: { $0.label == "@pytest.mark.checkout" }) == true)

        // 4. Snake_case `page.` & `expect(page).` member completions
        let pageSource = """
        def test_nav(page: Page):
            page.get_by_
        """
        let pageRes = IntelliSenseEngine.completions(
            in: pageSource,
            cursorUTF16Offset: (pageSource as NSString).length,
            language: "python",
            sourceFileURL: nil,
            workspace: nil,
            index: index
        )
        XCTAssertTrue(pageRes?.items.contains(where: { $0.label == "get_by_role" }) == true)
        XCTAssertTrue(pageRes?.items.contains(where: { $0.label == "get_by_test_id" }) == true)

        let expectSource = "    expect(page).to_have_"
        let expectRes = IntelliSenseEngine.completions(
            in: expectSource,
            cursorUTF16Offset: (expectSource as NSString).length,
            language: "python",
            sourceFileURL: nil,
            workspace: nil,
            index: index
        )
        XCTAssertTrue(expectRes?.items.contains(where: { $0.label == "to_have_title" }) == true)
        XCTAssertTrue(expectRes?.items.contains(where: { $0.label == "to_have_url" }) == true)

        // 5. Local variable inference: `api_ctx = playwright.request.new_context()` -> `api_ctx.` & `res = api_ctx.get(...)` -> `res.`
        let apiSource = """
        def test_todo(playwright: Playwright):
            api_ctx = playwright.request.new_context(base_url="https://api.example.com")
            res = api_ctx.get("/todos/1")
            res.
        """
        let apiRes = IntelliSenseEngine.completions(
            in: apiSource,
            cursorUTF16Offset: (apiSource as NSString).length,
            language: "python",
            sourceFileURL: nil,
            workspace: nil,
            index: index
        )
        XCTAssertTrue(apiRes?.items.contains(where: { $0.label == "json" }) == true)
        XCTAssertTrue(apiRes?.items.contains(where: { $0.label == "status" }) == true)
        XCTAssertTrue(apiRes?.items.contains(where: { $0.label == "ok" }) == true)
    }

    func testPythonFoldingCodeSnapshotScaffoldingAndAISystemPrompt() throws {
        let pyCode = """
        @pytest.mark.smoke
        def test_home(page: Page):
            page.goto("/")
            expect(page).to_have_title("Home")
        """

        // Indentation-based folding
        let regions = CodeFoldingEngine.detectRegions(in: pyCode, language: "python")
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].startLine, 2)
        XCTAssertEqual(regions[0].endLine, 4)

        // Smart Code Snapshot extraction includes preceding @decorator & labels the function
        let extraction = CodeSnapshotEngine.extract(
            from: pyCode,
            language: "python",
            selectedRange: NSRange(location: 0, length: 0),
            caretLine: 3
        )
        XCTAssertEqual(extraction.startLineNumber, 1)
        XCTAssertEqual(extraction.endLineNumber, 4)
        XCTAssertEqual(extraction.blockLabel, "test_home")
        XCTAssertEqual(CodeSnapshotEngine.languageBadge(for: "python", fileName: "test_home.py"), "PY")

        let spans = CodeSnapshotEngine.tokenize(code: pyCode, language: "python")
        XCTAssertTrue(spans.contains(where: { $0.kind == .keyword }))
        XCTAssertTrue(spans.contains(where: { $0.kind == .dsl }))
        XCTAssertTrue(spans.contains(where: { $0.kind == .actor }))
        XCTAssertTrue(spans.contains(where: { $0.kind == .tag }))

        // Scaffolding filenames (snake_case + test_ / _page conventions)
        XCTAssertEqual(
            ProjectScaffolder.previewFileRelativePath(directory: "tests", name: "Checkout Flow", kind: .playwrightPythonTest),
            "tests/test_checkout_flow.py"
        )
        XCTAssertEqual(
            ProjectScaffolder.previewFileRelativePath(directory: "pages", name: "Checkout", kind: .playwrightPythonPageObject),
            "pages/checkout_page.py"
        )
        XCTAssertFalse(CodeSnippetItem.snippets(for: .playwrightPython).isEmpty)

        // AI System Prompt tailored to pytest-playwright
        let prompt = AIContextAssembler.buildSystemPrompt(helperDisplayName: "Playwright (Py) · chromium", framework: .playwrightPython)
        XCTAssertTrue(prompt.contains("pytest-playwright"))
        XCTAssertTrue(prompt.contains("page.get_by_role"))
        XCTAssertTrue(prompt.contains("to_be_visible()"))
        XCTAssertTrue(prompt.contains("```python"))
    }

    func testTerminalPreSuggestedCommandsAdaptToDetectedRuntimeEnvironment() throws {
        let fm = FileManager.default

        // 1. Python · uv (`uv.lock`)
        let uvRoot = try makeTempDir("term-uv")
        try "".write(to: uvRoot.appendingPathComponent("uv.lock"), atomically: true, encoding: .utf8)
        let uvSug = PackageManagerSupport.terminalSuggestions(
            workspaceRoot: uvRoot,
            framework: .playwrightPython,
            packageManager: .npm,
            jsRuntime: .node
        )
        XCTAssertEqual(uvSug.environment, .pythonUV)
        XCTAssertEqual(uvSug.badgeTitle, "uv")
        XCTAssertTrue(uvSug.dependencyItems.contains(where: { $0.commandPreview == "uv sync" }))
        XCTAssertTrue(uvSug.frameworkItems.contains(where: { $0.commandPreview == "uv run playwright install" }))
        XCTAssertTrue(uvSug.quickCommandItems.contains(where: { $0.commandPreview == "uv run pytest --co -q" }))
        XCTAssertFalse(uvSug.allSuggestions.contains(where: { $0.commandPreview.contains("npm") || $0.commandPreview.contains("codeceptjs") }))

        // 2. Python · Poetry (`poetry.lock`)
        let poetryRoot = try makeTempDir("term-poetry")
        try "".write(to: poetryRoot.appendingPathComponent("poetry.lock"), atomically: true, encoding: .utf8)
        let poetrySug = PackageManagerSupport.terminalSuggestions(
            workspaceRoot: poetryRoot,
            framework: .playwrightPython,
            packageManager: .npm,
            jsRuntime: .node
        )
        XCTAssertEqual(poetrySug.environment, .pythonPoetry)
        XCTAssertEqual(poetrySug.badgeTitle, "poetry")
        XCTAssertTrue(poetrySug.dependencyItems.contains(where: { $0.commandPreview == "poetry install" }))
        XCTAssertTrue(poetrySug.frameworkItems.contains(where: { $0.commandPreview == "poetry run playwright install" }))

        // 3. Python · Local `.venv`
        let venvRoot = try makeTempDir("term-venv")
        try ProjectScaffolder.createSamplePlaywrightPythonWorkspace(at: venvRoot)
        let venvBin = venvRoot.appendingPathComponent(".venv/bin", isDirectory: true)
        try fm.createDirectory(at: venvBin, withIntermediateDirectories: true)
        for bin in ["python", "pytest", "playwright"] {
            let p = venvBin.appendingPathComponent(bin)
            try "#!/bin/sh\necho ok\n".write(to: p, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.path)
        }
        let venvSug = PackageManagerSupport.terminalSuggestions(
            workspaceRoot: venvRoot,
            framework: .playwrightPython,
            packageManager: .npm,
            jsRuntime: .node
        )
        XCTAssertEqual(venvSug.environment, .pythonVenv(directoryName: ".venv"))
        XCTAssertEqual(venvSug.badgeTitle, ".venv")
        XCTAssertTrue(venvSug.dependencyItems.contains(where: { $0.commandPreview == ".venv/bin/python -m pip install -r requirements.txt" }))
        XCTAssertTrue(venvSug.frameworkItems.contains(where: { $0.commandPreview == ".venv/bin/playwright install" }))
        XCTAssertTrue(venvSug.inputPlaceholder(systemTerminalName: nil).contains(".venv/bin/playwright install"))

        // 4. Python · System (no venv yet)
        let sysPyRoot = try makeTempDir("term-sys-py")
        try ProjectScaffolder.createSamplePlaywrightPythonWorkspace(at: sysPyRoot)
        let sysPySug = PackageManagerSupport.terminalSuggestions(
            workspaceRoot: sysPyRoot,
            framework: .playwrightPython,
            packageManager: .npm,
            jsRuntime: .node
        )
        XCTAssertEqual(sysPySug.environment, .pythonSystem)
        XCTAssertEqual(sysPySug.badgeTitle, "pip")
        XCTAssertTrue(sysPySug.dependencyItems.first?.commandPreview.contains("python3 -m venv .venv") == true)
        XCTAssertFalse(sysPySug.inputPlaceholder(systemTerminalName: nil).contains("npm"))

        // 5. Playwright Test (TS/JS) with Bun runtime selected vs pnpm
        let jsRoot = try makeTempDir("term-js")
        let bunPwSug = PackageManagerSupport.terminalSuggestions(
            workspaceRoot: jsRoot,
            framework: .playwright,
            packageManager: .npm,
            jsRuntime: .bun
        )
        XCTAssertEqual(bunPwSug.environment, .nodePackageManager(.bun))
        XCTAssertEqual(bunPwSug.badgeTitle, "bun")
        XCTAssertTrue(bunPwSug.dependencyItems.contains(where: { $0.commandPreview == "bun install" }))
        XCTAssertTrue(bunPwSug.frameworkItems.contains(where: { $0.commandPreview == "bunx playwright install" }))
        XCTAssertTrue(bunPwSug.quickCommandItems.contains(where: { $0.commandPreview == "bunx playwright test --list" }))
        XCTAssertFalse(bunPwSug.allSuggestions.contains(where: { $0.commandPreview.contains("codeceptjs") }))

        let pnpmCodeceptSug = PackageManagerSupport.terminalSuggestions(
            workspaceRoot: jsRoot,
            framework: .codeceptJS,
            packageManager: .pnpm,
            jsRuntime: .node
        )
        XCTAssertEqual(pnpmCodeceptSug.environment, .nodePackageManager(.pnpm))
        XCTAssertEqual(pnpmCodeceptSug.badgeTitle, "pnpm")
        XCTAssertTrue(pnpmCodeceptSug.frameworkItems.contains(where: { $0.commandPreview == "pnpm add -D codeceptjs@latest" }))
        XCTAssertTrue(pnpmCodeceptSug.quickCommandItems.contains(where: { $0.commandPreview == "pnpm exec codeceptjs check" }))
    }
}
