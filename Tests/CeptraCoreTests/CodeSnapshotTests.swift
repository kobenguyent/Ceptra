import AppKit
import CeptraCore
import XCTest

final class CodeSnapshotTests: XCTestCase {
    func testExtractsSmartCodeBlockAndSelectionWithAutoDedent() {
        let source = """
        import { loginPage } from '../support/pageObjects/loginPage';
        const { I } = inject();

        Feature('Login');

        Scenario('User logs in successfully', () => {
          I.amOnPage('/');
          loginPage.login('student', secret('Password123'));
          I.see('Logged In Successfully');
        });

        Scenario('Invalid password shows error', () => {
          const creds = {
            user: 'student',
            pass: 'wrong',
          };
          I.amOnPage('/');
          loginPage.login(creds.user, creds.pass);
        });
        """

        // 1. Caret inside Scenario #1 (no selection) extracts exact Scenario block lines 6..10
        let block1 = CodeSnapshotEngine.extract(
            from: source,
            language: "typescript",
            selectedRange: NSRange(location: 0, length: 0),
            caretLine: 8
        )
        XCTAssertEqual(block1.scope, .currentBlock)
        XCTAssertEqual(block1.startLineNumber, 6)
        XCTAssertEqual(block1.endLineNumber, 10)
        XCTAssertEqual(block1.blockLabel, "User logs in successfully")
        XCTAssertTrue(block1.code.hasPrefix("Scenario('User logs in successfully'"))
        XCTAssertTrue(block1.code.hasSuffix("});"))

        // 2. Caret inside small inner object `{ user, pass }` inside Scenario #2 expands cleanly to enclosing Scenario #2
        let block2 = CodeSnapshotEngine.extract(
            from: source,
            language: "typescript",
            selectedRange: NSRange(location: 0, length: 0),
            caretLine: 14
        )
        XCTAssertEqual(block2.startLineNumber, 12)
        XCTAssertEqual(block2.endLineNumber, 19)
        XCTAssertEqual(block2.blockLabel, "Invalid password shows error")

        // 3. Explicit mid-line selection across lines 7..9 expands cleanly to full lines and dedents 2 leading spaces
        let ns = source as NSString
        let selStart = ns.range(of: "amOnPage").location
        let selEnd = NSMaxRange(ns.range(of: "Logged In Successfully"))
        let selExtraction = CodeSnapshotEngine.extract(
            from: source,
            language: "typescript",
            selectedRange: NSRange(location: selStart, length: selEnd - selStart),
            caretLine: 7,
            autoDedent: true
        )
        XCTAssertEqual(selExtraction.scope, .selection)
        XCTAssertEqual(selExtraction.startLineNumber, 7)
        XCTAssertEqual(selExtraction.endLineNumber, 9)
        XCTAssertTrue(selExtraction.code.hasPrefix("I.amOnPage('/');"), "Expected common 2-space indent stripped: \(selExtraction.code)")
        XCTAssertEqual(selExtraction.rawCode.prefix(2), "  ")

        // 4. Suggested filename includes line range for partial captures and omits range for full file
        XCTAssertEqual(CodeSnapshotEngine.suggestedFilename(fileName: "login_test.ts", extraction: selExtraction), "login_test-L7-L9.png")
        let fullExtraction = CodeSnapshotEngine.extract(
            from: source,
            language: "typescript",
            selectedRange: NSRange(location: 0, length: 0),
            caretLine: 1,
            preferredScope: .fullFile
        )
        XCTAssertEqual(CodeSnapshotEngine.suggestedFilename(fileName: "login_test.ts", extraction: fullExtraction), "login_test.png")
    }

    func testGherkinExtractionIncludesPrecedingTagsAndTokenizesCleanly() {
        let feature = """
        @smoke
        Feature: Checkout

          @critical @web
          Scenario: Complete order
            Given I am on "/cart"
            When I click "Checkout"
            Then I see "Thank you"
        """
        let extracted = CodeSnapshotEngine.extract(
            from: feature,
            language: "gherkin",
            selectedRange: NSRange(location: 0, length: 0),
            caretLine: 6
        )
        XCTAssertEqual(extracted.startLineNumber, 4)
        XCTAssertEqual(extracted.endLineNumber, 8)
        XCTAssertTrue(extracted.code.hasPrefix("@critical @web"))
        XCTAssertEqual(extracted.blockLabel, "Complete order")

        let spans = CodeSnapshotEngine.tokenize(code: extracted.code, language: "gherkin")
        XCTAssertTrue(spans.contains(where: { $0.kind == .tag }))
        XCTAssertTrue(spans.contains(where: { $0.kind == .dsl }))
        XCTAssertTrue(spans.contains(where: { $0.kind == .actor }))
        XCTAssertTrue(spans.contains(where: { $0.kind == .string }))
    }

