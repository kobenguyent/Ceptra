import CeptraCore
import Foundation
import XCTest

final class DebugModeTests: XCTestCase {

    // MARK: - 1. SourceMap v3 Inline Base64 Bidirectional Mapping

    func testSourceMapV3InlineBase64BidirectionalMapping() throws {
        let originalPath = "/tmp/demo/login.spec.ts"
        // VLQ mappings:
        // genLine 0: unmapped
        // genLine 1: unmapped
        // genLine 2: col 0 -> src 0, origLine 0, origCol 0  ("AAAA")
        // genLine 3: col 0 -> src 0, origLine 1, origCol 0  ("AACA"), col 4 -> src 0, origLine 1, origCol 4 ("IAAI")
        let sourceMapJSON: [String: Any] = [
            "version": 3,
            "sources": [originalPath],
            "mappings": ";;AAAA;AACA,IAAI"
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: sourceMapJSON)
        let dataURL = "data:application/json;charset=utf-8;base64,\(jsonData.base64EncodedString())"

        let map = try XCTUnwrap(SourceMapV3.decode(sourceMapURL: dataURL, scriptURLString: nil))
        XCTAssertEqual(map.resolvedSources, [originalPath])

        // Generated (0-based) -> Original (1-based)
        let pos0 = try XCTUnwrap(map.originalPosition(generatedLine: 2, generatedColumn: 0))
        XCTAssertEqual(pos0, SourceMapOriginalPosition(sourcePath: originalPath, line: 1, column: 1))

        let pos1 = try XCTUnwrap(map.originalPosition(generatedLine: 3, generatedColumn: 0))
        XCTAssertEqual(pos1, SourceMapOriginalPosition(sourcePath: originalPath, line: 2, column: 1))

        let pos1Col = try XCTUnwrap(map.originalPosition(generatedLine: 3, generatedColumn: 4))
        XCTAssertEqual(pos1Col, SourceMapOriginalPosition(sourcePath: originalPath, line: 2, column: 5))

        // Unmapped generated line returns nil
        XCTAssertNil(map.originalPosition(generatedLine: 0, generatedColumn: 0))

        // Original (1-based) -> Generated (0-based)
        let gen0 = try XCTUnwrap(map.generatedPosition(forOriginalFile: originalPath, oneBasedLine: 1))
        XCTAssertEqual(gen0, SourceMapGeneratedPosition(line: 2, column: 0))

        let gen1 = try XCTUnwrap(map.generatedPosition(forOriginalFile: originalPath, oneBasedLine: 2))
        XCTAssertEqual(gen1, SourceMapGeneratedPosition(line: 3, column: 0))

        // Malformed sourceMapURLs return nil safely
        XCTAssertNil(SourceMapV3.decode(sourceMapURL: "data:application/json;base64,!!!invalid!!!", scriptURLString: nil))
        XCTAssertNil(SourceMapV3.decode(sourceMapURL: "data:application/json;base64,e30=", scriptURLString: nil))
        XCTAssertNil(SourceMapV3.decode(sourceMapURL: "data:no-comma-here", scriptURLString: nil))
        XCTAssertNil(SourceMapV3.decode(sourceMapURL: "/nonexistent/path/missing.js.map", scriptURLString: nil))
    }

    // MARK: - 2. BreakpointStore Persistence & Logpoint Expression

