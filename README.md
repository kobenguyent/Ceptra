<p align="center">
  <img src="docs/images/ceptra-icon.png" width="112" height="112" alt="Ceptra App Icon" />
</p>

<h1 align="center">Ceptra</h1>

<p align="center">
  <strong>Native macOS IDE for CodeceptJS 4.x, Playwright (TS/JS &amp; Python), Mobilewright &amp; API Collections.</strong><br/>
  Built in SwiftUI &amp; AppKit — zero Electron overhead, zero third-party Swift dependencies.
</p>

<p align="center">
  <a href="https://github.com/kobenguyent/Ceptra/releases/latest">
    <img src="https://img.shields.io/github/v/release/kobenguyent/Ceptra?style=flat-square&color=3b82f6&label=release" alt="Latest Release" />
  </a>
  <img src="https://img.shields.io/badge/macOS-14.0%2B-111827?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/CodeceptJS-4.x-f59e0b?style=flat-square&logoColor=white" alt="CodeceptJS 4.x" />
  <img src="https://img.shields.io/badge/Playwright-TS%20%7C%20JS%20%7C%20Python-2ead33?style=flat-square&logoColor=white" alt="Playwright Test & Python" />
  <img src="https://img.shields.io/badge/Mobilewright-iOS%20%26%20Android-0ea5e9?style=flat-square&logoColor=white" alt="Mobilewright iOS & Android" />
  <img src="https://img.shields.io/badge/API%20Studio-Postman%20%7C%20Insomnia%20%7C%20OpenAPI-06b6d4?style=flat-square&logoColor=white" alt="API Client Studio" />
  <img src="https://img.shields.io/badge/Swift-5.9%2B%20Native-f97316?style=flat-square&logo=swift&logoColor=white" alt="Pure Swift" />
  <img src="https://img.shields.io/badge/Runtime-Node.js%20%7C%20Bun%20%7C%20Python-10b981?style=flat-square&logoColor=white" alt="Node.js, Bun & Python" />
  <a href="LICENSE">
    <img src="https://img.shields.io/github/license/kobenguyent/Ceptra?style=flat-square&color=6366f1" alt="License" />
  </a>
</p>

<p align="center">
  <a href="#why-ceptra">Why Ceptra</a> &nbsp;·&nbsp;
  <a href="#feature-highlights">Features</a> &nbsp;·&nbsp;
  <a href="#quick-start">Quick Start</a> &nbsp;·&nbsp;
  <a href="#documentation">Docs &amp; Guides</a> &nbsp;·&nbsp;
  <a href="docs/SHORTCUTS.md">Shortcuts</a>
</p>

<p align="center">
  <img src="docs/images/studio-dark-hero.png" alt="Ceptra Obsidian Dark 3-Pane Studio running a CodeceptJS 4.x monorepo" width="100%" />
</p>

---

## Why Ceptra?

Running **CodeceptJS 4.x**, **Playwright Test (`@playwright/test` &amp; `pytest-playwright`)**, **Mobilewright (`@codeceptjs/mobilewright`)**, and REST/GraphQL API collections across TypeScript, Python, ESM, and mobile devices usually means juggling an IDE, Postman/Insomnia, Appium/simulators, terminal tabs, and config flags. **Ceptra** brings all of them into one native macOS workspace:

