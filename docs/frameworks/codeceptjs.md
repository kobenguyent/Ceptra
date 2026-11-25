# CodeceptJS 4.x Guide

Ceptra was engineered from day one around **CodeceptJS 4.x** workflows — covering Playwright, Puppeteer, WebDriver, REST/GraphQL, Gherkin BDD, TypeScript ESM, and multi-config monorepos.

---

## Automatic Project & Config Discovery

When you open any folder (++cmd+o++), Ceptra automatically scans:

- Standard configs: `codecept.conf.{ts,js,cjs,mjs}`, `codecept.config.*`, `codecept.json`
- Custom `-c` / `--config` paths referenced in `package.json` scripts
- Nested suite configs up to 4 directories deep (e.g., `tests/web/codecept.conf.ts` and `tests/api/codecept.conf.ts`)
- Helpers (`Playwright`, `Puppeteer`, `WebDriver`, `REST`, `GraphQL`, `JSONResponse`, `Mobilewright`), `include` Page Objects, `gherkin.features`, `multiple` browser blocks, and `steps.d.ts`

!!! info "Zero config mutations required"
    Ceptra injects its Time-Travel recorder plugin (`ceptraTimeTravel`) and `junitReporter` via CLI `-o` overrides at runtime — your `codecept.conf.*` stays completely untouched in Git.

---

## Authoring Features, Scenarios & Gherkin

- **Gutter Play Controls**: Every `Scenario(...)` and Gherkin `Scenario:` / `Scenario Outline:` renders an inline green play button in the editor gutter along with live pass/fail status icons and duration badges.
- **IntelliSense Auto-Complete**: Triggered automatically on `.`, `@`, `/` or ++ctrl+space++:
  - `I.*` helper actions and custom steps parsed from `steps_file.*` and `steps.d.ts`
  - Registered `include` Page Objects and helper methods
  - Workspace `@tags` and relative import paths
- **PyCharm-Style Symbol Navigation**: ++cmd++ + Click (or ++f12++) jumps straight to Page Object definitions, custom `I.*` steps, Gherkin step definitions (`Given`/`When`/`Then`), TypeScript path aliases, and usages across the repo — with Back/Forward history (++ctrl+minus++ / ++ctrl+shift+minus++).
- **Scaffolding & Snippets**: Create new Test Suites, Page Objects, Step Objects, or Gherkin `.feature` files via ++cmd+n++, or insert ready-made CodeceptJS snippets from the **Tools** popover.

---

## Running & Parallel Execution

| Action | Shortcut | CLI Equivalent |
| --- | --- | --- |
| Run All Tests | ++cmd+r++ | `codeceptjs run --steps` |
| Run Active Test File | ++cmd+shift+r++ | `codeceptjs run <file> -c <resolved-config> --steps` |
| Dry Run (Validate) | ++cmd+shift+d++ | `codeceptjs dry-run` |
| Run Workers | ++cmd+shift+w++ | `codeceptjs run-workers <N> --by <pool\|test\|suite>` |
| Run Multiple Suites | ++cmd+shift+m++ | `codeceptjs run-multiple --all` |
| Debug Active File | ++cmd+shift+b++ | Node `--inspect-brk` + built-in CDP Debugger |

### Parallel Workers & Multiple Suites

Open **Run → Configure Workers…** or **Configure Multiple Run…** to configure:

- **Worker count** (`2`–`16`) and strategy (`--by pool`, `--by test`, `--by suite`)
- `--serial` regex filter and `--last-failed`
- Specific `suite:browser` targets parsed directly from your config's `multiple` block

---

## Embedded `@codeceptjs/ui` Live (`⌘⌥U`)

Toggle **CodeceptUI Live** (++cmd+option+u++) to launch `@codeceptjs/ui` strictly on loopback (`127.0.0.1`) inside Ceptra's right inspector. If `@codeceptjs/ui` isn't installed in your project yet, Ceptra offers a 1-click install prompt.

---

## ESM / CJS & TypeScript Compatibility Hook

CodeceptJS 4.x TypeScript projects using `"type": "module"` often hit extensionless import errors or CommonJS named-export mismatches inside worker threads (for example, `uuid` or `flex-rest`). Ceptra includes an opt-out **Node ESM/CJS Compatibility Hook** (using Node's `module.registerHooks`, enabled by default in **Run Options**) that resolves extensionless TS imports, `tsconfig.json` path aliases, and CJS getter exports cleanly across both `run` and `run-workers`.

See [Monorepos & Runtimes](../MONOREPO-AND-RUNTIMES.md) for full Node.js vs Bun and multi-config details.