    func testBreakpointStorePersistenceAndLogpointExpression() throws {
        // Logpoint interpolation and CDP condition wrapping
        let expr = DebugBreakpoint.buildLogpointExpression(from: "id={user.id} ok")
        XCTAssertEqual(expr, "\"id=\", (user.id), \" ok\"")

        let logpoint = DebugBreakpoint(
            filePath: "/tmp/workspace/login_test.ts",
            line: 14,
            logMessage: "id={user.id} ok"
        )
        XCTAssertTrue(logpoint.isLogpoint)
        XCTAssertFalse(logpoint.isConditional)
        XCTAssertEqual(logpoint.effectiveCDPCondition, "(console.log(\"id=\", (user.id), \" ok\"), false)")

        let conditional = DebugBreakpoint(
            filePath: "/tmp/workspace/login_test.ts",
            line: 20,
            condition: "count > 3"
        )
        XCTAssertFalse(conditional.isLogpoint)
        XCTAssertTrue(conditional.isConditional)
        XCTAssertEqual(conditional.effectiveCDPCondition, "count > 3")

        // Isolated UserDefaults suite persistence
        let suiteName = "com.kobenguyent.Ceptra.DebugModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BreakpointStore(defaults: defaults)
        let workspaceRoot = "/tmp/workspace"

        XCTAssertTrue(store.loadBreakpoints(forWorkspaceRoot: workspaceRoot).isEmpty)
        XCTAssertTrue(store.loadWatchExpressions(forWorkspaceRoot: workspaceRoot).isEmpty)

        // Save in unsorted order to verify deterministic sorting on load
        store.saveBreakpoints([conditional, logpoint], forWorkspaceRoot: workspaceRoot)
        let loadedBPs = store.loadBreakpoints(forWorkspaceRoot: workspaceRoot)
        XCTAssertEqual(loadedBPs, [logpoint, conditional])

        // Save watch expressions with whitespace & empties
        store.saveWatchExpressions(["  user.id ", "", "   ", "items.length"], forWorkspaceRoot: workspaceRoot)
        let loadedWatches = store.loadWatchExpressions(forWorkspaceRoot: workspaceRoot)
        XCTAssertEqual(loadedWatches, ["user.id", "items.length"])

        // Clear both
        store.saveBreakpoints([], forWorkspaceRoot: workspaceRoot)
        store.saveWatchExpressions([], forWorkspaceRoot: workspaceRoot)
        XCTAssertTrue(store.loadBreakpoints(forWorkspaceRoot: workspaceRoot).isEmpty)
        XCTAssertTrue(store.loadWatchExpressions(forWorkspaceRoot: workspaceRoot).isEmpty)
    }

    // MARK: - 3. CommandBuilder & LiveOutputParser Debug Mode

    func testCommandBuilderAndLiveOutputParserDebugMode() throws {
        let root = URL(fileURLWithPath: "/tmp/demo")
        let toolchain = ResolvedToolchain(
            nodePath: "/opt/homebrew/bin/node",
            codeceptExecutable: "/tmp/demo/node_modules/.bin/codeceptjs",
            prefixArguments: [],
            searchPath: "/opt/homebrew/bin:/usr/bin",
            resolutionSource: "Project node_modules"
        )

        let debugOptions = DebugLaunchOptions(enabled: true, headedBrowser: true)
        let cmd = CommandBuilder.build(
            mode: .runFile(relativePath: "tests/login_test.ts"),
            options: RunOptions(esmCjsCompat: false),
            workspaceRoot: root,
            configFilePath: nil,
            toolchain: toolchain,
            debugOptions: debugOptions
        )

        let nodeOpts = try XCTUnwrap(cmd.environment["NODE_OPTIONS"])
        XCTAssertTrue(nodeOpts.contains("--inspect-brk=127.0.0.1:0"), "Expected --inspect-brk in NODE_OPTIONS, got: \(nodeOpts)")
        XCTAssertTrue(cmd.arguments.contains("--no-timeouts"), "Expected --no-timeouts in arguments: \(cmd.arguments)")
        XCTAssertEqual(cmd.environment["HEADLESS"], "false")

        // Non-debuggable mode should not inject --inspect-brk or --no-timeouts
        let dryRunCmd = CommandBuilder.build(
            mode: .dryRun(relativePath: "tests/login_test.ts"),
            options: RunOptions(esmCjsCompat: false),
            workspaceRoot: root,
            configFilePath: nil,
            toolchain: toolchain,
            debugOptions: debugOptions
        )
        XCTAssertFalse((dryRunCmd.environment["NODE_OPTIONS"] ?? "").contains("--inspect-brk"))
        XCTAssertFalse(dryRunCmd.arguments.contains("--no-timeouts"))

        // LiveOutputParser: loopback inspector URL accepted, 0.0.0.0 ignored
        let parser = LiveOutputParser()

        let loopbackEvents = parser.feed(line: "Debugger listening on ws://127.0.0.1:9229/abc-123", isStderr: true)
        let expectedURL = try XCTUnwrap(URL(string: "ws://127.0.0.1:9229/abc-123"))
        XCTAssertTrue(loopbackEvents.contains(.inspectorListening(expectedURL)))

        let nonLoopbackEvents = parser.feed(line: "Debugger listening on ws://0.0.0.0:9229/abc-123", isStderr: true)
        let hasInspectorEvent = nonLoopbackEvents.contains { event in
            if case .inspectorListening = event { return true }
            return false
        }
        XCTAssertFalse(hasInspectorEvent, "Non-loopback inspector URL must be ignored")

        // LiveOutputParser: interactive pause() shell lifecycle
        let shellStartEvents = parser.feed(line: "Interactive shell started", isStderr: false)
        XCTAssertTrue(shellStartEvents.contains(.interactiveShellState(active: true)))

        let shellExitEvents = parser.feed(line: "Exiting interactive shell", isStderr: false)
        XCTAssertTrue(shellExitEvents.contains(.interactiveShellState(active: false)))
    }

