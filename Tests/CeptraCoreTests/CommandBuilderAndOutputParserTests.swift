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
