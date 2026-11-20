# Ceptra

**Ceptra** is a minimalist, native macOS IDE crafted specifically for **CodeceptJS 4.x** (`SwiftUI` + `AppKit`, zero Electron overhead, zero external Swift dependencies).

## Key Capabilities

- **CodeceptJS 4.x Workspace Explorer**: Automatically detects `codecept.conf.{ts,js,cjs,mjs}` / `codecept.config.*`, `package.json`, Helpers (`Playwright`, `Puppeteer`, `WebDriver`, `CDPBrowser`, `REST`, `GraphQL`, `Appium`, custom helpers), `include` Page/Step objects, Plugins (`screenshot`, `screencast`, `aiTrace`, `junitReporter`, `heal`, `retryFailedStep`), JS/TS suites, and Gherkin `.feature` files.
- **Visual Scenario & Step Pipeline**: Interactive side-by-side **Split** or **Visual** mode rendering `Feature`, lifecycle hooks (`BeforeSuite`, `Before`, `After`, `AfterSuite`, `Background`), `Scenario` / `xScenario` / `Data(...).Scenario`, `@tags`, and color-coded `I.*` step flows. Clicking any node jumps straight to that line in the code editor.
- **Native macOS Code Editor**: Explicit TextKit 1 `NSTextView` with a sibling line-number gutter, CodeceptJS 4.x / TypeScript / JavaScript / Gherkin syntax highlighting, Find & Replace (`⌘F`), quick CodeceptJS snippet insertion, and template scaffolding (`⌘N`).
- **Focused Test Execution**: Run all tests (`⌘R`), current file (`⌘⇧R`), single scenario, `@tag`, `--last-failed`, `dry-run`, `run-workers <N> --by pool`, `check`, `def`, and `list` with live streaming console logs and real-time scenario status updates.
- **Reports & Artifacts Dashboard**: Persists per-project run history with pass-rate trend bars, parses CodeceptJS 4.x `junitReporter` XML (including nested `<system-out>` steps, tags, and failure stack traces), previews `output/` artifacts (Screenshots, `aiTrace` markdown traces, Screencasts/Subtitles, HTML reports), and exports reports to Markdown or standalone HTML.
- **GitHub Releases Auto-Updater**: Checks GitHub Releases (`kobenguyent/Ceptra` by default, configurable in Settings), downloads the macOS `.zip`/`.dmg` artifact with live progress, cryptographically verifies `SHA256SUMS.txt` via `CryptoKit`, then closes the running app and atomically replaces & relaunches `Ceptra.app` via a detached helper with rollback protection.

---

## Install on Your MacBook Pro (No Apple Developer Account Needed)

You do **not** need a paid Apple Developer Program account to build, install, and test Ceptra locally on macOS 14+:

```bash
./scripts/install-local.sh
```

What `install-local.sh` does automatically:
1. Compiles an optimized native release binary via Swift Package Manager (`swift build -c release`).
2. Generates a multi-resolution `Ceptra.icns` app icon and assembles `Ceptra.app` with `Info.plist`.
3. Applies an **ad-hoc code signature** (`codesign --force --deep --sign -`) required for Apple Silicon execution.
4. Strips macOS quarantine attributes (`xattr -cr`) so Gatekeeper does not block local testing.
5. Installs to `/Applications/Ceptra.app` and launches Ceptra.

To install into your user directory without `sudo`:

```bash
./scripts/install-local.sh --install-dir "$HOME/Applications"
```

To build distribution artifacts (`.dmg`, `.zip`, `SHA256SUMS.txt`) locally:

```bash
./scripts/package-app.sh --version 1.0.0 --arch native
# or universal (arm64 + x86_64):
./scripts/package-app.sh --version 1.0.0 --arch universal
```

---

## GitHub Actions Releases & Auto-Update

- **CI (`.github/workflows/ci.yml`)**: Runs `swift test --parallel`, release build, native `.app`/`.dmg`/`.zip` packaging, and `SHA256SUMS.txt` verification on `macos-15`.
- **Release (`.github/workflows/release.yml`)**: Push a semantic tag (e.g. `git tag v1.0.0 && git push origin v1.0.0`) or trigger manually via **Actions → Release → Run workflow** to publish a GitHub Release with:
  - `Ceptra-<version>-macOS-universal.dmg`
  - `Ceptra-<version>-macOS-universal.zip`
  - `SHA256SUMS.txt`

In-app updates check `Ceptra → Check for Updates…` (or automatically on launch), verify the SHA-256 digest, quit Ceptra cleanly, replace the bundle, clear quarantine, and relaunch the updated app.

---

## Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘O` | Open CodeceptJS workspace |
| `⌘N` | New test / page object / Gherkin feature / helper |
| `⌘S` | Save current file |
| `⌘R` | Run all tests |
| `⌘⇧R` | Run current file |
| `⌘⇧D` | Dry run (validate & discover) |
| `⌘.` | Stop active run |
| `⌘B` | Toggle sidebar |
| `⌘J` | Toggle execution console |
| `⌘F` | Find & Replace in editor |
| `⌘,` | Open Settings |

## Requirements

- macOS 14.0 (Sonoma) or later
- Swift 5.9+ (Command Line Tools or Xcode) for building from source
- Node.js + CodeceptJS 4.x installed in your test project (or globally)
