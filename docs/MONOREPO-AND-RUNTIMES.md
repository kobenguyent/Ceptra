# Monorepos, Runtimes & System Console Guide

Ceptra is built to handle real-world repositories out of the box — from single-suite Playwright or CodeceptJS projects to polyglot TypeScript + Python monorepos.

---

## Polyglot & Multi-Config Monorepo Auto-Resolution

Many teams organize Web, API, Mobile, and Python suites under one repository with separate configs:

```text
my-qa-monorepo/
├── package.json
├── e2e-codecept/
│   ├── tests/api/codecept.conf.ts      # CodeceptJS REST + JSONResponse
│   └── tests/web/codecept.conf.ts      # CodeceptJS Playwright
├── e2e-playwright-ts/
│   └── playwright.config.ts            # @playwright/test (chromium, firefox, webkit)
└── e2e-playwright-py/
    ├── pytest.ini                      # pytest-playwright (.venv / uv / poetry)
    └── tests/test_checkout.py
```

### How Ceptra handles this automatically
1. **Discovery**: Scans standard configs across all supported frameworks (`codecept.conf.{ts,js,cjs,mjs}`, `codecept.config.*`, `codecept.json`, `playwright.config.{ts,js,mjs,cjs}`, `pytest.ini`, `pyproject.toml`, `tox.ini`, `setup.cfg`), `-c` / `--config` targets declared in `package.json` scripts, and nested configs up to 4 directories deep (ignoring `node_modules`, `.venv`, `.git`, and build folders).
2. **Per-File Config & Framework Matching**: When you run, debug, or dry-run a specific file or scenario, Ceptra matches the file path against every discovered config's `tests` / `testDir` / `gherkin.features` glob and directory ancestry — automatically choosing the owning config, framework runner (`codeceptjs`, `playwright test`, or `pytest`), and toolchain.
3. **Environment Overrides Preserved**: If you explicitly pin an environment config (e.g. `configs/staging.conf.ts` vs `configs/prod.conf.ts`) that shares the same `tests` glob, Ceptra respects your pinned choice.
4. **Live Tab Sync**: In auto-detect mode, switching tabs between suites automatically updates the active config, status bar helper badge (`Playwright`, `Playwright (Py)`, `REST`, `Mobilewright`), IntelliSense completions, and AI prompt context.
5. **Manual Switching**: Click the helper pill in the bottom-right status bar (or press `⌘⇧C`) to inspect every discovered config with its helper summary, pin a config, or reset to Auto-Detect.

---

## Node.js, Bun & Python Runtimes + Adaptive Terminal Suggestions

Switch JavaScript runtimes anytime from the **Top Bar**, **Run Options**, **Settings (`⌘,`)**, or **Run → JavaScript Runtime**:

- **Node.js (default for JS/TS)**:
  - Resolves project-local `./node_modules/.bin/codeceptjs` or `./node_modules/.bin/playwright` (with fallback to global binaries or `npx`).
  - Supports **Interactive CDP Step-Through Debugging** (`⌘⇧B`).
  - Includes Ceptra's opt-out **ESM/CJS & TypeScript Compatibility Hook** (enabled by default in Run Options): uses Node's synchronous `module.registerHooks` so extensionless TS imports, `tsconfig.json` path aliases, CommonJS getter exports (e.g. `uuid`), and ESM `node_modules` packages (e.g. `flex-rest`) work smoothly in both `run` and `run-workers`.
  - **CodeceptJS 4.x TypeScript tip**: Under Node.js, CodeceptJS 4.x requires `require: ['tsx/esm']` in each `.ts` suite's `codecept.conf.ts` (along with `"type": "module"` in `package.json`).
- **Bun**:
  - Executes CodeceptJS or Playwright Test directly via `bun` / `bunx` with native TypeScript transpilation — no `tsx` loader required.
  - **Tip**: Avoid mixing `npm install` and `bun install` in the same `node_modules` tree. If Bun hits a module interop error in a previously `npm`-installed repo, run `rm -rf node_modules && bun install`.
- **Python (`uv`, `poetry`, `.venv`, `pip`)**:
  - Resolves project `.venv/bin/pytest`, `uv run pytest`, `poetry run pytest`, or a custom Python binary configured in Settings (`⌘,`).
  - Automatically bootstraps `.venv` and installs `requirements.txt` on 1-click dependency install when no virtualenv exists yet.

### Adaptive Terminal Pre-Suggested Commands

The built-in Terminal drawer (`⌘J`) automatically detects your active runtime environment (`uv.lock` → `uv`, `poetry.lock` → `poetry`, `.venv` → local virtualenv, `bun` / `pnpm` / `yarn` / `npm`) and adapts all pre-suggested install, browser-install, and quick-command chips so you never see irrelevant commands (for example, Python workspaces show `uv sync` / `.venv/bin/playwright install` / `pytest --co -q` instead of `npm`).

---

## Built-in Console vs macOS System Console

Choose how Ceptra executes tests, workers, package scripts, and custom commands:

- **Built-in Console** (default): Streams output directly into Ceptra's bottom drawer with live scenario status badges, gutter durations, interactive `pause()` shell input, JUnit report parsing, and automatic Web/API Time-Travel Replay capture.
- **System Console**: Launches runs in your macOS default terminal app — or any detected terminal you pick in Settings (`Terminal.app`, `iTerm`, `Ghostty`, `Warp`, `Kitty`, `WezTerm`, `Alacritty`) — preserving login `$PATH`, native ANSI colors, custom environment variables, and handing off to an interactive shell after exit.
- Press `⌘⇧T` anytime to open the active workspace folder directly in your chosen system terminal.

---

## Parallel Execution (`run-workers` & `run-multiple`)

- **`run-workers` (`⌘⇧W`)**: Configure worker count, distribution strategy (`--by pool`, `--by test`, or `--by suite`), `--serial` pattern, `--last-failed`, and selected runs in **CodeceptJS → Configure Workers…**.
- **`run-multiple` (`⌘⇧M`)**: Automatically parses suites and `suite:browser` targets from your config's `multiple` block so you can run `--all` or pick exact browser combinations.
