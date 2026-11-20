import CeptraCore
import XCTest

final class JUnitAndArtifactTests: XCTestCase {
    func testParsesCodecept4JUnitXMLWithStepsMetaAndFailure() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuites name="CodeceptJS" tests="2" failures="1" skipped="0" time="0.542">
          <testsuite name="Checkout" tests="2" failures="1" skipped="0" file="/repo/checkout_test.js">
            <testcase classname="Checkout" name="fills form @smoke" time="0.210" file="/repo/checkout_test.js">
              <properties>
                <property name="tags" value="@smoke @fast"/>
              </properties>
              <system-out><![CDATA[I amOnPage "/checkout" (120ms)
          I fillField "#email", "dev@example.com" (45ms)
          I see "Confirmed" (45ms)]]></system-out>
            </testcase>
            <testcase classname="Checkout" name="handles declined card" time="0.332" file="/repo/checkout_test.js">
              <failure message="Expected 'Declined' to be visible" type="AssertionError">AssertionError: Expected 'Declined'</failure>
              <system-out><![CDATA[I click "Pay" (12ms)
        [FAILED] I see "Declined" (320ms)]]></system-out>
            </testcase>
          </testsuite>
        </testsuites>
        """

        let records = JUnitReportParser.parse(xmlData: Data(xml.utf8))
        XCTAssertEqual(records.count, 2)

        XCTAssertEqual(records[0].status, .passed)
        XCTAssertEqual(records[0].durationMs, 210)
        XCTAssertEqual(records[0].tags, ["@fast", "@smoke"])
        XCTAssertEqual(records[0].steps.count, 3)
        XCTAssertEqual(records[0].steps[0].durationMs, 120)
        XCTAssertEqual(records[0].steps[1].depth, 1)

        XCTAssertEqual(records[1].status, .failed)
        XCTAssertEqual(records[1].errorMessage, "Expected 'Declined' to be visible")
        XCTAssertEqual(records[1].steps.last?.status, .failed)
        XCTAssertEqual(records[1].steps.last?.durationMs, 320)
    }

    func testScansArtifactsAndExportsMarkdownAndHTML() throws {
        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("ceptra-artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempOut.appendingPathComponent("traces"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempOut) }

        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: tempOut.appendingPathComponent("failed_step.png"))
        try "# AI Trace\nStep 1".write(to: tempOut.appendingPathComponent("traces/login_trace.md"), atomically: true, encoding: .utf8)
        try "<testsuites></testsuites>".write(to: tempOut.appendingPathComponent("report.xml"), atomically: true, encoding: .utf8)
        try "1\n00:00:00,000 --> 00:00:01,000\nI click Submit".write(to: tempOut.appendingPathComponent("run.srt"), atomically: true, encoding: .utf8)

        let scanned = ArtifactScanner.scan(outputDirectoryURL: tempOut)
        let kinds = Set(scanned.map(\.kind))
        XCTAssertTrue(kinds.contains(.screenshot))
        XCTAssertTrue(kinds.contains(.aiTrace))
        XCTAssertTrue(kinds.contains(.junitXML))
        XCTAssertTrue(kinds.contains(.subtitle))

        let report = TestRunReport(
            projectPath: tempOut.path,
            projectName: "Demo",
            label: "Run All",
            commandLine: "codeceptjs run --steps",
            startedAt: Date(),
            finishedAt: Date().addingTimeInterval(1.2),
            exitCode: 0,
            passedCount: 2,
            failedCount: 0,
            skippedCount: 0,
            durationMs: 1200,
            scenarios: [],
            rawOutput: "OK"
        )
        let md = ReportExporter.toMarkdown(report)
        let html = ReportExporter.toHTML(report)
        XCTAssertTrue(md.contains("# Ceptra Test Report — Demo"))
        XCTAssertTrue(html.contains("<!doctype html>"))
        XCTAssertTrue(html.contains("100%"))
    }
}