    // MARK: - 4. Real Node.js CDP Breakpoint, Scope Inspection, Eval & StepOver

    func testCDPInspectorClientRealNodeBreakpointStepAndEval() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("ceptra-cdp-e2e-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        let toolchain = NodeToolchainResolver.resolve(workspaceRoot: sandbox)
        guard let nodePath = toolchain.nodePath else {
            throw XCTSkip("Node binary not available in test environment")
        }

        let scriptURL = sandbox.appendingPathComponent("calc.mjs")
        let scriptSource = """
        function compute(a, b) {
          const total = a + b;
          const doubled = total * 2;
          return doubled;
        }
        const result = compute(17, 25);
        console.log('DONE:' + result);
        """
        try scriptSource.write(to: scriptURL, atomically: true, encoding: .utf8)

        let targetLine = 2 // `const total = a + b;`
        let breakpoint = DebugBreakpoint(filePath: scriptURL.path, line: targetLine)

        let runner = TestRunnerService()
        defer { runner.cancel() }

        var inspectorContinuation: AsyncStream<URL>.Continuation?
        let inspectorStream = AsyncStream<URL> { cont in
            inspectorContinuation = cont
        }
        let capturedCont = inspectorContinuation

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolchain.searchPath
        env["NODE_OPTIONS"] = "--inspect-brk=127.0.0.1:0"

        let command = BuiltCommand(
            executablePath: nodePath,
            arguments: [scriptURL.path],
            workingDirectory: sandbox,
            environment: env,
            displayCommand: "node \(scriptURL.lastPathComponent)"
        )

        let client = CDPInspectorClient()
        defer { Task { await client.disconnect() } }

        let runTask = Task {
            try await runner.execute(command: command) { event in
                switch event {
                case .inspectorListening(let url):
                    capturedCont?.yield(url)
                    capturedCont?.finish()
                case .inspectorWaitingToDisconnect:
                    Task { await client.disconnect() }
                default:
                    break
                }
            }
        }

        let inspectorURL = try await awaitFirstURL(from: inspectorStream, timeoutSeconds: 10)

        try await client.connect(to: inspectorURL)
        try await client.enableDebugger(breakpoints: [breakpoint], exceptionMode: .none)

        var hitBreakpointFrame: DebugCallFrame?
        var steppedLine: Int?

        let debugTask = Task {
            for await event in client.events {
                switch event {
                case .paused(_, let frames, _):
                    guard let top = frames.first else {
                        try await client.resume()
                        continue
                    }

                    if hitBreakpointFrame == nil {
                        // Auto-resume initial `--inspect-brk` pause until we hit our target breakpoint line
                        if top.location.filePath == breakpoint.filePath && top.location.line == targetLine {
                            hitBreakpointFrame = top

                            // Inspect local variables
                            let localScope = try XCTUnwrap(
                                top.scopes.first(where: { $0.type == "local" }) ?? top.scopes.first,
                                "Expected a local scope at breakpoint"
                            )
                            let props = try await client.getProperties(objectId: localScope.objectId)
                            let propMap = Dictionary(uniqueKeysWithValues: props.map { ($0.name, $0.value) })
                            XCTAssertEqual(propMap["a"], "17")
                            XCTAssertEqual(propMap["b"], "25")

                            // Evaluate expression on paused call frame
                            let evalResult = try await client.evaluateOnCallFrame(callFrameId: top.id, expression: "a + b")
                            XCTAssertFalse(evalResult.isError)
                            XCTAssertEqual(evalResult.value, "42")

                            // Step over to line 3
                            try await client.stepOver()
                        } else {
                            try await client.resume()
                        }
                    } else if steppedLine == nil {
                        steppedLine = top.location.line
                        try await client.resume()
                        return
                    }

                case .disconnected:
                    return

                case .scriptParsed, .resumed:
                    break
                }
            }
        }

        try await awaitWithTimeout(seconds: 8, onTimeout: {
            debugTask.cancel()
            runner.cancel()
            Task { await client.disconnect() }
        }) {
            try await debugTask.value
        }

        let result = try await runTask.value
        XCTAssertNotNil(hitBreakpointFrame, "Expected to pause at breakpoint on line \(targetLine)")
        XCTAssertEqual(hitBreakpointFrame?.location.line, targetLine)
        XCTAssertEqual(steppedLine, 3, "Expected stepOver() to advance to line 3")
        XCTAssertEqual(result.exitCode, 0, "Expected Node process to exit 0, output: \(result.rawOutput)")
        XCTAssertTrue(result.rawOutput.contains("DONE:84"), "Unexpected stdout: \(result.rawOutput)")
    }