| Challenge | How Ceptra Solves It |
| --- | --- |
| **Slow, memory-hungry editors** | Native **SwiftUI + AppKit** (`TextKit 1`) — fast startup, crisp typography, smooth pinch &amp; scroll zoom, full tab context menus, anchored multi-tab switcher with duplicate-filename hints, and zero Electron footprint. |
| **Switching to Postman or Insomnia** | **Built-in API Client Studio** (`⌘⌥I`) — clean-room import, edit, run, chain, and export collections &amp; environments across **Postman v2.1**, **Insomnia v4**, **OpenAPI 3.x**, **HAR 1.2**, **`.http`**, **`.env`**, and **cURL** — plus 1-click automated test generation &amp; Replay HTML export. |
| **First-class CodeceptJS &amp; Playwright (TS/JS + Python)** | Auto-detects `codecept.conf.*`, `playwright.config.{ts,js,mjs,cjs}`, and Python `pytest.ini`/`pyproject.toml` (`uv`, `poetry`, `.venv`), scaffolds starter workspaces for all three, embeds **Playwright UI Mode** &amp; `@codeceptjs/ui`, plus **Playwright Codegen**, callback-arg IntelliSense, and adaptive terminal commands. |
| **Native iOS &amp; Android mobile testing** | **Mobilewright Device Studio** (`⌘⌥M`) — guided 4-step Connect Device Wizard, live phone mirror sidebar with **Touch &amp; Swipe** / **Inspect** / **Wireframe** modes, exact hardware viewport calibration, ranked zero-CSS/XPath locators, and live step recording without an Appium server. |
| **Blind test failures** | **Zero-config Web, API &amp; Mobile Time-Travel Replay** — automatic step screenshots, full delta-reconstructed DOM/view-tree snapshots, HTTP/fetch &amp; `APIRequestContext` capture (including Python `pytest-playwright`), JSON tree &amp; timing waterfall, exported as a single offline HTML file. |
| **Painful debugging** | **Built-in CDP Step-Through Debugger** (`⌘⇧B`) with gutter breakpoints, conditional breakpoints, logpoints, locals, watch expressions, `PWDEBUG=1` Inspector support, and CodeceptJS's interactive `pause()` shell. |
| **Monorepo config mistakes** | **Automatic per-file config &amp; runtime resolution** — detects every `codecept.conf.*`, `playwright.config.*`, and Python test root in polyglot monorepos, picks the owning config &amp; toolchain automatically, adapts terminal quick commands to `uv`/`poetry`/`.venv`/`npm`/`pnpm`/`yarn`/`bun`, and switches between Built-in &amp; System Console in one click. |
| **Authoring &amp; fixing tests** | **Multi-Provider AI Assistant &amp; `/commands`** (`⌘⌥A`) — framework-aware prompts for CodeceptJS, Playwright TS/JS, Playwright Python, and Mobilewright with **Local Ollama**, Cloud APIs, or local CLI agents, multimodal attachments, portable `SKILL.md` skills, and 3-tier workspace permission controls. |
| **Sharing test snippets** | **Code Block Screenshots** (`⌘⌥P` / `⌘⌥⇧P`) — 1-step 2×/3× Retina PNG snapshots of any selection or enclosing `test()` / `Scenario()` block with gradients, themes, and macOS chrome. |

---

## Feature Highlights

### 1. Zero-Config Web, API &amp; Playwright Python Time-Travel Replay
Run any Web, API, or Mobile test across **CodeceptJS**, **Playwright (TS/JS)**, or **Playwright Python (`pytest-playwright`)** and scrub backward and forward through every step — directly in the embedded **Replay Inspector** (`⌘⌥T`) or in a **self-contained offline HTML report** ready for CI artifacts, Jira tickets, or Slack.

- **API Replay**: Automatically captures `REST`, `GraphQL`, `node:http`/`https`, `fetch`, `axios`, `flex-rest`, Playwright `request`, and Playwright Python `APIRequestContext` + `expect(response).to_be_ok()` traffic (including `BeforeSuite` setup and `br`/`gzip` decompression) with secret header redaction, collapsible **JSON Tree** with click-to-copy JSONPath, **DNS/TCP/TLS/TTFB/Download timing waterfall**, assertion cards, structural JSON diff, one-click **Copy as `cURL` / `fetch()` / CodeceptJS / Playwright (TS &amp; Py)**, and inline **Live Replay**.
- **Web Replay**: Captures **Before &amp; After screenshots** with curtain diff &amp; target selector reticles, full **DOM snapshots** (including Playwright 1.50+/1.60 incremental delta DOM reconstruction and teardown `trace.zip` hydration), correlated browser network requests, and console/page errors — automatically distinguishing Web, API, and Hybrid scenarios in mixed suites.

