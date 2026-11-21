# Monorepos, Runtimes & System Console Guide

Ceptra is built to handle real-world CodeceptJS 4.x repositories out of the box — from single-suite Playwright projects to multi-config TypeScript ESM monorepos.

---

## Multi-Config Monorepo Auto-Resolution

Many teams organize API and Web suites under one repository with separate CodeceptJS configs:

```text
my-qa-monorepo/
├── package.json
├── common/
│   └── steps/steps_file.ts
└── tests/
    ├── api/
    │   ├── codecept.conf.ts        # REST + JSONResponse (tests: './tests/**/*.ts')
    │   └── tests/orders_api_test.ts
    └── web/
        ├── codecept.conf.ts        # Playwright (tests: './tests/**/*.ts')
        └── tests/checkout_test.ts
```

### How Ceptra handles this automatically
1. **Discovery**: Scans standard config names (`codecept.conf.{ts,js,cjs,mjs}`, `codecept.config.*`, `codecept.json`), `-c` / `--config` targets declared in `package.json` scripts, and nested or custom-named configs up to 4 directories deep.
2. **Per-File Config Matching**: When you run, debug, or dry-run a specific file or scenario, Ceptra matches the file path against every discovered config's `tests` / `gherkin.features` glob and directory ancestry — automatically passing `-c tests/web/codecept.conf.ts` for web tests and `-c tests/api/codecept.conf.ts` for API tests.
3. **Environment Overrides Preserved**: If you explicitly pin an environment config (e.g. `configs/staging.conf.ts` vs `configs/prod.conf.ts`) that shares the same `tests` glob, Ceptra respects your pinned choice.
4. **Live Tab Sync**: In auto-detect mode, switching tabs between suites automatically updates the active config, status bar helper badge (`Playwright` vs `REST`), and IntelliSense completions.
5. **Manual Switching**: Click the helper pill in the bottom-right status bar (or press `⌘⇧C`) to inspect every discovered config with its helper summary, pin a config, or reset to Auto-Detect.

---

## Node.js vs Bun Runtime Switching

Switch runtimes anytime from the **Top Bar**, **Run Options**, **Settings (`⌘,`)**, or **CodeceptJS → JavaScript Runtime**:

- **Node.js (default)**:
  - Resolves project-local `./node_modules/.bin/codeceptjs` (with fallback to global `codeceptjs` or `npx`).
  - Supports **Interactive CDP Step-Through Debugging** (`⌘⇧B`).
  - Includes Ceptra's opt-out **ESM/CJS & TypeScript Compatibility Hook** (enabled by default in Run Options): uses Node's synchronous `module.registerHooks` so extensionless TS imports, `tsconfig.json` path aliases, CommonJS getter exports (e.g. `uuid`), and ESM `node_modules` packages (e.g. `flex-rest`) work smoothly in both `run` and `run-workers`.
  - **CodeceptJS 4.x TypeScript tip**: Under Node.js, CodeceptJS 4.x requires `require: ['tsx/esm']` in each `.ts` suite's `codecept.conf.ts` (along with `"type": "module"` in `package.json`).
- **Bun**:
  - Executes CodeceptJS directly via `bun` (`bun <codecept.js>` or `bun x --bun codeceptjs`) with native TypeScript transpilation — no `tsx` loader required.
  - **Tip**: Avoid mixing `npm install` and `bun install` in the same `node_modules` tree. If Bun hits a module interop error in a previously `npm`-installed repo, run `rm -rf node_modules && bun install`.

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
