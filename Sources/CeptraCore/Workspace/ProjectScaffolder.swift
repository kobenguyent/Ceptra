import Foundation

public enum ScaffoldTemplateKind: String, CaseIterable, Identifiable, Sendable {
    case jsTest = "CodeceptJS Test (.js)"
    case tsTest = "CodeceptJS Test (.ts)"
    case gherkinFeature = "Gherkin Feature (.feature)"
    case pageObject = "Page Object (.js)"
    case customHelper = "Custom Helper (.js)"

    public var id: String { rawValue }

    public var defaultExtension: String {
        switch self {
        case .jsTest: return "_test.js"
        case .tsTest: return "_test.ts"
        case .gherkinFeature: return ".feature"
        case .pageObject: return "Page.js"
        case .customHelper: return "_helper.js"
        }
    }

    public var suggestedDirectory: String {
        switch self {
        case .jsTest, .tsTest: return "tests"
        case .gherkinFeature: return "features"
        case .pageObject: return "pages"
        case .customHelper: return "helpers"
        }
    }
}

public enum ProjectScaffolder {
    public static func renderTemplate(kind: ScaffoldTemplateKind, name: String) -> String {
        let cleanTitle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleanTitle.isEmpty ? "New Feature" : cleanTitle
        let identifier = sanitizeIdentifier(title)

        switch kind {
        case .jsTest:
            return """
            Feature('\(title)');

            Before(({ I }) => {
              I.amOnPage('/');
            });

            Scenario('loads home experience @smoke', async ({ I }) => {
              I.seeElement('body');
              I.see('\(title)');
            });

            Scenario('completes primary action', async ({ I }) => {
              I.click('Get Started');
              I.waitForText('Welcome', 5);
            });
            """

        case .tsTest:
            return """
            Feature('\(title)');

            Before(({ I }) => {
              I.amOnPage('/');
            });

            Scenario('loads home experience @smoke', async ({ I }) => {
              I.seeElement('body');
              I.see('\(title)');
            });

            Scenario('validates API response @api', async ({ I }) => {
              const res = await I.sendGetRequest('/health');
              I.seeResponseCodeIsSuccessful();
              if (res.status !== 200) {
                throw new Error(`Expected 200, received ${res.status}`);
              }
            });
            """

        case .gherkinFeature:
            return """
            @smoke
            Feature: \(title)
              As a user
              I want to verify \(title.lowercased())
              So that core flows stay reliable

              Background:
                Given I open the application

              Scenario: Primary happy path
                When I navigate to "\(title)"
                Then I should see the main content
            """

        case .pageObject:
            return """
            const { I } = inject();

            export default {
              root: '[data-testid="\(identifier.lowercased())"]',
              fields: {
                search: 'input[type="search"]',
              },
              buttons: {
                submit: 'button[type="submit"]',
              },

              open() {
                I.amOnPage('/\(identifier.lowercased())');
                I.waitForElement(this.root, 10);
              },

              submitQuery(query) {
                I.fillField(this.fields.search, query);
                I.click(this.buttons.submit);
              },
            };
            """

        case .customHelper:
            return """
            import Helper from '@codeceptjs/helper';

            class \(identifier)Helper extends Helper {
              async _before() {
                // Hook before each scenario
              }

              async _failed(test) {
                // Capture extra context on failure
              }

              async checkHealth(endpoint = '/health') {
                const rest = this.helpers['REST'];
                if (!rest) return null;
                return rest.sendGetRequest(endpoint);
              }
            }

            export default \(identifier)Helper;
            """
        }
    }