    func testRendersCrispRetinaPNGForGradientAndTransparentPresets() throws {
        let code = """
        Scenario('Login via API @api', async ({ I }) => {
          const res = await I.sendPostRequest('/auth/login', {
            username: 'emilys',
            password: secret('emilyspass'),
          });
          I.seeResponseCodeIs(200);
        });
        """
        let extraction = CodeSnapshotExtraction(
            code: code,
            rawCode: code,
            startLineNumber: 5,
            endLineNumber: 11,
            scope: .currentBlock,
            blockLabel: "Login via API @api"
        )

        // 1. 2x Candy + Obsidian PNG
        let style2x = CodeSnapshotStyle(
            background: .candy,
            theme: .obsidian,
            windowChrome: .macOS,
            padding: .cozy,
            fontSize: 14,
            scale: 2,
            showLineNumbers: true,
            showTitle: true,
            showLanguageBadge: true,
            showWatermark: true
        )
        let rendered2x = try XCTUnwrap(CodeSnapshotRenderer.render(
            extraction: extraction,
            language: "typescript",
            title: "login_test.ts",
            style: style2x
        ))
        // Verify valid PNG signature (89 50 4E 47 0D 0A 1A 0A)
        XCTAssertGreaterThan(rendered2x.pngData.count, 4096)
        XCTAssertEqual(Array(rendered2x.pngData.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(rendered2x.scale, 2)
        XCTAssertEqual(rendered2x.pixelSize.width, rendered2x.logicalSize.width * 2, accuracy: 1.0)
        XCTAssertEqual(rendered2x.pixelSize.height, rendered2x.logicalSize.height * 2, accuracy: 1.0)

        let rep2x = try XCTUnwrap(NSBitmapImageRep(data: rendered2x.pngData))
        XCTAssertEqual(rep2x.pixelsWide, Int(rendered2x.pixelSize.width))
        XCTAssertEqual(rep2x.pixelsHigh, Int(rendered2x.pixelSize.height))
        // Top-left corner on gradient backdrop must be opaque
        let cornerOpaque = try XCTUnwrap(rep2x.colorAt(x: 4, y: 4))
        XCTAssertGreaterThan(cornerOpaque.alphaComponent, 0.95)

        // 2. 3x Transparent + Paper Light PNG preserves transparent corners
        let styleTransparent = CodeSnapshotStyle(
            background: .transparent,
            theme: .paperLight,
            windowChrome: .minimal,
            padding: .compact,
            fontSize: 15,
            scale: 3,
            showLineNumbers: false,
            showTitle: true,
            showLanguageBadge: true,
            showWatermark: false
        )
        let rendered3x = try XCTUnwrap(CodeSnapshotRenderer.render(
            extraction: extraction,
            language: "typescript",
            title: "tests/api/tests/login_test.ts",
            style: styleTransparent
        ))
        XCTAssertEqual(rendered3x.scale, 3)
        let rep3x = try XCTUnwrap(NSBitmapImageRep(data: rendered3x.pngData))
        XCTAssertEqual(rep3x.pixelsWide, Int(rendered3x.pixelSize.width))
        let cornerTransparent = try XCTUnwrap(rep3x.colorAt(x: 2, y: 2))
        XCTAssertLessThan(cornerTransparent.alphaComponent, 0.05, "Transparent preset must keep transparent canvas corners")

        // 3. AppSettings backward-compatible decoding + persistence round-trip
        let legacyJSON = #"{"recentProjectPaths":[],"editorFontSize":13}"#.data(using: .utf8)!
        let decodedLegacy = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)
        XCTAssertEqual(decodedLegacy.codeSnapshotStyle, CodeSnapshotStyle())

        var modified = decodedLegacy
        modified.codeSnapshotStyle = styleTransparent
        let roundTripped = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(modified))
        XCTAssertEqual(roundTripped.codeSnapshotStyle, styleTransparent)
    }
}
