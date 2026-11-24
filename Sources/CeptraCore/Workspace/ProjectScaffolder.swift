import Foundation

public enum ScaffoldTemplateKind: String, CaseIterable, Identifiable, Sendable {
    case blankFile = "Blank / Custom File"
    case playwrightTSTest = "Playwright Test (.spec.ts)"
    case playwrightJSTest = "Playwright Test (.spec.js)"
    case playwrightPageObject = "Playwright Page Object (.ts)"
    case playwrightPythonTest = "Playwright Python Test (test_*.py)"
    case playwrightPythonPageObject = "Playwright Python Page Object (*_page.py)"
    case jsTest = "CodeceptJS Test (.js)"
    case tsTest = "CodeceptJS Test (.ts)"
    case mobilewrightTest = "Mobilewright Test (.js)"
    case gherkinFeature = "Gherkin Feature (.feature)"
    case pageObject = "CodeceptJS Page Object (.js)"
    case customHelper = "Custom Helper (.js)"

    public var id: String { rawValue }

    public var defaultExtension: String {
        switch self {
        case .blankFile: return ""
        case .playwrightTSTest: return ".spec.ts"
        case .playwrightJSTest: return ".spec.js"
        case .playwrightPageObject: return "Page.ts"
        case .playwrightPythonTest: return ".py"
        case .playwrightPythonPageObject: return "_page.py"
        case .jsTest, .mobilewrightTest: return "_test.js"
        case .tsTest: return "_test.ts"
        case .gherkinFeature: return ".feature"
        case .pageObject: return "Page.js"
        case .customHelper: return "_helper.js"
        }
    }

    public var suggestedDirectory: String {
        switch self {
        case .blankFile: return ""
        case .playwrightTSTest, .playwrightJSTest, .playwrightPythonTest, .jsTest, .tsTest, .mobilewrightTest: return "tests"
        case .gherkinFeature: return "features"
        case .playwrightPageObject, .playwrightPythonPageObject, .pageObject: return "pages"
        case .customHelper: return "helpers"
        }
    }
}

public enum WorkspaceFileOperationError: LocalizedError, Equatable, Sendable {
    case emptyName
    case invalidPath(String)
    case escapesWorkspace
    case alreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Please enter a name."
        case .invalidPath(let reason):
            return reason
        case .escapesWorkspace:
            return "Path must stay inside the current workspace."
        case .alreadyExists(let relPath):
            return "\"\(relPath)\" already exists."
        }
    }
}

