import CeptraCore
import XCTest

final class CodeFoldingEngineTests: XCTestCase {
    func testDetectsJSAndCodeceptJSFoldRegionsIgnoringStringsAndComments() throws {
        let code = """
        import { expect } from 'chai';
        import { v4 as uuid4 } from 'uuid';
        import loginPage from './pages/LoginPage';

        /*
         * Multi-line header comment
         */
        Feature('Checkout Flow @smoke');

        Scenario('completes checkout with braces in string "}{"', async ({ I }) => {
          const payload = {
            id: uuid4(),
            items: [
              'sku-1',
              'sku-2',
            ],
          };
          I.amOnPage('/checkout');
          I.see('{not a fold}');
        });
        """

        let table = LineIndexTable(text: code)
        XCTAssertEqual(table.lineCount, 20)
        XCTAssertEqual(table.lineNumber(forUTF16Offset: 0), 1)

        let regions = CodeFoldingEngine.detectRegions(in: code, language: "typescript", lineIndex: table)
        let byStart = Dictionary(uniqueKeysWithValues: regions.map { ($0.startLine, $0) })

        // Consecutive imports (lines 1..3)
        XCTAssertEqual(byStart[1]?.kind, .imports)
        XCTAssertEqual(byStart[1]?.endLine, 3)

        // Multi-line block comment (lines 5..7)
        XCTAssertEqual(byStart[5]?.kind, .comment)
        XCTAssertEqual(byStart[5]?.endLine, 7)

        // Outer Scenario block (lines 10..20)
        let scenario = try XCTUnwrap(byStart[10])
        XCTAssertEqual(scenario.endLine, 20)
        XCTAssertEqual(scenario.hiddenLineCount, 10)

        // Nested payload object (lines 11..17) and items array (lines 13..16)
        XCTAssertEqual(byStart[11]?.endLine, 17)
        XCTAssertEqual(byStart[11]?.kind, .block)
        XCTAssertEqual(byStart[13]?.endLine, 16)
        XCTAssertEqual(byStart[13]?.kind, .array)

        // Braces inside string on line 19 must not create a fold region
        XCTAssertNil(byStart[19])

        // Merging nested collapsed ranges (lines 10..20 and 13..16) yields single disjoint hidden range
        let merged = CodeFoldingEngine.mergedHiddenRanges(regions: regions, collapsedStartLines: [10, 13])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0], scenario.hiddenRange)

        // Auto-unfold lookup when jumping to line 14 inside collapsed scenario & nested object
        let hiding14 = CodeFoldingEngine.collapsedStartLinesHiding(line: 14, regions: regions, collapsedStartLines: [10, 11])
        XCTAssertEqual(hiding14, [10, 11])

        // Innermost region for caret on line 14 is the items array (13..16)
        XCTAssertEqual(CodeFoldingEngine.innermostRegion(containingLine: 14, in: regions)?.startLine, 13)
    }

    func testDetectsGherkinYAMLAndMarkdownFoldRegions() {
        let gherkin = """
        Feature: Auth
          Background:
            Given I open login

          Scenario: Valid user
            When I sign in
            Then I see dashboard
        """
        let gherkinRegions = CodeFoldingEngine.detectRegions(in: gherkin, language: "gherkin")
        let gMap = Dictionary(uniqueKeysWithValues: gherkinRegions.map { ($0.startLine, $0.endLine) })
        XCTAssertEqual(gMap[1], 7) // Feature
        XCTAssertEqual(gMap[2], 3) // Background
        XCTAssertEqual(gMap[5], 7) // Scenario

        let yaml = """
        jobs:
          test:
            runs-on: macos-15
            steps:
              - run: swift test
        """
        let yamlRegions = CodeFoldingEngine.detectRegions(in: yaml, language: "yaml")
        let yMap = Dictionary(uniqueKeysWithValues: yamlRegions.map { ($0.startLine, $0.endLine) })
        XCTAssertEqual(yMap[1], 5)
        XCTAssertEqual(yMap[2], 5)
        XCTAssertEqual(yMap[4], 5)

        let md = """
        # Title
        Intro text

        ## Section A
        ```js
        Scenario('x', () => {});
        ```

        ## Section B
        Body
        """
        let mdRegions = CodeFoldingEngine.detectRegions(in: md, language: "markdown")
        let mMap = Dictionary(uniqueKeysWithValues: mdRegions.map { ($0.startLine, $0.endLine) })
        XCTAssertEqual(mMap[1], 10) // # Title
        XCTAssertEqual(mMap[4], 7)  // ## Section A
        XCTAssertEqual(mMap[5], 7)  // ```js fence
        XCTAssertEqual(mMap[9], 10) // ## Section B
    }

    func testHandlesCRLFAndTrailingNewlineLineNumbersAccurately() {
        let crlf = "Feature('A');\r\nScenario('B', () => {\r\n  I.see('ok');\r\n});\r\n"
        let table = LineIndexTable(text: crlf)
        // 4 lines + 1 empty trailing line = 5 lines
        XCTAssertEqual(table.lineCount, 5)
        XCTAssertEqual(table.lineNumber(forUTF16Offset: 0), 1)
        XCTAssertEqual(table.lineNumber(forUTF16Offset: table.lineStarts[1]), 2)
        XCTAssertEqual(table.lineNumber(forUTF16Offset: table.lineStarts[4]), 5)

        let regions = CodeFoldingEngine.detectRegions(in: crlf, language: "javascript", lineIndex: table)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].startLine, 2)
        XCTAssertEqual(regions[0].endLine, 4)

        let hiddenText = (crlf as NSString).substring(with: regions[0].hiddenRange)
        XCTAssertTrue(hiddenText.hasPrefix("\r\n"))
        XCTAssertTrue(hiddenText.hasSuffix("});"))
    }
}