    /// Scaffolds a ready-to-explore CodeceptJS 4.x sample workspace at `directoryURL`.
    public static func createSampleWorkspace(at directoryURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: directoryURL.appendingPathComponent("tests"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directoryURL.appendingPathComponent("pages"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directoryURL.appendingPathComponent("features"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directoryURL.appendingPathComponent("output"), withIntermediateDirectories: true)

        let packageJSON = """
        {
          "name": "\(directoryURL.lastPathComponent)",
          "version": "1.0.0",
          "type": "module",
          "scripts": {
            "test": "codeceptjs run --steps",
            "test:dry": "codeceptjs dry-run",
            "test:workers": "codeceptjs run-workers 2 --by pool"
          },
          "devDependencies": {
            "codeceptjs": "^4.0.0",
            "playwright": "^1.50.0"
          }
        }
        """

        let configJS = """
        export const config = {
          name: '\(directoryURL.lastPathComponent)',
          tests: './tests/*_test.js',
          output: './output',
          helpers: {
            Playwright: {
              url: 'https://example.com',
              browser: 'chromium',
              show: false,
            },
            REST: {
              endpoint: 'https://jsonplaceholder.typicode.com',
            },
            JSONResponse: {},
          },
          include: {
            homePage: './pages/HomePage.js',
          },
          plugins: {
            screenshot: {
              enabled: true,
              on: 'fail',
            },
            junitReporter: {
              enabled: true,
              outputName: 'report.xml',
            },
            aiTrace: {
              enabled: false,
              on: 'fail',
            },
          },
        };
        """

        let sampleTest = """
        Feature('Starter Verification @smoke');

        Before(({ I }) => {
          I.amOnPage('https://example.com');
        });

        Scenario('renders Example Domain page @web', async ({ I }) => {
          I.see('Example Domain');
          I.seeElement('h1');
          I.seeElement('a');
        });

        Scenario('queries public REST API @api', async ({ I }) => {
          await I.sendGetRequest('/todos/1');
          I.seeResponseCodeIsSuccessful();
          I.seeResponseContainsJson({ id: 1 });
        });
        """

        try packageJSON.write(to: directoryURL.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try configJS.write(to: directoryURL.appendingPathComponent("codecept.conf.js"), atomically: true, encoding: .utf8)
        try sampleTest.write(to: directoryURL.appendingPathComponent("tests/starter_test.js"), atomically: true, encoding: .utf8)
        try renderTemplate(kind: .pageObject, name: "Home").write(
            to: directoryURL.appendingPathComponent("pages/HomePage.js"),
            atomically: true,
            encoding: .utf8
        )
        try renderTemplate(kind: .gherkinFeature, name: "Starter Flow").write(
            to: directoryURL.appendingPathComponent("features/starter.feature"),
            atomically: true,
            encoding: .utf8
        )
    }

    public static func sanitizeIdentifier(_ raw: String) -> String {
        let parts = raw.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "Custom" }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}

public struct CodeSnippetItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let body: String

    public static let builtInSnippets: [CodeSnippetItem] = [
        CodeSnippetItem(
            id: "scenario",
            title: "Scenario",
            subtitle: "Standard async CodeceptJS scenario",
            body: """
            Scenario('describes expected behavior @smoke', async ({ I }) => {
              I.amOnPage('/');
              I.see('Welcome');
            });
            """
        ),
        CodeSnippetItem(
            id: "data-driven",
            title: "Data-Driven Scenario",
            subtitle: "CodeceptJS DataTable parameterized scenario",
            body: """
            const accounts = new DataTable(['email', 'role']);
            accounts.add(['admin@example.com', 'admin']);
            accounts.add(['member@example.com', 'member']);

            Data(accounts).Scenario('signs in with role', async ({ I, current }) => {
              I.amOnPage('/login');
              I.fillField('Email', current.email);
              I.see(current.role);
            });
            """
        ),
        CodeSnippetItem(
            id: "rest-api",
            title: "REST API Scenario",
            subtitle: "REST + JSONResponse helper check",
            body: """
            Scenario('verifies REST endpoint @api', async ({ I }) => {
              await I.sendGetRequest('/users/1');
              I.seeResponseCodeIsSuccessful();
              I.seeResponseContainsJson({ id: 1 });
            });
            """
        ),
        CodeSnippetItem(
            id: "retry-block",
            title: "retryTo Block",
            subtitle: "Resilient multi-step retry block",
            body: """
            await retryTo((retryNum) => {
              I.click('Submit');
              I.waitForText('Saved', 5);
            }, 3);
            """
        ),
        CodeSnippetItem(
            id: "hooks",
            title: "Before & After Hooks",
            subtitle: "Per-scenario setup and cleanup",
            body: """
            Before(({ I }) => {
              I.amOnPage('/');
            });

            After(({ I }) => {
              I.clearCookie();
            });
            """
        ),
        CodeSnippetItem(
            id: "session",
            title: "Multi-Session Block",
            subtitle: "Isolated parallel browser session",
            body: """
            session('reviewer', () => {
              I.amOnPage('/dashboard');
              I.see('Pending Approval');
            });
            """
        )
    ]
}
