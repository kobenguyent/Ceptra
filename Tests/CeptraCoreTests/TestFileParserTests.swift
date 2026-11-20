import CeptraCore
import XCTest

final class TestFileParserTests: XCTestCase {
    func testParsesCodeceptJSFeaturesHooksScenariosTagsAndSteps() {
        let source = """
        Feature('Checkout Flow @e2e').tag('@critical');

        Before(({ I }) => {
          I.amOnPage('https://example.com/checkout');
        });

        Scenario('completes checkout @smoke', async ({ I }) => {
          I.fillField('#lastName', 'Ada');
          await retryTo(() => {
            I.click('Redeem');
            I.see('Payment');
          }, 3);
          I.click('Checkout');
          I.see('Thank you!');
        });

        xScenario('skipped experiment @wip', ({ I }) => {
          I.amOnPage('/beta');
        });

        Data(users).Scenario('data driven login', async ({ I, current }) => {
          await I.sendPostRequest('/login', current);
          I.seeResponseCodeIsSuccessful();
        });
        """

        let features = TestFileParser.parse(content: source, filePath: "/tmp/checkout_test.js")
        XCTAssertEqual(features.count, 1)

        let feature = features[0]
        XCTAssertEqual(feature.title, "Checkout Flow @e2e")
        XCTAssertEqual(feature.tags, ["@critical", "@e2e"])
        XCTAssertEqual(feature.hooks.count, 1)
        XCTAssertEqual(feature.hooks[0].kind, "Before")
        XCTAssertEqual(feature.hooks[0].steps.count, 1)
        XCTAssertEqual(feature.hooks[0].steps[0].category, .navigation)

        XCTAssertEqual(feature.scenarios.count, 3)

        let first = feature.scenarios[0]
        XCTAssertEqual(first.cleanTitle, "completes checkout")
        XCTAssertEqual(first.tags, ["@smoke"])
        XCTAssertEqual(first.modifier, .standard)
        XCTAssertTrue(first.steps.contains { $0.action == "fillField" && $0.category == .interaction })
        XCTAssertTrue(first.steps.contains { $0.action == "retryTo" && $0.category == .control })
        XCTAssertTrue(first.steps.contains { $0.action == "see" && $0.category == .assertion })

        let skipped = feature.scenarios[1]
        XCTAssertEqual(skipped.modifier, .skip)
        XCTAssertEqual(skipped.tags, ["@wip"])

        let dataDriven = feature.scenarios[2]
        XCTAssertEqual(dataDriven.modifier, .dataDriven)
        XCTAssertTrue(dataDriven.steps.contains { $0.action == "sendPostRequest" && $0.category == .network })
        XCTAssertTrue(dataDriven.steps.contains { $0.action == "seeResponseCodeIsSuccessful" && $0.category == .assertion })
    }

    func testParsesGherkinFeatureFile() {
        let gherkin = """
        @checkout
        Feature: Shopping Cart
          Background:
            Given I open the storefront

          @smoke @fast
          Scenario: Add single item
            When I add "Headphones" to cart
            Then I see 1 item in cart

          Scenario Outline: Bulk pricing
            When I add <qty> items
            Then total equals <total>
        """

        let features = TestFileParser.parse(content: gherkin, filePath: "/tmp/cart.feature")
        XCTAssertEqual(features.count, 1)
        let feature = features[0]
        XCTAssertEqual(feature.title, "Shopping Cart")
        XCTAssertEqual(feature.tags, ["@checkout"])
        XCTAssertEqual(feature.hooks.count, 1)
        XCTAssertEqual(feature.hooks[0].kind, "Background")
        XCTAssertEqual(feature.hooks[0].steps.count, 1)

        XCTAssertEqual(feature.scenarios.count, 2)
        XCTAssertEqual(feature.scenarios[0].title, "Add single item")
        XCTAssertEqual(feature.scenarios[0].tags, ["@fast", "@smoke"])
        XCTAssertEqual(feature.scenarios[0].steps.count, 2)
        XCTAssertEqual(feature.scenarios[0].steps[0].category, .gherkin)
        XCTAssertEqual(feature.scenarios[1].modifier, .outline)
    }
}