    // MARK: - 5. Real Node.js Inline SourceMap (.temp.mjs -> Original .ts)

    func testCDPInspectorClientSourceMapTempMjsMapsToOriginalTypeScript() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("ceptra-cdp-sourcemap-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        let toolchain = NodeToolchainResolver.resolve(workspaceRoot: sandbox)
        guard let nodePath = toolchain.nodePath else {
            throw XCTSkip("Node binary not available in test environment")
        }

        let originalTSURL = sandbox.appendingPathComponent("fake_test.ts")
        let originalTSSource = """
        function greet(name: string) {
          const msg = `hello ${name}`;
          return msg;
        }
        console.log(greet('ceptra'));
        """
        try originalTSSource.write(to: originalTSURL, atomically: true, encoding: .utf8)

        // Offset generated `.temp.mjs` by +2 lines compared to `fake_test.ts`
        // genLine 0, 1: header comments (unmapped)
        // genLine 2 -> origLine 0 ("AAAA")
        // genLine 3 -> origLine 1 ("AACA")  <-- fake_test.ts line 2
        // genLine 4 -> origLine 2 ("AACA")
        // genLine 5 -> origLine 3 ("AACA")
        // genLine 6 -> origLine 4 ("AACA")
        let sourceMapObj: [String: Any] = [
            "version": 3,
            "sources": [originalTSURL.path],
            "mappings": ";;AAAA;AACA;AACA;AACA;AACA"
        ]
        let sourceMapData = try JSONSerialization.data(withJSONObject: sourceMapObj)
        let sourceMapB64 = sourceMapData.base64EncodedString()

        let tempMjsURL = sandbox.appendingPathComponent("fake_test.123.temp.mjs")
        let tempMjsSource = """
        // generated header line 1
        // generated header line 2
        function greet(name) {
          const msg = `hello ${name}`;
          return msg;
        }
        console.log(greet('ceptra'));
        //# sourceMappingURL=data:application/json;charset=utf-8;base64,\(sourceMapB64)
        """
        try tempMjsSource.write(to: tempMjsURL, atomically: true, encoding: .utf8)

        let breakpoint = DebugBreakpoint(filePath: originalTSURL.path, line: 2)

        let runner = TestRunnerService()
        defer { runner.cancel() }

        var inspectorContinuation: AsyncStream<URL>.Continuation?
        let inspectorStream = AsyncStream<URL> { cont in
            inspectorContinuation = cont
        }
        let capturedCont = inspectorContinuation

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolchain.searchPath

        let command = BuiltCommand(
            executablePath: nodePath,
            arguments: ["--inspect-brk=127.0.0.1:0", tempMjsURL.path],
            workingDirectory: sandbox,
            environment: env,
            displayCommand: "node --inspect-brk=127.0.0.1:0 \(tempMjsURL.lastPathComponent)"
        )

        let client = CDPInspectorClient()
        defer { Task { await client.disconnect() } }

        let runTask = Task {
            try await runner.execute(command: command) { event in
                switch event {
                case .inspectorListening(let url):
                    capturedCont?.yield(url)
                    capturedCont?.finish()
                case .inspectorWaitingToDisconnect:
                    Task { await client.disconnect() }
                default:
                    break
                }
            }
        }

        let inspectorURL = try await awaitFirstURL(from: inspectorStream, timeoutSeconds: 10)

        try await client.connect(to: inspectorURL)
        try await client.enableDebugger(breakpoints: [breakpoint], exceptionMode: .none)

        var mappedFrame: DebugCallFrame?

        let debugTask = Task {
            for await event in client.events {
                switch event {
                case .paused(_, let frames, _):
                    guard let top = frames.first else {
                        try await client.resume()
                        continue
                    }

                    if top.location.filePath == originalTSURL.path && top.location.line == 2 {
                        mappedFrame = top
                        try await client.resume()
                        return
                    } else {
                        try await client.resume()
                    }

                case .disconnected:
                    return

                case .scriptParsed, .resumed:
                    break
                }
            }
        }

        try await awaitWithTimeout(seconds: 8, onTimeout: {
            debugTask.cancel()
            runner.cancel()
            Task { await client.disconnect() }
        }) {
            try await debugTask.value
        }

        let result = try await runTask.value
        XCTAssertEqual(mappedFrame?.location.filePath, originalTSURL.path)
        XCTAssertEqual(mappedFrame?.location.line, 2)
        XCTAssertEqual(result.exitCode, 0, "Expected Node process to exit 0, output: \(result.rawOutput)")
        XCTAssertTrue(result.rawOutput.contains("hello ceptra"), "Unexpected stdout: \(result.rawOutput)")
    }

