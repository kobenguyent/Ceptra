# Playwright (TypeScript / JavaScript & Python)

Ceptra provides first-class support for both **`@playwright/test`** (TypeScript &amp; JavaScript) and **`pytest-playwright`** (Python) — including polyglot monorepos that combine CodeceptJS, Playwright TS, and Playwright Python in the same repository.

---

## Auto-Detection & Toolchain Resolution

=== "Playwright Test (TS / JS)"

    Ceptra automatically discovers:

    - `playwright.config.{ts,js,mjs,cjs}` anywhere in your workspace
    - Configured `projects` (e.g., `chromium`, `firefox`, `webkit`, mobile profiles), `testDir`, `baseURL`, and HTML report directory
    - Local `./node_modules/.bin/playwright` (under **Node.js** or **Bun** via `bunx playwright`)
    - `test(...)`, `test.describe(...)`, `test.only(...)`, `test.skip(...)`, `test.beforeEach(...)`, and `@tags`

=== "Playwright Python (`pytest-playwright`)"

    Ceptra automatically discovers:

    - `pytest.ini`, `pyproject.toml`, `tox.ini`, `setup.cfg`, and `requirements.txt` containing `pytest-playwright` or `playwright`
    - Python virtual environments in priority order: project `.venv` / `venv`, `uv`, `poetry`, or a custom Python binary configured in Settings (++cmd+comma++)
    - `def test_*`, `async def test_*`, `class Test*`, `@pytest.fixture`, `@pytest.mark.*` tags, `@pytest.mark.parametrize`, and `conftest.py` helpers
    - Automatically injects workspace root onto `PYTHONPATH` and configures `pythonpath = .` in scaffolded workspaces so `from pages.home_page import HomePage` works out of the box

---

## Writing Tests with Framework-Aware IntelliSense

Ceptra adapts completions, code folding, snippets, and AI prompts automatically to the active file's framework:

=== "TypeScript / JavaScript"

    ```ts
    import { test, expect } from '@playwright/test';

    test.describe('Playwright Docs', () => {
      test('has title and opens Getting Started @web @smoke', async ({ page }) => {
        await page.goto('/');
        await expect(page).toHaveTitle(/Playwright/);
        await page.getByRole('link', { name: 'Get started' }).click();
        await expect(page.getByRole('heading', { name: 'Installation' })).toBeVisible();
      });

      test('fetches a todo resource @api', async ({ request }) => {
        const response = await request.get('https://jsonplaceholder.typicode.com/todos/1');
        await expect(response).toBeOK();
        const data = await response.json();
        expect(data.id).toBe(1);
      });
    });
    ```

    - **Callback fixture IntelliSense**: Typing `request.` or `page.` inside `async ({ page, request })` immediately completes `APIRequestContext` (`get`, `post`, `put`, `patch`, `delete`, `fetch`) and `Page`/`Locator` methods.
    - **Zero `NO_COLOR`/`FORCE_COLOR` warnings**: Ceptra configures clean terminal color flags automatically so Node workers stay noise-free.

=== "Python (`pytest-playwright`)"

    ```python
    import re
    import pytest
    from playwright.sync_api import Page, APIRequestContext, expect


    @pytest.mark.smoke
    @pytest.mark.web
    def test_has_title_and_opens_getting_started(page: Page):
        page.goto("/")
        expect(page).to_have_title(re.compile("Playwright"))
        page.get_by_role("link", name="Get started").click()
        expect(page.get_by_role("heading", name="Installation")).to_be_visible()


    @pytest.mark.api
    def test_fetches_todo_resource(api_request_context: APIRequestContext):
        response = api_request_context.get("https://jsonplaceholder.typicode.com/todos/1")
        expect(response).to_be_ok()
        payload = response.json()
        assert payload["id"] == 1
    ```

    - **Python IntelliSense**: Completes fixture parameters inside `def test_*(`, type annotations (`Page`, `Locator`, `APIRequestContext`, `Playwright`), `@pytest.mark.*` workspace markers, `snake_case` Playwright APIs (`get_by_role`, `to_have_title`), and inferred local variables (`res = api_ctx.get(...)` → `res.json()`, `res.status`, `res.ok`).
    - **Indentation-based code folding & Smart Code Snapshots**: Folds Python functions/classes and includes preceding `@pytest.mark.*` decorators in Code Block Screenshots (++cmd+option+p++).

---

## Full Time-Travel Replay (Web, API & Mixed Suites)

Ceptra automatically classifies every scenario as **Web**, **API**, or **Hybrid** so mixed Playwright suites never misclassify browser tests as API tests:

- **Playwright TS/JS**: Captures step timelines, screenshots, DOM snapshots, network traffic, console/page errors, and `request.*` API exchanges via Ceptra's zero-config custom reporter + `trace.zip` extractor.
- **Playwright Python**: Uses Ceptra's zero-dependency stdlib pytest plugin (`-p ceptra_pw_time_travel` via `PYTHONPATH`) with zero edits to `pytest.ini` or `conftest.py`:
  - **Teardown `trace.zip` hydration**: Waits until `pytest-playwright`'s `context` fixture writes `trace.zip` during teardown before parsing actions, screencast JPEGs, and network logs.
  - **Incremental delta DOM reconstruction**: Resolves Playwright 1.50+/1.60 post-order subtree references (`[[offset, nodeIndex]]`) so every step preserves complete `<head>` and `<body>` DOM snapshots plus target element `outerHTML` and bounding boxes.
  - **In-process `APIRequestContext` capture**: Safely instruments `APIRequestContext` and `expect(response).to_be_ok()` / `not_to_be_ok()` so pure Python API tests (with no browser `page` and no `trace.zip`) capture full HTTP requests, JSON bodies, redacted headers, latency, and linked assertion cards.

---

## Codegen, Playwright UI & Adaptive Terminal Commands

- **Playwright Codegen**: Launch `playwright codegen` (or `playwright codegen --target python-pytest` for Python projects) directly from the Run menu or Command Palette (++cmd+k++).
- **Playwright UI Mode (++cmd+option+u++)**: Embeds `playwright test --ui` in the right inspector for TS/JS projects (or opens Trace Viewer for Python projects).
- **Adaptive Terminal Pre-Suggested Commands**: Opening the Terminal drawer (++cmd+j++) automatically adapts quick commands to your detected runtime — `uv sync` / `uv run pytest`, `poetry install` / `poetry run pytest`, `.venv/bin/pytest`, or `npm`/`pnpm`/`yarn`/`bun` for TS/JS.
- **Starter Workspaces**: Scaffold a complete starter project via **File → Create Sample Workspace → Playwright Test Project (TypeScript)…** or **Playwright Python Project (pytest)…**.
