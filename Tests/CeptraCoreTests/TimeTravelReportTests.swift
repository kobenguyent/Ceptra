import CeptraCore
import XCTest

final class TimeTravelReportTests: XCTestCase {
    func testLegacyTestRunReportDecodesBackwardCompatibly() throws {
        let legacyJSON = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "projectPath": "/tmp/demo",
          "projectName": "Demo",
          "label": "Run All",
          "commandLine": "codeceptjs run --steps",
          "startedAt": "2026-11-21T05:00:00Z",
          "finishedAt": "2026-11-21T05:00:02Z",
          "exitCode": 0,
          "wasCancelled": false,
          "passedCount": 1,
          "failedCount": 0,
          "skippedCount": 0,
          "durationMs": 2000,
          "scenarios": [
            {
              "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
              "featureTitle": "Auth",
              "scenarioTitle": "logs in",
              "status": "passed",
              "durationMs": 420,
              "tags": ["@smoke"],
              "steps": [
                {
                  "id": "99999999-8888-7777-6666-555555555555",
                  "text": "I amOnPage \\"/login\\"",
                  "depth": 0,
                  "status": "passed",
                  "durationMs": 120
                }
              ]
            }
          ],
          "rawOutput": "OK"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TestRunReport.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.projectName, "Demo")
        XCTAssertNil(decoded.traceBundlePath)
        XCTAssertNil(decoded.htmlReportPath)
        XCTAssertEqual(decoded.scenarios.count, 1)
        XCTAssertNil(decoded.scenarios[0].startedAt)
        XCTAssertNil(decoded.scenarios[0].steps[0].diagnostics)
        XCTAssertNil(decoded.scenarios[0].steps[0].targetSelector)
    }

    func testTraceStoreSavesLoadsAndPrunesBundles() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceptra-trace-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = TimeTravelTraceStore(baseDirectory: tempDir)
        let idKeep = UUID()
        let idDrop = UUID()

        let step = ExecutedStepRecord(
            text: ##"I click "#checkout""##,
            status: .passed,
            durationMs: 85,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_000.085),
            targetSelector: "#checkout",
            diagnostics: TimeTravelStepDiagnostics(
                pageURL: "https://example.com/cart",
                beforeScreenshotDataURI: "data:image/png;base64,iVBORw0KGgo=",
                afterScreenshotDataURI: "data:image/png;base64,iVBORw0KGgo=",
                domSnapshot: TimeTravelDOMSnapshot(
                    html: "<html><body><button id=\"checkout\">Checkout</button></body></html>",
                    url: "https://example.com/cart",
                    title: "Cart",
                    targetSelector: "#checkout",
                    targetOuterHTML: "<button id=\"checkout\">Checkout</button>",
                    targetBoundingBox: TimeTravelBoundingBox(x: 20, y: 40, width: 120, height: 36, viewportWidth: 1280, viewportHeight: 720),
                    matchedCount: 1
                ),
                networkRequests: [
                    TimeTravelNetworkEntry(
                        method: "POST",
                        url: "https://example.com/api/checkout",
                        resourceType: "fetch",
                        status: 200,
                        statusText: "OK",
                        durationMs: 42,
                        requestHeaders: ["content-type": "application/json"],
                        responseHeaders: ["content-type": "application/json"],
                        requestBody: #"{"cartId":7}"#,
                        responseBody: #"{"ok":true}"#
                    )
                ],
                consoleEntries: [
                    TimeTravelConsoleEntry(level: .info, message: "Checkout clicked", sourceURL: "app.js", lineNumber: 42)
                ]
            )
        )
        let sc = ExecutedScenarioRecord(featureTitle: "Cart", scenarioTitle: "checks out", status: .passed, durationMs: 85, steps: [step])

        let savedKeep = store.save(bundle: TimeTravelTraceBundle(reportID: idKeep, scenarios: [sc]))
        let savedDrop = store.save(bundle: TimeTravelTraceBundle(reportID: idDrop, scenarios: [sc]))
        XCTAssertNotNil(savedKeep)
        XCTAssertNotNil(savedDrop)

        let loaded = store.load(reportID: idKeep)
        XCTAssertEqual(loaded?.scenarios.count, 1)
        XCTAssertEqual(loaded?.scenarios.first?.steps.first?.diagnostics?.networkRequests.count, 1)
        XCTAssertEqual(loaded?.scenarios.first?.steps.first?.diagnostics?.domSnapshot?.targetSelector, "#checkout")

        store.prune(keepingReportIDs: [idKeep])
        XCTAssertNotNil(store.load(reportID: idKeep))
        XCTAssertNil(store.load(reportID: idDrop))
    }

    func testCommandBuilderInjectsTimeTravelPluginOnlyWhenConfigured() throws {
        let root = URL(fileURLWithPath: "/tmp/ceptra-cmd-tt")
        let traceDir = URL(fileURLWithPath: "/tmp/ceptra-cmd-tt/output/.ceptra-traces/run-1")
        let toolchain = ResolvedToolchain(
            nodePath: "/opt/homebrew/bin/node",
            codeceptExecutable: "/tmp/ceptra-cmd-tt/node_modules/.bin/codeceptjs",
            prefixArguments: [],
            searchPath: "/opt/homebrew/bin:/usr/bin",
            resolutionSource: "Test"
        )

        var opts = RunOptions()
        opts.timeTravelTrace = true

        let cmd = CommandBuilder.build(
            mode: .runAll,
            options: opts,
            workspaceRoot: root,
            configFilePath: "/tmp/ceptra-cmd-tt/codecept.conf.js",
            toolchain: toolchain,
            traceOutputDirectory: traceDir
        )
        XCTAssertEqual(cmd.environment["CEPTRA_TIME_TRAVEL_DIR"], traceDir.path)
        XCTAssertTrue(cmd.arguments.contains("-o"))
        let overrideIdx = try XCTUnwrap(cmd.arguments.firstIndex(of: "-o"))
        let overrideJSON = cmd.arguments[overrideIdx + 1]
        XCTAssertTrue(overrideJSON.contains("ceptraTimeTravel"))
        XCTAssertTrue(overrideJSON.contains("ceptra-time-travel-plugin.cjs"))

        // Dry run should NOT inject trace plugin
        let dryCmd = CommandBuilder.build(
            mode: .dryRun(relativePath: nil),
            options: opts,
            workspaceRoot: root,
            toolchain: toolchain,
            traceOutputDirectory: traceDir
        )
        XCTAssertNil(dryCmd.environment["CEPTRA_TIME_TRAVEL_DIR"])
        XCTAssertFalse(dryCmd.arguments.contains("-o"))

        // Disabled option should NOT inject trace plugin
        opts.timeTravelTrace = false
        let disabledCmd = CommandBuilder.build(
            mode: .runAll,
            options: opts,
            workspaceRoot: root,
            toolchain: toolchain,
            traceOutputDirectory: traceDir
        )
        XCTAssertNil(disabledCmd.environment["CEPTRA_TIME_TRAVEL_DIR"])
        XCTAssertFalse(disabledCmd.arguments.contains("-o"))
    }

    func testTimeTravelRecorderPluginCapturesTelemetryAndRedactsSecretsInNode() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("ceptra-tt-node-\(UUID().uuidString)", isDirectory: true)
        let traceDir = sandbox.appendingPathComponent("traces", isDirectory: true)
        try fm.createDirectory(at: traceDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        let toolchain = NodeToolchainResolver.resolve(workspaceRoot: sandbox)
        guard let nodePath = toolchain.nodePath else {
            throw XCTSkip("Node binary not available in test environment")
        }

        let pluginURL = try XCTUnwrap(TimeTravelRecorderLoader.ensurePluginFileURL(baseDirectory: sandbox))

        // Build a lightweight mock CodeceptJS module + Playwright page harness
        let mockCodeceptDir = sandbox.appendingPathComponent("node_modules/codeceptjs", isDirectory: true)
        try fm.createDirectory(at: mockCodeceptDir, withIntermediateDirectories: true)
        let mockCodeceptJS = """
        const { EventEmitter } = require('node:events');
        const dispatcher = new EventEmitter();
        const pageListeners = new Map();
        const mockPage = {
          url: () => 'https://app.example.test/checkout',
          title: async () => 'Checkout',
          on: (evt, fn) => {
            if (!pageListeners.has(evt)) pageListeners.set(evt, []);
            pageListeners.get(evt).push(fn);
          },
          emitEvent: (evt, payload) => {
            for (const fn of pageListeners.get(evt) || []) fn(payload);
          },
          screenshot: async () => Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]),
          content: async () => '<!doctype html><html><body><button id="pay" data-ceptra-target="true">Pay</button></body></html>',
          evaluate: async () => ({
            html: '<!doctype html><html><body><button id="pay" data-ceptra-target="true">Pay</button></body></html>',
            url: 'https://app.example.test/checkout',
            title: 'Checkout',
            targetOuterHTML: '<button id="pay" data-ceptra-target="true">Pay</button>',
            targetBoundingBox: { x: 10, y: 20, width: 100, height: 32, viewportWidth: 1280, viewportHeight: 720 },
            matchedCount: 1
          })
        };
        const helpers = { Playwright: { page: mockPage } };
        module.exports = {
          event: {
            dispatcher,
            test: { before: 'test.before', passed: 'test.passed', failed: 'test.failed', after: 'test.after' },
            step: { before: 'step.before', passed: 'step.passed', failed: 'step.failed', after: 'step.after' },
            all: { result: 'all.result' }
          },
          container: {
            helpers: () => helpers
          },
          __mockPage: mockPage
        };
        """
        try mockCodeceptJS.write(to: mockCodeceptDir.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        let driverScript = sandbox.appendingPathComponent("run-mock.cjs")
        let driverSource = """
        const codeceptjs = require('codeceptjs');
        const registerPlugin = require(\(String(reflecting: pluginURL.path)));
        registerPlugin({ enabled: true });

        (async () => {
          const { event, __mockPage: page } = codeceptjs;
          const test = {
            title: 'completes checkout @smoke',
            parent: { title: 'Checkout' },
            file: '/repo/tests/checkout_test.js',
            tags: ['@smoke']
          };
          const step1 = { name: 'click', args: ['#pay'], helperMethod: 'click', toString: () => 'I click "#pay"' };

          event.dispatcher.emit(event.test.before, test);
          event.dispatcher.emit(event.step.before, step1);
          await new Promise((r) => setTimeout(r, 25));

          // Simulate network request + response with sensitive auth & cookie headers
          const reqObj = {
            url: () => 'https://app.example.test/api/pay',
            method: () => 'POST',
            resourceType: () => 'fetch',
            headers: () => ({ 'authorization': 'Bearer super-secret-jwt', 'cookie': 'sid=abc', 'content-type': 'application/json' }),
            postData: () => '{"amount":42}'
          };
          page.emitEvent('request', reqObj);
          page.emitEvent('response', {
            request: () => reqObj,
            url: () => 'https://app.example.test/api/pay',
            status: () => 500,
            statusText: () => 'Internal Server Error',
            headers: () => ({ 'content-type': 'application/json', 'set-cookie': 'sid=xyz' }),
            text: async () => '{"error":"Card declined"}'
          });
          page.emitEvent('console', {
            type: () => 'warn',
            text: () => 'Retrying payment gateway',
            location: () => ({ url: 'https://app.example.test/checkout.js', lineNumber: 88 })
          });
          page.emitEvent('pageerror', new Error('Uncaught PaymentError: declined'));

          event.dispatcher.emit(event.step.failed, step1, new Error('Payment failed'));
          event.dispatcher.emit(event.step.after, step1);
          await new Promise((r) => setTimeout(r, 40));

          event.dispatcher.emit(event.test.failed, test, new Error('Payment failed'));
          event.dispatcher.emit(event.test.after, test);
          event.dispatcher.emit(event.all.result);
          await new Promise((r) => setTimeout(r, 60));
        })();
        """
        try driverSource.write(to: driverScript, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [driverScript.path]
        proc.currentDirectoryURL = sandbox
        var env = ProcessInfo.processInfo.environment
        env["CEPTRA_TIME_TRAVEL_DIR"] = traceDir.path
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(proc.terminationStatus, 0, "Mock Node run failed: \(output)")

        let loaded = TimeTravelTraceMerger.loadWorkerTraces(from: traceDir)
        XCTAssertEqual(loaded.count, 1)
        let sc = try XCTUnwrap(loaded.first)
        XCTAssertEqual(sc.featureTitle, "Checkout")
        XCTAssertEqual(sc.scenarioTitle, "completes checkout @smoke")
        XCTAssertEqual(sc.status, .failed)
        XCTAssertEqual(sc.steps.count, 1)

        let step = try XCTUnwrap(sc.steps.first)
        XCTAssertEqual(step.status, .failed)
        XCTAssertEqual(step.targetSelector, "#pay")
        let diag = try XCTUnwrap(step.diagnostics)
        XCTAssertNotNil(diag.beforeScreenshotDataURI)
        XCTAssertNotNil(diag.afterScreenshotDataURI)
        XCTAssertEqual(diag.domSnapshot?.targetSelector, "#pay")
        XCTAssertEqual(diag.domSnapshot?.matchedCount, 1)

        // Verify network capture & credential redaction
        XCTAssertEqual(diag.networkRequests.count, 1)
        let net = try XCTUnwrap(diag.networkRequests.first)
        XCTAssertEqual(net.method, "POST")
        XCTAssertEqual(net.status, 500)
        XCTAssertEqual(net.requestHeaders["authorization"], "[REDACTED]")
        XCTAssertEqual(net.requestHeaders["cookie"], "[REDACTED]")
        XCTAssertEqual(net.responseHeaders["set-cookie"], "[REDACTED]")
        XCTAssertEqual(net.requestHeaders["content-type"], "application/json")
        XCTAssertEqual(net.responseBody, #"{"error":"Card declined"}"#)

        // Verify console + uncaught pageerror capture
        XCTAssertTrue(diag.consoleEntries.contains(where: { $0.level == .warn && $0.message.contains("Retrying payment gateway") }))
        XCTAssertTrue(diag.consoleEntries.contains(where: { $0.level == .pageerror && $0.message.contains("PaymentError") }))
    }

    func testSelfContainedHTMLReportHasTimeTravelUIXSSSafetyDeduplicationAndValidJS() throws {
        let baseDate = Date(timeIntervalSince1970: 1_763_700_000)
        let sharedScreenshot = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let hostileDOM = """
        <!doctype html>
        <html>
          <head><title>Checkout</title></head>
          <body>
            <script>window.__xss = true;</script>
            <main>
              <button id="pay-btn" data-ceptra-target="true" onclick="alert(1)">Pay Now</button>
            </main>
            <!-- </script><img src=x onerror=alert('breakout')> -->
          </body>
        </html>
        """

        let step1 = ExecutedStepRecord(
            text: #"I amOnPage "/checkout""#,
            depth: 0,
            status: .passed,
            durationMs: 140,
            startedAt: baseDate,
            finishedAt: baseDate.addingTimeInterval(0.14),
            diagnostics: TimeTravelStepDiagnostics(
                pageURL: "https://shop.example.test/checkout",
                beforeScreenshotDataURI: sharedScreenshot,
                afterScreenshotDataURI: sharedScreenshot,
                domSnapshot: TimeTravelDOMSnapshot(
                    html: hostileDOM,
                    url: "https://shop.example.test/checkout",
                    title: "Checkout"
                ),
                networkRequests: [
                    TimeTravelNetworkEntry(
                        method: "GET",
                        url: "https://shop.example.test/checkout",
                        resourceType: "document",
                        status: 200,
                        statusText: "OK",
                        durationMs: 110
                    )
                ],
                consoleEntries: []
            )
        )

        let step2 = ExecutedStepRecord(
            text: ##"I click "#pay-btn""##,
            depth: 0,
            status: .failed,
            durationMs: 320,
            startedAt: baseDate.addingTimeInterval(0.15),
            finishedAt: baseDate.addingTimeInterval(0.47),
            targetSelector: "#pay-btn",
            errorMessage: "Expected payment confirmation banner",
            diagnostics: TimeTravelStepDiagnostics(
                pageURL: "https://shop.example.test/checkout",
                beforeScreenshotDataURI: sharedScreenshot,
                afterScreenshotDataURI: sharedScreenshot,
                domSnapshot: TimeTravelDOMSnapshot(
                    html: hostileDOM,
                    url: "https://shop.example.test/checkout",
                    title: "Checkout",
                    targetSelector: "#pay-btn",
                    targetOuterHTML: #"<button id="pay-btn" data-ceptra-target="true">Pay Now</button>"#,
                    targetBoundingBox: TimeTravelBoundingBox(x: 42, y: 120, width: 140, height: 42, viewportWidth: 1280, viewportHeight: 720),
                    matchedCount: 1
                ),
                networkRequests: [
                    TimeTravelNetworkEntry(
                        method: "POST",
                        url: "https://shop.example.test/api/charge",
                        resourceType: "fetch",
                        status: 402,
                        statusText: "Payment Required",
                        durationMs: 215,
                        requestHeaders: ["content-type": "application/json"],
                        responseHeaders: ["content-type": "application/json"],
                        requestBody: #"{"amount":1999}"#,
                        responseBody: #"{"code":"card_declined"}"#
                    )
                ],
                consoleEntries: [
                    TimeTravelConsoleEntry(level: .error, message: "Charge API returned 402", timestamp: baseDate.addingTimeInterval(0.4), sourceURL: "checkout.js", lineNumber: 120)
                ]
            )
        )

        let report = TestRunReport(
            projectPath: "/tmp/shop",
            projectName: "ShopWeb",
            label: "Run checkout_test.js",
            commandLine: "codeceptjs run tests/checkout_test.js --steps",
            startedAt: baseDate,
            finishedAt: baseDate.addingTimeInterval(0.5),
            exitCode: 1,
            passedCount: 0,
            failedCount: 1,
            skippedCount: 0,
            durationMs: 500,
            scenarios: [
                ExecutedScenarioRecord(
                    featureTitle: "Checkout",
                    scenarioTitle: "handles declined card @smoke",
                    filePath: "/tmp/shop/tests/checkout_test.js",
                    status: .failed,
                    durationMs: 470,
                    tags: ["@smoke"],
                    steps: [step1, step2],
                    errorMessage: "Expected payment confirmation banner"
                )
            ],
            rawOutput: "FAIL | 0 passed, 1 failed"
        )

        let html = ReportExporter.toHTML(report)

        // 1. Self-contained: no external CDN script/stylesheet links
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertFalse(html.contains("<script src=\"http"))
        XCTAssertFalse(html.contains("<link rel=\"stylesheet\" href=\"http"))

        // 2. Core interactive controls & accessible semantics present
        XCTAssertTrue(html.contains(#"id="ceptra-report-data""#))
        XCTAssertTrue(html.contains(#"role="toolbar""#))
        XCTAssertTrue(html.contains(#"focusgroup="toolbar wrap""#))
        XCTAssertTrue(html.contains(#"focusgroup="tablist nomemory""#))
        XCTAssertTrue(html.contains("Jump to Failure"))
        XCTAssertTrue(html.contains("DOM Snapshot"))
        XCTAssertTrue(html.contains("Network"))
        XCTAssertTrue(html.contains("Visual &amp; Console"))
        XCTAssertTrue(html.contains(#"sandbox="""#))

        // 3. XSS breakout prevention: raw `</script>` inside embedded JSON must be escaped
        let jsonStart = try XCTUnwrap(html.range(of: #"<script id="ceptra-report-data" type="application/json">"#))
        let jsonEnd = try XCTUnwrap(html.range(of: "</script>", range: jsonStart.upperBound..<html.endIndex))
        let embeddedJSON = String(html[jsonStart.upperBound..<jsonEnd.lowerBound])
        XCTAssertFalse(embeddedJSON.contains("</script>"))
        XCTAssertFalse(embeddedJSON.contains("<!--"))
        // Verify JSON parses cleanly and deduplicates shared screenshot & DOM assets
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(embeddedJSON.utf8)) as? [String: Any])
        let assets = try XCTUnwrap(parsed["assets"] as? [String: String])
        // Shared screenshot appears 4 times across 2 steps, hostileDOM appears 2 times -> only 2 unique assets!
        XCTAssertEqual(assets.count, 2)

        // 4. Verify embedded client JS has zero syntax errors using `node --check`
        let toolchain = NodeToolchainResolver.resolve(workspaceRoot: FileManager.default.temporaryDirectory)
        if let nodePath = toolchain.nodePath {
            let appScriptMarker = #"<script id="ceptra-report-app">"#
            let jsStart = try XCTUnwrap(html.range(of: appScriptMarker))
            let jsEnd = try XCTUnwrap(html.range(of: "</script>", range: jsStart.upperBound..<html.endIndex))
            let jsCode = String(html[jsStart.upperBound..<jsEnd.lowerBound])

            let tmpJS = FileManager.default.temporaryDirectory.appendingPathComponent("ceptra-report-check-\(UUID().uuidString).js")
            try jsCode.write(to: tmpJS, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tmpJS) }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: nodePath)
            proc.arguments = ["--check", tmpJS.path]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try proc.run()
            proc.waitUntilExit()
            let errText = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(proc.terminationStatus, 0, "Report JS syntax check failed: \(errText)")
        }
    }

    func testTraceMergerCombinesMultiWorkerTracesWithJUnitAndSynthesizesTimestamps() throws {
        let baseDate = Date(timeIntervalSince1970: 1_763_700_000)
        let primary = [
            ExecutedScenarioRecord(
                featureTitle: "Checkout",
                scenarioTitle: "submits order @smoke",
                filePath: "/repo/tests/checkout_test.js",
                status: .passed,
                durationMs: 300,
                tags: ["@smoke"],
                steps: [
                    ExecutedStepRecord(text: #"I amOnPage "/checkout""#, durationMs: 120),
                    ExecutedStepRecord(text: #"I click "Pay""#, durationMs: 180)
                ]
            ),
            ExecutedScenarioRecord(
                featureTitle: "API",
                scenarioTitle: "checks health",
                status: .passed,
                durationMs: 50,
                steps: [
                    ExecutedStepRecord(text: #"I sendGetRequest "/health""#, durationMs: 50)
                ]
            )
        ]

        let trace = [
            ExecutedScenarioRecord(
                featureTitle: "Checkout",
                scenarioTitle: "submits order @smoke",
                status: .passed,
                durationMs: 295,
                startedAt: baseDate,
                finishedAt: baseDate.addingTimeInterval(0.295),
                steps: [
                    ExecutedStepRecord(
                        text: #"I amOnPage "/checkout""#,
                        status: .passed,
                        durationMs: 115,
                        startedAt: baseDate,
                        finishedAt: baseDate.addingTimeInterval(0.115),
                        diagnostics: TimeTravelStepDiagnostics(pageURL: "https://example.test/checkout")
                    ),
                    ExecutedStepRecord(
                        text: #"I click "Pay""#,
                        status: .passed,
                        durationMs: 180,
                        startedAt: baseDate.addingTimeInterval(0.115),
                        finishedAt: baseDate.addingTimeInterval(0.295),
                        targetSelector: "Pay",
                        diagnostics: TimeTravelStepDiagnostics(
                            pageURL: "https://example.test/checkout",
                            afterScreenshotDataURI: "data:image/png;base64,iVBORw0KGgo="
                        )
                    )
                ]
            )
        ]

        let merged = TimeTravelTraceMerger.merge(
            primaryScenarios: primary,
            traceScenarios: trace,
            runStartedAt: baseDate
        )
        XCTAssertEqual(merged.count, 2)
        // Matched scenario retains JUnit filePath/tags and gains rich trace diagnostics
        XCTAssertEqual(merged[0].filePath, "/repo/tests/checkout_test.js")
        XCTAssertEqual(merged[0].tags, ["@smoke"])
        XCTAssertEqual(merged[0].steps[1].targetSelector, "Pay")
        XCTAssertNotNil(merged[0].steps[1].diagnostics?.afterScreenshotDataURI)
        // Unmatched JUnit-only scenario receives synthesized monotonic timestamps
        XCTAssertNotNil(merged[1].startedAt)
        XCTAssertNotNil(merged[1].steps[0].startedAt)
        XCTAssertNotNil(merged[1].steps[0].finishedAt)
        XCTAssertGreaterThanOrEqual(merged[1].startedAt!, merged[0].finishedAt!)
    }

    func testApiTimeTravelRecorderCapturesNodeHttpFetchGzipBeforeSuiteAndAssertions() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("ceptra-api-tt-\(UUID().uuidString)", isDirectory: true)
        let traceDir = sandbox.appendingPathComponent("traces", isDirectory: true)
        try fm.createDirectory(at: traceDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        let toolchain = NodeToolchainResolver.resolve(workspaceRoot: sandbox)
        guard let nodePath = toolchain.nodePath else {
            throw XCTSkip("Node binary not available in test environment")
        }

        let pluginURL = try XCTUnwrap(TimeTravelRecorderLoader.ensurePluginFileURL(baseDirectory: sandbox))

        // Mock CodeceptJS module WITHOUT any browser/Playwright page (pure API suite!)
        let mockCodeceptDir = sandbox.appendingPathComponent("node_modules/codeceptjs", isDirectory: true)
        try fm.createDirectory(at: mockCodeceptDir, withIntermediateDirectories: true)
        let mockCodeceptJS = """
        const { EventEmitter } = require('node:events');
        const dispatcher = new EventEmitter();
        module.exports = {
          event: {
            dispatcher,
            suite: { before: 'suite.before', after: 'suite.after' },
            test: { before: 'test.before', passed: 'test.passed', failed: 'test.failed', skipped: 'test.skipped', after: 'test.after' },
            step: { before: 'step.before', passed: 'step.passed', failed: 'step.failed', after: 'step.after' },
            all: { result: 'all.result' }
          },
          container: {
            helpers: () => ({ REST: {}, JSONResponse: {} })
          }
        };
        """
        try mockCodeceptJS.write(to: mockCodeceptDir.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        let driverScript = sandbox.appendingPathComponent("run-api-mock.cjs")
        let driverSource = """
        const http = require('node:http');
        const zlib = require('node:zlib');
        const codeceptjs = require('codeceptjs');
        const registerPlugin = require(\(String(reflecting: pluginURL.path)));
        registerPlugin({ enabled: true });

        function httpCall(url, opts, body) {
          return new Promise((resolve, reject) => {
            const req = http.request(url, opts, (res) => {
              const chunks = [];
              res.on('data', (c) => chunks.push(c));
              res.on('end', () => resolve({ status: res.statusCode, raw: Buffer.concat(chunks) }));
            });
            req.on('error', reject);
            if (body) req.write(body);
            req.end();
          });
        }

        (async () => {
          // Local real HTTP server serving token JSON, gzip-compressed accounts JSON, and POST echo
          const server = http.createServer((req, res) => {
            const chunks = [];
            req.on('data', (c) => chunks.push(c));
            req.on('end', () => {
              if (req.url === '/oauth/token') {
                res.writeHead(200, { 'Content-Type': 'application/json', 'Set-Cookie': 'session=secret' });
                res.end(JSON.stringify({ access_token: 'tok-123' }));
              } else if (req.url.startsWith('/admin/accounts')) {
                const gz = zlib.gzipSync(Buffer.from(JSON.stringify({ items: [{ id: 1, name: 'Acme' }] })));
                res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Encoding': 'gzip' });
                res.end(gz);
              } else if (req.url === '/admin/users' && req.method === 'POST') {
                res.writeHead(201, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ created: true, echo: JSON.parse(Buffer.concat(chunks).toString('utf8')) }));
              } else {
                res.writeHead(403, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Forbidden' }));
              }
            });
          });
          await new Promise((r) => server.listen(0, '127.0.0.1', r));
          const port = server.address().port;
          const base = `http://127.0.0.1:${port}`;

          const { event } = codeceptjs;
          event.dispatcher.emit(event.suite.before, { title: 'Admin > Accounts' });

          // 1. BeforeSuite HTTP call (outside any scenario/step, like kcApi.getTokenWithPasswordGrant)
          await httpCall(`${base}/oauth/token`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Authorization': 'Basic dXNlcjpwYXNz' }
          }, JSON.stringify({ grant_type: 'password' }));

          // 2. Scenario with direct axios/http call OUTSIDE I.* step + fetch inside I.* step + assertion step
          const test = {
            title: 'Fetch and create accounts @api',
            parent: { title: 'Admin > Accounts' },
            file: '/repo/tests/api/accounts.spec.ts',
            tags: ['@api']
          };
          event.dispatcher.emit(event.test.before, test);

          // Direct http.request outside any I.* step (gzipped response!)
          await httpCall(`${base}/admin/accounts?page=1&size=10`, {
            method: 'GET',
            headers: { 'Authorization': 'Bearer super-secret', 'Accept': 'application/json' }
          });

          // Fetch inside an active I.sendPostRequest step
          const postStep = { name: 'sendPostRequest', args: ['/admin/users'], toString: () => 'I sendPostRequest "/admin/users"' };
          event.dispatcher.emit(event.step.before, postStep);
          const fRes = await fetch(`${base}/admin/users`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'x-api-key': 'secret-key' },
            body: JSON.stringify({ email: 'qa@example.test' })
          });
          await fRes.json();
          event.dispatcher.emit(event.step.after, postStep);

          // Assertion step linked to the preceding API exchange
          const assertStep = {
            name: 'expectContain',
            args: ['{"created":true}', 'created'],
            toString: () => 'I expectContain "{\\"created\\":true}", "created"'
          };
          event.dispatcher.emit(event.step.before, assertStep);
          event.dispatcher.emit(event.step.after, assertStep);

          event.dispatcher.emit(event.test.passed, test);
          event.dispatcher.emit(event.test.after, test);
          event.dispatcher.emit(event.all.result);
          await new Promise((r) => setTimeout(r, 80));
          server.close();
        })();
        """
        try driverSource.write(to: driverScript, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [driverScript.path]
        proc.currentDirectoryURL = sandbox
        var env = ProcessInfo.processInfo.environment
        env["CEPTRA_TIME_TRAVEL_DIR"] = traceDir.path
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(proc.terminationStatus, 0, "Mock API Node run failed: \(output)")

        let loaded = TimeTravelTraceMerger.loadWorkerTraces(from: traceDir)
        XCTAssertEqual(loaded.count, 2, "Expected BeforeSuite setup bucket + 1 scenario, got: \(loaded.map(\.scenarioTitle))")

        let setupSc = try XCTUnwrap(loaded.first(where: { $0.tags.contains("@setup") }))
        XCTAssertEqual(setupSc.steps.count, 1)
        let setupReq = try XCTUnwrap(setupSc.steps.first?.diagnostics?.networkRequests.first)
        XCTAssertEqual(setupReq.method, "POST")
        XCTAssertEqual(setupReq.status, 200)
        XCTAssertEqual(setupReq.requestHeaders["authorization"], "[REDACTED]")
        XCTAssertEqual(setupReq.responseHeaders["set-cookie"], "[REDACTED]")
        XCTAssertTrue(setupReq.responseBody?.contains("tok-123") == true)

        let mainSc = try XCTUnwrap(loaded.first(where: { $0.scenarioTitle == "Fetch and create accounts @api" }))
        XCTAssertEqual(mainSc.steps.count, 3, "Expected synthetic GET step + I.sendPostRequest step + I.expectContain step")

        // Step 1: synthetic HTTP GET step with decompressed gzip JSON + timing breakdown
        let getStep = mainSc.steps[0]
        XCTAssertTrue(getStep.text.contains("HTTP GET /admin/accounts?page=1&size=10"))
        let getReq = try XCTUnwrap(getStep.diagnostics?.networkRequests.first)
        XCTAssertEqual(getReq.status, 200)
        XCTAssertEqual(getReq.source, "http")
        XCTAssertEqual(getReq.requestHeaders["authorization"], "[REDACTED]")
        XCTAssertTrue(getReq.responseBody?.contains(#""name":"Acme""#) == true, "Expected gunzipped JSON body, got: \(getReq.responseBody ?? "nil")")
        XCTAssertNotNil(getReq.timings?.totalMs)

        // Step 2: fetch() inside I.sendPostRequest
        let postStep = mainSc.steps[1]
        let postReq = try XCTUnwrap(postStep.diagnostics?.networkRequests.first)
        XCTAssertEqual(postReq.method, "POST")
        XCTAssertEqual(postReq.status, 201)
        XCTAssertEqual(postReq.source, "fetch")
        XCTAssertEqual(postReq.requestHeaders["x-api-key"], "[REDACTED]")
        XCTAssertTrue(postReq.requestBody?.contains("qa@example.test") == true)
        XCTAssertTrue(postReq.responseBody?.contains("qa@example.test") == true)

        // Step 3: assertion linked to the preceding POST request
        let assertStep = mainSc.steps[2]
        let assertion = try XCTUnwrap(assertStep.diagnostics?.assertion)
        XCTAssertEqual(assertion.method, "expectContain")
        XCTAssertTrue(assertion.passed)
        XCTAssertEqual(assertion.relatedRequestId, postReq.id)

        // Verify TimeTravelTraceMerger places @setup BeforeSuite traces ahead of primary scenarios
        let primaryOnly = [
            ExecutedScenarioRecord(featureTitle: "Admin > Accounts", scenarioTitle: "Fetch and create accounts @api", status: .passed, durationMs: 90)
        ]
        let merged = TimeTravelTraceMerger.merge(primaryScenarios: primaryOnly, traceScenarios: loaded, runStartedAt: Date())
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged[0].tags.contains("@setup"))
        XCTAssertEqual(merged[1].steps.count, 3)

        // Generate API Replay HTML and verify mode auto-detection + valid JS syntax
        let report = TestRunReport(
            projectPath: sandbox.path,
            projectName: "QA API Suite",
            label: "Run accounts.spec.ts",
            commandLine: "codeceptjs run tests/api/accounts.spec.ts --steps",
            startedAt: Date(),
            finishedAt: Date().addingTimeInterval(0.4),
            exitCode: 0,
            passedCount: 1,
            failedCount: 0,
            skippedCount: 0,
            durationMs: 400,
            scenarios: merged,
            rawOutput: "OK | 1 passed"
        )
        let html = ReportExporter.toHTML(report)
        XCTAssertTrue(html.contains(#"data-report-mode="api""#))
        XCTAssertTrue(html.contains("API REPLAY"))
        XCTAssertTrue(html.contains("API Calls"))
        XCTAssertTrue(html.contains("API Exchange"))
        XCTAssertTrue(html.contains("Waterfall &amp; Diff"))
        XCTAssertTrue(html.contains("Copy cURL"))
        XCTAssertTrue(html.contains("Replay Live"))

        let appScriptMarker = #"<script id="ceptra-report-app">"#
        let jsStart = try XCTUnwrap(html.range(of: appScriptMarker))
        let jsEnd = try XCTUnwrap(html.range(of: "</script>", range: jsStart.upperBound..<html.endIndex))
        let jsCode = String(html[jsStart.upperBound..<jsEnd.lowerBound])
        let tmpJS = sandbox.appendingPathComponent("api-replay-check.js")
        try jsCode.write(to: tmpJS, atomically: true, encoding: .utf8)

        let checkProc = Process()
        checkProc.executableURL = URL(fileURLWithPath: nodePath)
        checkProc.arguments = ["--check", tmpJS.path]
        let checkPipe = Pipe()
        checkProc.standardOutput = checkPipe
        checkProc.standardError = checkPipe
        try checkProc.run()
        checkProc.waitUntilExit()
        let checkOut = String(data: checkPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(checkProc.terminationStatus, 0, "API Replay HTML JS syntax check failed: \(checkOut)")
    }
}