<p align="center">
  <img src="docs/images/feature-api-replay.png" alt="Ceptra Interactive API Replay HTML Report with JSON Tree, Timing Waterfall and Copy cURL" width="100%" />
</p>

<p align="center">
  <img src="docs/images/feature-web-replay.png" alt="Ceptra Interactive Web Replay HTML Report with Before/After Screenshots, Target Reticle and DOM Inspector" width="100%" />
</p>

---

### 2. Built-in API Client Studio (`⌘⌥I`) — Postman, Insomnia, OpenAPI, HAR &amp; cURL
Import, edit, run, chain, and export API collections and environments right inside Ceptra — **zero third-party SDKs, clean-room MIT-compatible Swift implementation**:

- **Auto-Detect Import &amp; Multi-Format Export**: Import **Postman Collection v2.1/v2.0**, **Postman Environments/Globals**, **Insomnia v4 JSON** (collections, folders &amp; base/sub environments in one file), **OpenAPI 3.x / Swagger 2.0 JSON**, **HAR 1.2**, **`.http`/`.rest`**, **`.env`**, and **cURL** (or right-click any matching file in the Explorer → **Import into API Studio**). Export back to **Postman v2.1** (with synthesized `pm.test` scripts), **Insomnia v4**, **`.http`**, **`.env`**, or Ceptra JSON.
- **Full Request Editor &amp; Variable Chaining**: Edit Params, Headers, Auth inheritance (**Bearer**, **Basic**, **API Key**), Body (**JSON** with formatter, **Raw**, **Form URL-Encoded**, **Multipart File Upload**, **GraphQL Query + Variables**), declarative **Assertions** (Status, Latency, Headers, JSONPath, Regex), and **Variable Extractors** (`$.token` → `{{authToken}}`) with `{{var}}` and dynamic `{{$guid}}`/`{{$isoTimestamp}}` resolution.
- **Secret-Safe Environments**: Manage multiple environments with separate shared `Initial Value` vs local `Current Value`, secret masking &amp; reveal toggle, and automatic **secret redaction on export** by default.
- **Collection Runner → Replay HTML &amp; Automated Tests**: Run entire collections or folders sequentially with real DNS/TCP/TLS/TTFB/Download timings and cookie inspection, open runs directly in **Time-Travel Replay** or export offline **Replay HTML**, and generate **cURL / CodeceptJS / Playwright TS / Playwright Python** snippets or complete automated test suite files in one click.
- **Instant Runnable Examples**: Load **3 live example collections** (*REST CRUD &amp; Variable Chaining*, *HTTPBin Auth/Forms/Cookies*, *Countries GraphQL*) directly into API Studio, or generate a full `api-examples/` folder of ready-to-import Postman, Insomnia, OpenAPI, `.http`, and `.env` files to test every importer/exporter immediately.

---

