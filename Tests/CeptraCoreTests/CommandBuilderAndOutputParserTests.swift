import CeptraCore
import XCTest

final class CommandBuilderAndOutputParserTests: XCTestCase {
    func testBuildsCodecept4CommandsAccurately() {
        let root = URL(fileURLWithPath: "/tmp/demo")
        let toolchain = ResolvedToolchain(
            nodePath: "/opt/homebrew/bin/node",
            codeceptExecutable: "/tmp/demo/node_modules/.bin/codeceptjs",
            prefixArguments: [],
            searchPath: "/opt/homebrew/bin:/usr/bin",
            resolutionSource: "Project node_modules"
        )

        var options = RunOptions()
        options.showSteps = true
        options.debug = true
        options.enabledPlugins = ["junitReporter", "aiTrace"]
        options.profile = "chromium"

        let scenarioCmd = CommandBuilder.build(
            mode: .runScenario(relativePath: "src/GET_test.ts", scenarioTitle: "Verify (single) user"),
            options: options,
            workspaceRoot: root,
            configFilePath: "/tmp/demo/codecept.conf.ts",
            toolchain: toolchain
        )

        XCTAssertEqual(scenarioCmd.arguments[0], "run")
        XCTAssertEqual(scenarioCmd.arguments[1], "src/GET_test.ts")
        XCTAssertTrue(scenarioCmd.arguments.contains("--steps"))
        XCTAssertTrue(scenarioCmd.arguments.contains("--debug"))
        XCTAssertTrue(scenarioCmd.arguments.contains("--profile"))
        XCTAssertTrue(scenarioCmd.arguments.contains("chromium"))
        XCTAssertTrue(scenarioCmd.arguments.contains("-p"))
        XCTAssertTrue(scenarioCmd.arguments.contains("junitReporter,aiTrace"))
        XCTAssertTrue(scenarioCmd.arguments.contains(#"Verify \(single\) user"#))

        let workersCmd = CommandBuilder.build(
            mode: .runWorkers(count: 4, strategy: .pool),
            options: options,
            workspaceRoot: root,
            configFilePath: nil,
            toolchain: toolchain
        )
        XCTAssertEqual(Array(workersCmd.arguments.prefix(4)), ["run-workers", "4", "--by", "pool"])

        // Full run-workers with selectedRuns, --serial, --last-failed, and --invert
        var workerOpts = options
        workerOpts.grepPattern = "@slow"
        workerOpts.invertGrep = true
        let fullWorkersCmd = CommandBuilder.build(
            mode: .runWorkers(
                count: 6,
                strategy: .suite,
                selectedRuns: ["smoke:chromium", "regression"],
                serialPattern: "@serial",
                lastFailed: true
            ),
            options: workerOpts,
            workspaceRoot: root,
            configFilePath: "/tmp/demo/codecept.conf.ts",
            toolchain: toolchain
        )
        XCTAssertEqual(Array(fullWorkersCmd.arguments.prefix(6)), ["run-workers", "6", "smoke:chromium", "regression", "--by", "suite"])
        XCTAssertTrue(fullWorkersCmd.arguments.contains("--serial"))
        XCTAssertTrue(fullWorkersCmd.arguments.contains("@serial"))
        XCTAssertTrue(fullWorkersCmd.arguments.contains("--last-failed"))
        XCTAssertTrue(fullWorkersCmd.arguments.contains("--invert"))

        // run-multiple --all
        let multipleAllCmd = CommandBuilder.build(
            mode: .runMultiple(suites: [], runAll: true),
            options: options,
            workspaceRoot: root,
            configFilePath: "/tmp/demo/codecept.conf.ts",
            toolchain: toolchain
        )
        XCTAssertEqual(Array(multipleAllCmd.arguments.prefix(2)), ["run-multiple", "--all"])
        XCTAssertTrue(multipleAllCmd.arguments.contains("--steps"))
        XCTAssertTrue(multipleAllCmd.arguments.contains("-c"))
        XCTAssertTrue(multipleAllCmd.arguments.contains("/tmp/demo/codecept.conf.ts"))

        // run-multiple with explicit suites / suite:browser targets
        let multipleSelectedCmd = CommandBuilder.build(
            mode: .runMultiple(suites: ["smoke:chromium", "basic:firefox"], runAll: false),
            options: workerOpts,
            workspaceRoot: root,
            configFilePath: "/tmp/demo/codecept.conf.ts",
            toolchain: toolchain
        )
        XCTAssertEqual(Array(multipleSelectedCmd.arguments.prefix(3)), ["run-multiple", "smoke:chromium", "basic:firefox"])
        XCTAssertFalse(multipleSelectedCmd.arguments.contains("--all"))
        XCTAssertTrue(multipleSelectedCmd.arguments.contains("--invert"))

        // When config is in a custom nested subdirectory, test file path resolves to absolute so CodeceptJS
        // finds it even though store.codeceptDir = dirname(configFile)
        let nestedConfigCmd = CommandBuilder.build(
            mode: .runFile(relativePath: "tests/checkout_test.ts"),
            options: options,
            workspaceRoot: root,
            configFilePath: "/tmp/demo/configs/staging.conf.ts",
            toolchain: toolchain
        )
        XCTAssertEqual(nestedConfigCmd.arguments[1], "/tmp/demo/tests/checkout_test.ts")
        XCTAssertTrue(nestedConfigCmd.arguments.contains("/tmp/demo/configs/staging.conf.ts"))
    }

    func testDetectsPackageManagersReadsScriptsAndBuildsDependencyCommands() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ceptra-pm-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Default npm + scripts
        let pkg = """
        {
          "name": "pm-test",
          "scripts": {
            "def": "codeceptjs def",
            "lint": "eslint ."
          }
        }
        """
        try pkg.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(PackageManagerSupport.detectPackageManager(in: root), .npm)
        XCTAssertEqual(PackageManagerSupport.readPackageScripts(in: root).map(\.name), ["def", "lint"])

        // Lockfile detection (pnpm)
        try "lockfileVersion: '9.0'\n".write(to: root.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(PackageManagerSupport.detectPackageManager(in: root), .pnpm)

        // packageManager field takes precedence (bun)
        let bunPkg = """
        {
          "name": "pm-test",
          "packageManager": "bun@1.2.0"
        }
        """
        try bunPkg.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(PackageManagerSupport.detectPackageManager(in: root), .bun)

        let toolchain = NodeToolchainResolver.resolve(workspaceRoot: root)
        let updateCmd = PackageManagerSupport.buildCommand(
            action: .update,
            packageManager: .npm,
            workspaceRoot: root,
            toolchain: toolchain
        )
        XCTAssertEqual(updateCmd.displayCommand, "npm update")
        XCTAssertTrue(updateCmd.arguments.contains("update"))

        let upgradeCmd = PackageManagerSupport.buildCommand(
            action: .upgradeCodeceptJS,
            packageManager: .pnpm,
            workspaceRoot: root,
            toolchain: toolchain
        )
        XCTAssertEqual(upgradeCmd.displayCommand, "pnpm add -D codeceptjs@latest")

        let shellCmd = PackageManagerSupport.buildCommand(
            action: .customShell(command: "npm install -D @codeceptjs/configure"),
            packageManager: .npm,
            workspaceRoot: root,
            toolchain: toolchain
        )
        XCTAssertEqual(shellCmd.executablePath, "/bin/zsh")
        XCTAssertEqual(shellCmd.arguments, ["-c", "npm install -D @codeceptjs/configure"])
        XCTAssertEqual(shellCmd.workingDirectory, root)
    }

    func testNodeCompatLoaderFixesNamedImportFromCommonJSUuidPackage() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("ceptra-uuid-compat-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sandbox.appendingPathComponent("node_modules/uuid"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        // CJS-only uuid package using Object.defineProperty getter exports (fails native ESM `import { v4 as uuid4 } from 'uuid'`)
        try #"{"name":"uuid","version":"8.3.2","main":"./index.js"}"#
            .write(to: sandbox.appendingPathComponent("node_modules/uuid/package.json"), atomically: true, encoding: .utf8)
        let uuidCJS = """
        "use strict";
        Object.defineProperty(exports, "__esModule", { value: true });
        Object.defineProperty(exports, "v4", {
          enumerable: true,
          get: function () { return function () { return "ceptra-uuid-v4-ok"; }; }
        });
        """
        try uuidCJS.write(to: sandbox.appendingPathComponent("node_modules/uuid/index.js"), atomically: true, encoding: .utf8)

        let mjsEntry = sandbox.appendingPathComponent("check.mjs")
        try "import { v4 as uuid4 } from 'uuid'; console.log(uuid4());\n"
            .write(to: mjsEntry, atomically: true, encoding: .utf8)

        let toolchain = NodeToolchainResolver.resolve(workspaceRoot: sandbox)
        guard let nodePath = toolchain.nodePath else {
            throw XCTSkip("Node binary not available in test environment")
        }

        // Verify CommandBuilder injects NODE_OPTIONS --import preload when esmCjsCompat == true
        let built = CommandBuilder.build(
            mode: .runAll,
            options: RunOptions(esmCjsCompat: true),
            workspaceRoot: sandbox,
            toolchain: toolchain
        )
        let nodeOptions = try XCTUnwrap(built.environment["NODE_OPTIONS"])
        XCTAssertTrue(nodeOptions.contains("--import file://"))
        XCTAssertTrue(nodeOptions.contains("ceptra-cjs-interop-preload.mjs"))

        // Execute real Node process with the injected NODE_OPTIONS and verify `import { v4 as uuid4 } from 'uuid'` succeeds!
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [mjsEntry.path]
        proc.currentDirectoryURL = sandbox
        proc.environment = built.environment
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        try proc.run()
        proc.waitUntilExit()

        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(proc.terminationStatus, 0, "Expected exit 0, got output: \(output)")
        XCTAssertTrue(output.contains("ceptra-uuid-v4-ok"), "Unexpected output: \(output)")
    }

    func testParsesLiveStepsAndCompactCodeceptOutput() {
        let parser = LiveOutputParser()
        let lines = [
            "CodeceptJS v4.0.3",
            "GET tests --",
            "/tmp/demo/src/GET_test.ts",
            "  Verify getting a single user @api",
            "    I sendGetRequest \"/users/2\"",
            "    I seeResponseCodeIsSuccessful",
            "  ✔ OK in 48ms",
            "  Verify not found error",
            "    I sendGetRequest \"/users/999\"",
            "    I seeResponseCodeIs 200",
            "  ✖ FAILED in 112ms",
            "  S Skipped pending test",
            "FAIL  | 1 passed, 1 failed, 1 skipped   // 1s"
        ]

        var sawSummary = false
        for line in lines {
            let events = parser.feed(line: line)
            for event in events {
                if case .summary(let p, let f, let s, _) = event {
                    XCTAssertEqual(p, 1)
                    XCTAssertEqual(f, 1)
                    XCTAssertEqual(s, 1)
                    sawSummary = true
                }
            }
        }

        XCTAssertTrue(sawSummary)
        XCTAssertEqual(parser.scenarios.count, 3)
        XCTAssertEqual(parser.scenarios[0].status, .passed)
        XCTAssertEqual(parser.scenarios[0].durationMs, 48)
        XCTAssertEqual(parser.scenarios[0].steps.count, 2)
        XCTAssertEqual(parser.scenarios[0].tags, ["@api"])
        XCTAssertEqual(parser.scenarios[1].status, .failed)
        XCTAssertEqual(parser.scenarios[1].steps.last?.status, .failed)
        XCTAssertEqual(parser.scenarios[2].status, .skipped)
    }
}