public enum ProjectScaffolder {
    public static func renderTemplate(kind: ScaffoldTemplateKind, name: String) -> String {
        let cleanTitle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleanTitle.isEmpty ? "New Feature" : cleanTitle
        let identifier = sanitizeIdentifier(title)

        switch kind {
        case .blankFile:
            return ""

        case .playwrightTSTest:
            return """
            import { test, expect } from '@playwright/test';

            test.describe('\(title)', { tag: '@smoke' }, () => {
              test.beforeEach(async ({ page }) => {
                await page.goto('/');
              });

              test('renders primary experience', async ({ page }) => {
                await expect(page.locator('body')).toBeVisible();
                await expect(page).toHaveTitle(/.+/);
              });

              test('validates API response', { tag: '@api' }, async ({ request }) => {
                const response = await request.get('/health');
                await expect(response).toBeOK();
              });
            });
            """

        case .playwrightJSTest:
            return """
            import { test, expect } from '@playwright/test';

            test.describe('\(title)', { tag: '@smoke' }, () => {
              test.beforeEach(async ({ page }) => {
                await page.goto('/');
              });

              test('renders primary experience', async ({ page }) => {
                await expect(page.locator('body')).toBeVisible();
                await expect(page).toHaveTitle(/.+/);
              });
            });
            """

        case .playwrightPageObject:
            return """
            import type { Locator, Page } from '@playwright/test';

            export class \(identifier)Page {
              readonly page: Page;
              readonly heading: Locator;
              readonly submitButton: Locator;

              constructor(page: Page) {
                this.page = page;
                this.heading = page.getByRole('heading', { level: 1 });
                this.submitButton = page.getByRole('button', { name: /submit/i });
              }

              async goto() {
                await this.page.goto('/\(identifier.lowercased())');
              }

              async submit() {
                await this.submitButton.click();
              }
            }
            """

        case .playwrightPythonTest:
            let fnName = sanitizeSnakeCase(title)
            return """
            import re
            import pytest
            from playwright.sync_api import Page, Playwright, expect


            @pytest.mark.smoke
            def test_\(fnName)_renders(page: Page):
                page.goto("/")
                expect(page.locator("body")).to_be_visible()
                expect(page).to_have_title(re.compile(r".+"))


            @pytest.mark.api
            def test_\(fnName)_api(playwright: Playwright):
                api_ctx = playwright.request.new_context()
                response = api_ctx.get("https://jsonplaceholder.typicode.com/todos/1")
                expect(response).to_be_ok()
                assert response.json()["id"] == 1
                api_ctx.dispose()
            """

        case .playwrightPythonPageObject:
            let routeSlug = sanitizeSnakeCase(title).replacingOccurrences(of: "_", with: "-")
            return """
            import re
            from playwright.sync_api import Locator, Page


            class \(identifier)Page:
                def __init__(self, page: Page) -> None:
                    self.page = page
                    self.heading: Locator = page.get_by_role("heading", level=1)
                    self.submit_button: Locator = page.get_by_role("button", name=re.compile(r"submit", re.I))

                def goto(self) -> None:
                    self.page.goto("/\(routeSlug)")

                def submit(self) -> None:
                    self.submit_button.click()
            """

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

        case .mobilewrightTest:
            return """
            import { secret } from 'codeceptjs';

            Feature('\(title) @mobile');

            Scenario('loads main screen and interacts via accessibility tree @smoke', ({ I }) => {
              I.waitForText('Products', 20);
              I.see('\(title)');
              I.tap('~store button');
              I.saveScreenshot('01-home.png');
            });

            Scenario('fills form by adjacent label and rotates orientation', ({ I }) => {
              I.fillField('Username', 'bob@example.com');
              I.fillField('Password', secret('10203040'));
              I.tap({ role: 'button', name: 'Sign In' });
              I.setOrientation('LANDSCAPE');
              I.seeOrientationIs('LANDSCAPE');
              I.setOrientation('PORTRAIT');
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

    /// Scaffolds a ready-to-run Playwright Test (`@playwright/test`) TypeScript sample workspace at `directoryURL`.
    public static func createSamplePlaywrightWorkspace(at directoryURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: directoryURL.appendingPathComponent("tests"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directoryURL.appendingPathComponent("pages"), withIntermediateDirectories: true)

        let packageJSON = """
        {
          "name": "\(directoryURL.lastPathComponent)",
          "version": "1.0.0",
          "type": "module",
          "scripts": {
            "test": "playwright test",
            "test:ui": "playwright test --ui",
            "test:headed": "playwright test --headed",
            "report": "playwright show-report"
          },
          "devDependencies": {
            "@playwright/test": "^1.50.0",
            "@types/node": "^22.0.0"
          }
        }
        """

        let tsconfigJSON = """
        {
          "compilerOptions": {
            "target": "ES2022",
            "module": "ESNext",
            "moduleResolution": "Bundler",
            "strict": true,
            "esModuleInterop": true,
            "skipLibCheck": true,
            "noEmit": true
          },
          "include": ["playwright.config.ts", "tests/**/*.ts", "pages/**/*.ts"]
        }
        """

        let playwrightConfigTS = """
        import { defineConfig, devices } from '@playwright/test';

        export default defineConfig({
          testDir: './tests',
          outputDir: './test-results',
          fullyParallel: true,
          forbidOnly: !!process.env.CI,
          retries: process.env.CI ? 2 : 0,
          workers: process.env.CI ? 1 : undefined,
          reporter: [['list'], ['html', { outputFolder: 'playwright-report', open: 'never' }]],
          use: {
            baseURL: 'https://playwright.dev',
            trace: 'on-first-retry',
            screenshot: 'only-on-failure',
          },
          projects: [
            {
              name: 'chromium',
              use: { ...devices['Desktop Chrome'] },
            },
            {
              name: 'firefox',
              use: { ...devices['Desktop Firefox'] },
            },
            {
              name: 'webkit',
              use: { ...devices['Desktop Safari'] },
            },
          ],
        });
        """

        let exampleSpec = """
        import { test, expect } from '@playwright/test';
        import { HomePage } from '../pages/HomePage';

        test.describe('Playwright Docs', { tag: '@smoke' }, () => {
          test('has title and opens Getting Started @web', async ({ page }) => {
            const home = new HomePage(page);
            await test.step('Open Playwright home page', async () => {
              await home.goto();
              await expect(page).toHaveTitle(/Playwright/);
            });

            await test.step('Navigate to Installation guide', async () => {
              await home.clickGetStarted();
              await expect(page.getByRole('heading', { name: 'Installation' })).toBeVisible();
            });
          });
        });
        """

        let apiSpec = """
        import { test, expect } from '@playwright/test';

        test.describe('Public JSON API', { tag: '@api' }, () => {
          test('fetches a todo resource', async ({ request }) => {
            const response = await request.get('https://jsonplaceholder.typicode.com/todos/1');
            await expect(response).toBeOK();
            const payload = await response.json();
            expect(payload).toMatchObject({ id: 1 });
          });
        });
        """

        let homePageTS = """
        import type { Locator, Page } from '@playwright/test';

        export class HomePage {
          readonly page: Page;
          readonly getStartedLink: Locator;

          constructor(page: Page) {
            this.page = page;
            this.getStartedLink = page.getByRole('link', { name: 'Get started' });
          }

          async goto() {
            await this.page.goto('/');
          }

          async clickGetStarted() {
            await this.getStartedLink.click();
          }
        }
        """

        try packageJSON.write(to: directoryURL.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try tsconfigJSON.write(to: directoryURL.appendingPathComponent("tsconfig.json"), atomically: true, encoding: .utf8)
        try playwrightConfigTS.write(to: directoryURL.appendingPathComponent("playwright.config.ts"), atomically: true, encoding: .utf8)
        try exampleSpec.write(to: directoryURL.appendingPathComponent("tests/example.spec.ts"), atomically: true, encoding: .utf8)
        try apiSpec.write(to: directoryURL.appendingPathComponent("tests/api.spec.ts"), atomically: true, encoding: .utf8)
        try homePageTS.write(to: directoryURL.appendingPathComponent("pages/HomePage.ts"), atomically: true, encoding: .utf8)
    }

    /// Scaffolds a ready-to-run Playwright Python (`pytest-playwright`) sample workspace at `directoryURL`.
    public static func createSamplePlaywrightPythonWorkspace(at directoryURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: directoryURL.appendingPathComponent("tests"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directoryURL.appendingPathComponent("pages"), withIntermediateDirectories: true)

        let projectName = sanitizeSnakeCase(directoryURL.lastPathComponent)

        let pytestIni = """
        [pytest]
        pythonpath = .
        testpaths = tests
        addopts = --browser chromium --base-url https://playwright.dev --output test-results
        markers =
            smoke: high-priority smoke verification tests
            web: browser-backed UI tests
            api: HTTP / REST APIRequestContext tests
        """

        let pyprojectToml = """
        [project]
        name = "\(projectName)"
        version = "0.1.0"
        requires-python = ">=3.9"
        dependencies = [
            "pytest>=8.0.0",
            "pytest-playwright>=0.7.0",
            "playwright>=1.50.0",
        ]

        [tool.pytest.ini_options]
        pythonpath = ["."]
        testpaths = ["tests"]
        """

        let requirementsTxt = """
        pytest>=8.0.0
        pytest-playwright>=0.7.0
        playwright>=1.50.0
        """

        let conftestPy = """
        from typing import Generator
        import pytest
        from playwright.sync_api import APIRequestContext, Playwright


        @pytest.fixture(scope="session")
        def api_request_context(
            playwright: Playwright,
        ) -> Generator[APIRequestContext, None, None]:
            ctx = playwright.request.new_context(
                base_url="https://jsonplaceholder.typicode.com",
                extra_http_headers={"Accept": "application/json"},
            )
            yield ctx
            ctx.dispose()
        """

        let exampleTestPy = """
        import re
        import pytest
        from playwright.sync_api import Page, expect
        from pages.home_page import HomePage


        @pytest.mark.smoke
        @pytest.mark.web
        def test_has_title_and_opens_getting_started(page: Page):
            home = HomePage(page)
            home.goto()
            expect(page).to_have_title(re.compile(r"Playwright"))

            home.click_get_started()
            expect(page.get_by_role("heading", name="Installation")).to_be_visible()
        """

        let apiTestPy = """
        import pytest
        from playwright.sync_api import APIRequestContext, expect


        @pytest.mark.api
        def test_fetches_todo_resource(api_request_context: APIRequestContext):
            response = api_request_context.get("/todos/1")
            expect(response).to_be_ok()
            payload = response.json()
            assert payload["id"] == 1
        """

        let homePagePy = """
        from playwright.sync_api import Locator, Page


        class HomePage:
            def __init__(self, page: Page) -> None:
                self.page = page
                self.get_started_link: Locator = page.get_by_role("link", name="Get started")

            def goto(self) -> None:
                self.page.goto("/")

            def click_get_started(self) -> None:
                self.get_started_link.click()
        """

        try pytestIni.write(to: directoryURL.appendingPathComponent("pytest.ini"), atomically: true, encoding: .utf8)
        try pyprojectToml.write(to: directoryURL.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
        try requirementsTxt.write(to: directoryURL.appendingPathComponent("requirements.txt"), atomically: true, encoding: .utf8)
        try conftestPy.write(to: directoryURL.appendingPathComponent("conftest.py"), atomically: true, encoding: .utf8)
        try "".write(to: directoryURL.appendingPathComponent("pages/__init__.py"), atomically: true, encoding: .utf8)
        try exampleTestPy.write(to: directoryURL.appendingPathComponent("tests/test_example.py"), atomically: true, encoding: .utf8)
        try apiTestPy.write(to: directoryURL.appendingPathComponent("tests/test_api.py"), atomically: true, encoding: .utf8)
        try homePagePy.write(to: directoryURL.appendingPathComponent("pages/home_page.py"), atomically: true, encoding: .utf8)
    }

    public static func sanitizeSnakeCase(_ raw: String) -> String {
        let withUnderscores = raw.replacingOccurrences(
            of: #"([a-z0-9])([A-Z])"#,
            with: "$1_$2",
            options: .regularExpression
        )
        let parts = withUnderscores
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "custom" }
        return parts.joined(separator: "_")
    }

    public static func sanitizeIdentifier(_ raw: String) -> String {
        let parts = raw.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "Custom" }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// Computes the normalized workspace-relative path for a file or folder creation preview.
    public static func previewFileRelativePath(
        directory: String,
        name: String,
        kind: ScaffoldTemplateKind
    ) -> String {
        let dir = normalizeRelativeDirectory(directory)
        let resolvedName = resolveFileName(name: name, kind: kind)
        guard !resolvedName.isEmpty else { return dir }
        return dir.isEmpty ? resolvedName : "\(dir)/\(resolvedName)"
    }

    public static func previewFolderRelativePath(
        directory: String,
        folderName: String
    ) -> String {
        let dir = normalizeRelativeDirectory(directory)
        let cleaned = normalizeRelativeDirectory(folderName)
        guard !cleaned.isEmpty else { return dir }
        return dir.isEmpty ? cleaned : "\(dir)/\(cleaned)"
    }

    /// Creates a new folder (and any intermediate nested folders) at any level inside `workspaceRoot`.
    @discardableResult
    public static func createFolder(
        workspaceRoot: URL,
        relativeDirectory: String,
        folderName: String
    ) throws -> (url: URL, relativePath: String) {
        let trimmedName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw WorkspaceFileOperationError.emptyName
        }
        let target = try resolveBoundedURL(
            workspaceRoot: workspaceRoot,
            relativeDirectory: relativeDirectory,
            itemSubpath: trimmedName
        )

        let fm = FileManager.default
        if fm.fileExists(atPath: target.url.path) {
            throw WorkspaceFileOperationError.alreadyExists(target.relativePath)
        }
        try fm.createDirectory(at: target.url, withIntermediateDirectories: true)
        return target
    }

    /// Creates a new file (blank/custom OR CodeceptJS template) at any level inside `workspaceRoot`,
    /// automatically creating missing intermediate parent directories.
    @discardableResult
    public static func createFile(
        workspaceRoot: URL,
        relativeDirectory: String,
        name: String,
        kind: ScaffoldTemplateKind
    ) throws -> (url: URL, relativePath: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw WorkspaceFileOperationError.emptyName
        }

        let resolvedSubpath = resolveFileName(name: trimmedName, kind: kind)
        guard !resolvedSubpath.isEmpty else {
            throw WorkspaceFileOperationError.emptyName
        }

        let target = try resolveBoundedURL(
            workspaceRoot: workspaceRoot,
            relativeDirectory: relativeDirectory,
            itemSubpath: resolvedSubpath
        )

        let fm = FileManager.default
        if fm.fileExists(atPath: target.url.path) {
            throw WorkspaceFileOperationError.alreadyExists(target.relativePath)
        }

        let parentDir = target.url.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let templateStem = (trimmedName as NSString).lastPathComponent
        let body = renderTemplate(kind: kind, name: templateStem)
        try body.write(to: target.url, atomically: true, encoding: .utf8)
        return target
    }

    private static func resolveFileName(name: String, kind: ScaffoldTemplateKind) -> String {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else { return "" }

        let parts = normalized.split(separator: "/").map(String.init)
        guard let last = parts.last else { return "" }
        let prefixParts = parts.dropLast()

        let finalLast: String
        if kind == .blankFile || last.contains(".") {
            finalLast = last
        } else if kind == .playwrightPythonTest {
            let snake = sanitizeSnakeCase(last)
            let stem = (snake.hasPrefix("test_") || snake.hasSuffix("_test")) ? snake : "test_\(snake)"
            finalLast = stem + ".py"
        } else if kind == .playwrightPythonPageObject {
            let snake = sanitizeSnakeCase(last)
            let stem = snake.hasSuffix("_page") ? snake : "\(snake)_page"
            finalLast = stem + ".py"
        } else {
            let baseName = sanitizeIdentifier(last)
            let stem = (kind == .pageObject || kind == .playwrightPageObject) ? baseName : baseName.lowercased()
            finalLast = stem + kind.defaultExtension
        }

        return (prefixParts + [finalLast]).joined(separator: "/")
    }

    private static func normalizeRelativeDirectory(_ raw: String) -> String {
        var cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while cleaned.hasPrefix("./") {
            cleaned.removeFirst(2)
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cleaned == "." {
            return ""
        }
        return cleaned
    }

    private static func resolveBoundedURL(
        workspaceRoot: URL,
        relativeDirectory: String,
        itemSubpath: String
    ) throws -> (url: URL, relativePath: String) {
        let stdRoot = workspaceRoot.standardizedFileURL
        let cleanDir = normalizeRelativeDirectory(relativeDirectory)
        let cleanSub = itemSubpath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !cleanSub.isEmpty else {
            throw WorkspaceFileOperationError.emptyName
        }

        let combined = cleanDir.isEmpty ? cleanSub : "\(cleanDir)/\(cleanSub)"
        let segments = combined.split(separator: "/").map(String.init)
        if segments.contains("..") || segments.contains(".") {
            throw WorkspaceFileOperationError.invalidPath("Path segments cannot contain '.' or '..'.")
        }

        let targetURL = stdRoot.appendingPathComponent(combined).standardizedFileURL
        let rootPrefix = stdRoot.path.hasSuffix("/") ? stdRoot.path : stdRoot.path + "/"
        guard targetURL.path.hasPrefix(rootPrefix) else {
            throw WorkspaceFileOperationError.escapesWorkspace
        }
        let relPath = String(targetURL.path.dropFirst(rootPrefix.count))
        return (targetURL, relPath)
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
        ),
        CodeSnippetItem(
            id: "mobilewright",
            title: "Mobilewright Scenario",
            subtitle: "iOS & Android native scenario via @codeceptjs/mobilewright",
            body: """
            Scenario('navigates mobile app @mobile', ({ I }) => {
              I.waitForText('Products', 20);
              I.fillField('Username', 'bob@example.com');
              I.tap('~Login button');
              I.seeOrientationIs('PORTRAIT');
            });
            """
        )
    ]

    public static let playwrightSnippets: [CodeSnippetItem] = [
        CodeSnippetItem(
            id: "pw-test",
            title: "Playwright Test",
            subtitle: "Standard async Playwright test with web-first assertions",
            body: """
            test('verifies user flow @smoke', async ({ page }) => {
              await page.goto('/');
              await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
            });
            """
        ),
        CodeSnippetItem(
            id: "pw-describe",
            title: "test.describe Suite",
            subtitle: "Grouped suite with beforeEach hook and tag",
            body: """
            test.describe('Feature Suite', { tag: '@smoke' }, () => {
              test.beforeEach(async ({ page }) => {
                await page.goto('/');
              });

              test('completes primary action', async ({ page }) => {
                await page.getByRole('button', { name: 'Continue' }).click();
                await expect(page).toHaveURL(/dashboard/);
              });
            });
            """
        ),
        CodeSnippetItem(
            id: "pw-step",
            title: "test.step Block",
            subtitle: "Structured step visible in Replay & Trace Viewer",
            body: """
            await test.step('Submit checkout form', async () => {
              await page.getByLabel('Email').fill('qa@example.com');
              await page.getByRole('button', { name: 'Submit' }).click();
            });
            """
        ),
        CodeSnippetItem(
            id: "pw-api",
            title: "API Request Test",
            subtitle: "Built-in APIRequestContext GET + JSON assertion",
            body: """
            test('verifies REST endpoint', { tag: '@api' }, async ({ request }) => {
              const response = await request.get('/api/users/1');
              await expect(response).toBeOK();
              expect(await response.json()).toMatchObject({ id: 1 });
            });
            """
        ),
        CodeSnippetItem(
            id: "pw-route-mock",
            title: "Network Route Mock",
            subtitle: "Intercept and mock HTTP response with page.route",
            body: """
            await page.route('**/api/items', async (route) => {
              await route.fulfill({
                status: 200,
                contentType: 'application/json',
                body: JSON.stringify([{ id: 1, name: 'Mock Item' }]),
              });
            });
            """
        )
    ]

    public static let playwrightPythonSnippets: [CodeSnippetItem] = [
        CodeSnippetItem(
            id: "pw-py-test",
            title: "Playwright Python Test",
            subtitle: "Standard pytest-playwright test with web-first assertions",
            body: """
            @pytest.mark.smoke
            def test_user_flow(page: Page):
                page.goto("/")
                expect(page.get_by_role("heading", level=1)).to_be_visible()
            """
        ),
        CodeSnippetItem(
            id: "pw-py-parametrize",
            title: "Parametrized Pytest Test",
            subtitle: "Data-driven test with @pytest.mark.parametrize",
            body: """
            @pytest.mark.parametrize("query,expected", [
                ("Playwright", "Installation"),
                ("Locators", "Locators"),
            ])
            def test_search_docs(page: Page, query: str, expected: str):
                page.goto("/")
                page.get_by_role("button", name="Search").click()
                page.get_by_placeholder("Search docs").fill(query)
                expect(page.get_by_text(expected).first).to_be_visible()
            """
        ),
        CodeSnippetItem(
            id: "pw-py-api",
            title: "API Request Test (Python)",
            subtitle: "APIRequestContext GET + expect(response).to_be_ok()",
            body: """
            @pytest.mark.api
            def test_rest_endpoint(playwright: Playwright):
                api_ctx = playwright.request.new_context(base_url="https://jsonplaceholder.typicode.com")
                response = api_ctx.get("/todos/1")
                expect(response).to_be_ok()
                assert response.json()["id"] == 1
                api_ctx.dispose()
            """
        ),
        CodeSnippetItem(
            id: "pw-py-fixture",
            title: "Pytest Fixture",
            subtitle: "Reusable session or function fixture in conftest.py",
            body: """
            @pytest.fixture
            def logged_in_page(page: Page) -> Page:
                page.goto("/login")
                page.get_by_label("Email").fill("qa@example.com")
                page.get_by_role("button", name="Sign in").click()
                return page
            """
        ),
        CodeSnippetItem(
            id: "pw-py-route-mock",
            title: "Network Route Mock (Python)",
            subtitle: "Intercept and fulfill HTTP requests via page.route",
            body: """
            page.route(
                "**/api/items",
                lambda route: route.fulfill(
                    status=200,
                    content_type="application/json",
                    body='[{"id": 1, "name": "Mock Item"}]',
                ),
            )
            """
        )
    ]

    public static func snippets(for framework: TestFrameworkKind) -> [CodeSnippetItem] {
        switch framework {
        case .codeceptJS: return builtInSnippets
        case .playwright: return playwrightSnippets
        case .playwrightPython: return playwrightPythonSnippets
        }
    }
}