    // MARK: - 6. TestRunnerService Interactive Stdin Round-Trip

    func testTestRunnerServiceInteractiveStdinRoundTrip() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("ceptra-stdin-e2e-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        let toolchain = NodeToolchainResolver.resolve(workspaceRoot: sandbox)
        guard let nodePath = toolchain.nodePath else {
            throw XCTSkip("Node binary not available in test environment")
        }

        let scriptURL = sandbox.appendingPathComponent("echo_repl.mjs")
        let scriptSource = """
        import readline from 'node:readline';
        const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });
        console.log('READY');
        rl.on('line', (line) => {
          const trimmed = line.trim();
          if (trimmed === 'exit') {
            rl.close();
            process.exit(0);
          }
          console.log('ECHO:' + trimmed);
        });
        """
        try scriptSource.write(to: scriptURL, atomically: true, encoding: .utf8)

        let runner = TestRunnerService()
        defer { runner.cancel() }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolchain.searchPath

        let command = BuiltCommand(
            executablePath: nodePath,
            arguments: [scriptURL.path],
            workingDirectory: sandbox,
            environment: env,
            displayCommand: "node \(scriptURL.lastPathComponent)"
        )

        let result = try await awaitWithTimeout(seconds: 8, onTimeout: { runner.cancel() }) {
            try await runner.execute(command: command, attachStdin: true) { event in
                if case .logLine(let text, let isError) = event, !isError {
                    if text.contains("READY") {
                        runner.sendStdin("hello-ceptra\n")
                    } else if text.contains("ECHO:hello-ceptra") {
                        runner.sendStdin("exit\n")
                    }
                }
            }
        }

        XCTAssertEqual(result.exitCode, 0, "Expected exit 0, output: \(result.rawOutput)")
        XCTAssertTrue(result.rawOutput.contains("ECHO:hello-ceptra"), "Expected echoed line in stdout: \(result.rawOutput)")
    }

    // MARK: - Helpers

    private func awaitFirstURL(from stream: AsyncStream<URL>, timeoutSeconds: Double) async throws -> URL {
        try await awaitWithTimeout(seconds: timeoutSeconds) {
            for await url in stream {
                return url
            }
            throw NSError(domain: "DebugModeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Inspector stream ended before URL was emitted"])
        }
    }

    private func awaitWithTimeout<T: Sendable>(
        seconds: Double,
        onTimeout: (@Sendable () -> Void)? = nil,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                onTimeout?()
                throw NSError(domain: "DebugModeTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out after \(seconds)s"])
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