### 3. Mobilewright Device Studio (`⌘⌥M`) — Live Mirror &amp; Appium-Style Inspector
Test native **iOS** and **Android** apps with [`@codeceptjs/mobilewright`](https://mobilewright.dev) directly inside Ceptra — no Appium server required:

- **Guided 4-Step Connect Device Wizard**: Categorized **Virtual Devices** (**iOS Simulator** — free, zero signing; **Android Emulator**) vs **Physical Devices** (**Real Android USB**, **Real iPhone / iPad**), built-in `mobilewright doctor` with 1-click prerequisite installs, searchable `iPhone` / `iPad` / `All` simulator filters, and automatic `.mobileprovision` wildcard profile validation.
- **Smooth Live Phone Mirror &amp; Gestures**: Fast core framebuffer capture on iOS Simulators (`xcrun simctl io`), 2-stage post-action settle refresh, idle auto-stream that automatically re-syncs the UI tree when screen content changes, **Touch &amp; Swipe** mode (click-to-tap + live drag-to-swipe directional arrow), 1-click directional swipe pad (`↑ ↓ ← →`), and iOS edge back-swipe.
- **Appium-Style Precision Inspector**: Exact hardware viewport calibration (`mobilecli device info` + pixel fallback) so floating iOS permission alerts and modals align pixel-accurately, optional **Wireframe Bounds** overlay, ranked Mobilewright locators (`~accessibilityId`, `#resourceId`, `{ role, name }` — zero CSS/XPath), automatic `secret()` masking for password fields, live **Rec** step recording into the active editor, and a 1-click cross-platform **Sample Test** generator (plus a zero-device demo in [`examples/mobilewright-demo/`](examples/mobilewright-demo/)).

<p align="center">
  <img src="docs/images/studio-mobilewright.png" alt="Ceptra Mobilewright Device Studio with live iOS Simulator mirror, precision element reticle, wireframe bounds, ranked locators, and test runner" width="100%" />
</p>

<p align="center">
  <img src="docs/images/feature-mobilewright-wizard.png" alt="Ceptra Connect Mobile Device wizard categorized into Virtual Devices and Physical Devices with live status badges" width="76%" />
</p>

---

### 4. Interactive Step-Through CDP Debugger (`⌘⇧B`)
Debug CodeceptJS tests line-by-line in the editor with Chrome DevTools Protocol integration and source-mapped TypeScript support:

- Toggle breakpoints in the gutter or right-click to add **Conditional Breakpoints** and non-pausing **Logpoints**.
- Step with the floating **Debug Control Bar** — Continue (`⌃⌘Y`), Pause, Step Over (`⌘⇧'`), Step Into (`⌘⇧I`), Step Out (`⌘⇧O`).
- Inspect **Call Stack** (with *Just My Code* filtering), **Scopes &amp; Variables**, persistent **Watch Expressions**, live **Debug Eval**, and CodeceptJS's interactive `pause()` shell.

<p align="center">
  <img src="docs/images/studio-debugger.png" alt="Ceptra Interactive CDP Debugger paused on a breakpoint with Call Stack and Local Variables" width="100%" />
</p>

---

### 5. Native AI Assistant, Universal `/commands` &amp; `SKILL.md` (`⌘⌥A`)
Write scenarios, harden flaky locators, and diagnose Replay traces using local models, cloud APIs, or local CLI tools:

- **Local Ollama, Cloud APIs &amp; CLI Agents**:
  - **Local Ollama**: Guided setup, 1-click local server start, and streaming model downloader — no API key required.
  - **Cloud APIs**: Anthropic Claude, OpenAI, Google Gemini, GitHub Models, and OpenAI-Compatible endpoints (LM Studio, vLLM, OpenRouter, Groq, DeepSeek).
  - **Local CLI Agents**: Reuses existing local logins for Claude Code (`claude`), OpenAI Codex (`codex`), Gemini CLI (`gemini`), and GitHub Copilot (`gh copilot`).
- **Universal `/commands` &amp; Portable `SKILL.md`**:
  - Built-in CodeceptJS 4.x commands work identically across Local Ollama, Cloud APIs, and CLI Agents: `/scenario`, `/fix`, `/page-object`, `/debug`, `/explain`, `/review`, `/api-test`, `/gherkin`, and `/skills`.
  - Discovers custom `SKILL.md` and command markdown files from `.ceptra/skills`, `.ceptra/commands`, `.agents/skills`, `.claude/skills`, `.codex/skills`, and `~/.ceptra/skills` (`Workspace > Built-in > Global`), with 1-click skill scaffolding.
- **Multimodal Attachments**: Paste (`⌘V`) or drag-and-drop screenshots, code/log files, PDFs, and `.mp4`/`.mov` test recordings alongside toggleable workspace context pills (`File`, `Selection`, `Console Errors`, `Replay Trace`, `I.* API`).
- **3-Tier Permissions &amp; Security**: Switch between **Read-Only** (`Read`), **Ask to Proceed** (`Ask`, unified diff preview before applying), and **Full Permissions** (`Full`, 1-click undoable Apply jailed to the open workspace). API keys stay in macOS Keychain; sensitive files (`.env`, private keys, `~/.ssh`, `~/.aws`, credentials) are blocked and automatically redacted before cloud requests.

<p align="center">
  <img src="docs/images/studio-ai-assistant.png" alt="Ceptra Native AI Assistant with Local Ollama, Universal /commands (SKILL.md), Apply/Diff, and 3-Tier Permission Mode" width="100%" />
</p>

---

### 6. Code Block Screenshots (`⌘⌥P` / `⌘⌥⇧P`)
Turn any selected lines — or the enclosing `Scenario()`, `Feature`, function, or Gherkin block at your caret — into a **2× / 3× Retina PNG** inside the IDE:

- **1-Step Quick Copy (`⌘⌥⇧P`)** or right-click → **Quick Copy Screenshot** copies the PNG straight to your macOS clipboard (`⌘V` into Slack, GitHub, Notion, or Keynote).
- **Code Screenshot Studio (`⌘⌥P`)** includes **8 backdrops** (Candy, Midnight, Breeze, Sunset, Emerald, Amber, Graphite, and **Transparent**), **5 syntax themes** (Obsidian, Dracula, Catppuccin, Tokyo Night, Paper Light), auto-dedent with real line numbers, macOS window chrome, drag-and-drop export, and Save PNG (`⌘S`).

<p align="center">
  <img src="docs/images/feature-code-snapshot-studio.png" alt="Ceptra Code Screenshot Studio with live preview, gradient swatches, and syntax themes" width="100%" />
</p>

<p align="center">
  <img src="docs/images/feature-code-snapshot-sample.png" alt="2x Retina PNG code block screenshot rendered directly by Ceptra" width="84%" />
</p>

---

### 7. Adaptive Light &amp; Dark Themes · Polyglot Monorepos &amp; Adaptive Terminal
Supports **Obsidian Dark**, **Paper Light**, and **Match macOS**:

- **Polyglot Multi-Config Monorepo Support**: Automatically discovers every `codecept.conf.*`, `playwright.config.*`, and Python `pytest.ini`/`pyproject.toml` across nested packages (`tests/web/`, `tests/api/`, `configs/`), resolves the owning config &amp; runner per file on Run/Debug/Dry-Run, and auto-syncs the status bar helper (`Playwright` ↔ `Playwright (Py)` ↔ `REST`) and IntelliSense as you switch tabs.
- **Adaptive Runtime-Detected Terminal Commands**: The Terminal drawer automatically detects your active runtime (`uv`, `poetry`, `.venv`, `pip`, `npm`, `pnpm`, `yarn`, `bun`) and adapts pre-suggested quick commands, dependency installs (including automatic `.venv` bootstrapping for Python), and framework CLI helpers accordingly.
- **Node.js, Bun &amp; Python Switcher + System Console**: Toggle between Node.js (with zero-config ESM/CJS &amp; TypeScript worker compatibility) and Bun in one click, or launch natively in **Terminal.app**, **iTerm**, **Ghostty**, **Warp**, **Kitty**, **WezTerm**, or **Alacritty** (`⌘⇧T`).

<p align="center">
  <img src="docs/images/studio-light.png" alt="Ceptra Paper Light theme with auto-detected REST API config and embedded API Replay" width="100%" />
</p>

---

### 8. Editor &amp; Runner Craft (CodeceptJS, Playwright TS/JS &amp; Python)
- **Gutter Scenario &amp; Test Play Buttons**: Click any `Scenario()`, `test()`, or Python `def test_*` in the gutter to run it immediately and see live pass/fail badges &amp; durations.
- **Many-Files Tab Context Menu &amp; Switcher**: Right-click any tab (or the empty tab rail) to **Close**, **Close Others (`⌘⌥W`)**, **Close Tabs to the Right / Left**, **Close Saved Tabs**, **Close All Tabs**, **Reopen Closed Tab**, **Save**, **Run/Debug Test File**, **Copy Path**, or **Reveal in Explorer / Finder**. Includes an anchored **Open Tabs Switcher** pill when multiple files are open and automatic parent-folder disambiguation for duplicate filenames.
- **Starter Workspace Scaffolding**: Create ready-to-run **Playwright Test (TypeScript)**, **Playwright Python (`pytest-playwright`)**, or **CodeceptJS 4.x** workspaces directly from the Welcome screen, File menu, top-bar Workspace switcher, or Command Palette (`⌘K`).
- **PyCharm-Style Symbol Navigation**: `⌘+Click` / `⌃+Click` / `F12` jumps across imports, `require()`, TypeScript path aliases, barrel re-exports, `include` Page Objects, custom `I.*` steps, Gherkin step definitions, and usages — with Back/Forward history (`⌃-` / `⌃⇧-`).
- **Smart Framework-Aware IntelliSense &amp; Code Folding**: Auto-complete on `.`, `@`, `/` or `Ctrl+Space` for `I.*` actions, `steps.d.ts`, Playwright callback fixture arguments (`async ({ page, request })` &amp; `def test_(page: Page):`), snake_case Python Playwright APIs, Page Objects, and `@tags`; non-destructive folding (`⌘⌥[` / `⌘⌥]`) for JS/TS/Python/JSON/Gherkin/YAML/Markdown/XML.
- **Parallel Execution**: **`run-workers`** (`⌘⇧W` — `--by pool|test|suite`, `--serial`, `--last-failed`, Playwright `--workers`, `pytest -n`) and **`run-multiple`** (`⌘⇧M` — parsed `suite:browser` / Playwright project targets).
- **Embedded `@codeceptjs/ui` &amp; Playwright UI Live (`⌘⌥U`)**: Launch and inspect CodeceptUI or Playwright UI on loopback (`127.0.0.1`) inside the right inspector.
- **Command Palette (`⌘K` / `⌘P`) &amp; Smooth Zoom**: Fuzzy-jump to any file, scenario, or action; pinch or `⌘+`/`⌘−`/`⌘0` to zoom smoothly with scroll anchoring.

---

## Quick Start

### Option 1: Download Prebuilt App
1. Download the latest `Ceptra-*-macOS-*.dmg` from [**GitHub Releases**](https://github.com/kobenguyent/Ceptra/releases/latest).
2. Drag **Ceptra.app** into `/Applications`.
3. If macOS Gatekeeper warns on first launch (ad-hoc signed build), run once in Terminal:
   ```bash
   xattr -cr /Applications/Ceptra.app
   ```
4. Launch **Ceptra**, press `⌘O`, and open any CodeceptJS 4.x project (or scaffold a starter workspace from the Welcome screen).

### Option 2: Build &amp; Install from Source
```bash
git clone https://github.com/kobenguyent/Ceptra.git
cd Ceptra
./scripts/install-local.sh
```

`install-local.sh` compiles a native Swift release binary, generates `Ceptra.icns`, assembles and ad-hoc signs `Ceptra.app`, clears quarantine attributes, installs to `/Applications/Ceptra.app`, and launches Ceptra.

- Install into your home directory without `sudo`:
  ```bash
  ./scripts/install-local.sh --install-dir "$HOME/Applications"
  ```
- Build distributable `.dmg`, `.zip`, and `SHA256SUMS.txt` locally:
  ```bash
  ./scripts/package-app.sh --version 1.17.1 --arch native
  # or universal (arm64 + x86_64):
  ./scripts/package-app.sh --version 1.17.1 --arch universal
  ```
- Run the Swift unit test suite or the offline Mobilewright demo:
  ```bash
  swift test --parallel
  cd examples/mobilewright-demo && npm install && npx codeceptjs run --steps
  ```

---

## Documentation

| Guide | Contents |
| --- | --- |
| [**Features Guide**](docs/FEATURES.md) | Time-Travel Web &amp; API Replay, CDP Debugger, Native AI Assistant &amp; `/commands`, Code Block Screenshots, `@codeceptjs/ui` Live, and Editor Intelligence. |
| [**Monorepos, Runtimes &amp; Console**](docs/MONOREPO-AND-RUNTIMES.md) | Multi-config monorepo auto-resolution (`tests/web` + `tests/api`), Node.js vs Bun setup, TypeScript `tsx/esm`, System Console, and `run-workers`. |
| [**Keyboard Shortcuts**](docs/SHORTCUTS.md) | Categorized reference of every Ceptra shortcut. |

---

## Essential Shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘K` / `⌘P` | Command Palette / Quick Open file or scenario |
| `⌘R` / `⌘⇧R` | Run all tests / Run current test file |
| `⌘⇧B` | Debug current test file (CDP breakpoints &amp; stepping) |
| `⌘⇧W` / `⌘⇧M` | Run parallel workers (`run-workers`) / Run multiple suites (`run-multiple`) |
| `⌘⌥A` | Toggle AI Assistant Inspector (`/commands` &amp; `SKILL.md`) |
| `⌘⌥I` / `⌘↩` | Toggle API Client Studio / Send active API request |
| `⌘⌥M` | Toggle Mobilewright Device Studio (Live Mirror &amp; Inspector) |
| `⌘⌥W` | Close other editor tabs |
| `⌘⌥P` / `⌘⌥⇧P` | Open Code Screenshot Studio / 1-Step Quick Copy Retina PNG |
| `⌘⌥T` / `⌘⌥U` / `⌘⌥O` | Toggle Replay Inspector / CodeceptUI Live / Flow Outline |
| `⌘+Click` / `F12` | Go to declaration, import target, `I.*` step, or usages |
| `⌘B` / `⌘J` / `⌘⌥B` | Toggle Explorer / Terminal Drawer / Right Inspector |

See all shortcuts in [**docs/SHORTCUTS.md**](docs/SHORTCUTS.md).

---

## Requirements

- **macOS 14.0 (Sonoma)** or later (Apple Silicon &amp; Intel)
- **Node.js** (22.12+ recommended for Mobilewright) or **Bun** for CodeceptJS 4.x / Playwright Test, or **Python 3** (`uv` / `poetry` / `.venv`) for `pytest-playwright`
- **Xcode iOS Simulator** (free, zero signing) or **ADB** (`brew install android-platform-tools`) when using Mobilewright live device mirroring
- **Swift 5.9+** (Xcode or Command Line Tools) only if building from source

---

## Automatic Releases &amp; In-App Auto-Updater

- **CI (`.github/workflows/ci.yml`)**: Runs `swift test --parallel`, release builds, `.app`/`.dmg`/`.zip` packaging, and `SHA256SUMS.txt` verification on `macos-15`.
- **Automatic Release (`.github/workflows/release.yml`)**: Computes SemVer bumps via `scripts/next-version.sh`, builds universal (`arm64` + `x86_64`) archives, signs checksums, tags, and publishes GitHub Releases automatically on push to `main` (add `[skip release]` to skip).
- **In-App Updater**: **Ceptra → Check for Updates…** downloads the latest GitHub Release, verifies `SHA256SUMS.txt` via `CryptoKit`, and atomically updates &amp; relaunches `Ceptra.app` with rollback protection.

---

## License

Released under the [MIT License](LICENSE).
