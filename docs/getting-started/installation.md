# Installation & Updates

Ceptra is a native macOS application compiled directly with Swift 5.9+, SwiftUI, and AppKit — with zero Electron runtime and zero third-party Swift package dependencies.

## System Requirements

| Requirement | Details |
| --- | --- |
| **Operating System** | **macOS 14.0 (Sonoma)** or later (Apple Silicon `arm64` and Intel `x86_64`) |
| **JavaScript / TypeScript Suites** | **Node.js** (22.12+ recommended for Mobilewright) or **Bun** |
| **Playwright Python Suites** | **Python 3.9+** with `pytest-playwright` (`uv`, `poetry`, `.venv`, or `pip`) |
| **Mobilewright Live Mirror** | **Xcode iOS Simulator** (free, zero signing) and/or **ADB** (`brew install android-platform-tools`) |
| **Building from Source** | **Swift 5.9+** (Xcode 15+ or Xcode Command Line Tools) |

!!! tip "API Client Studio requires zero external runtimes"
    Ceptra's built-in **API Client Studio** runs natively on Apple's `URLSession` — you can import, edit, run, and export Postman, Insomnia, OpenAPI, HAR, `.http`, and cURL collections even without Node.js or Python installed.

---

## Option 1: Install Prebuilt DMG (Recommended)

1. Download the latest `Ceptra-*-macOS-*.dmg` from [**GitHub Releases**](https://github.com/kobenguyent/Ceptra/releases/latest).
2. Open the `.dmg` and drag **Ceptra.app** into `/Applications`.
3. Because community releases use ad-hoc signing (no Apple Developer notarization gate), clear the macOS quarantine flag once in Terminal if macOS Gatekeeper warns on first launch:

   ```bash
   xattr -cr /Applications/Ceptra.app
   ```

4. Launch **Ceptra** from Spotlight, Launchpad, or `/Applications`.

---

## Option 2: Build & Install from Source

```bash
git clone https://github.com/kobenguyent/Ceptra.git
cd Ceptra
./scripts/install-local.sh
```

`install-local.sh` compiles a native Swift release binary, generates `Ceptra.icns`, assembles and ad-hoc signs `Ceptra.app`, clears quarantine attributes, installs to `/Applications/Ceptra.app`, and launches the app.

### Useful Installer Flags

=== "Install to ~/Applications (No sudo)"

    ```bash
    ./scripts/install-local.sh --install-dir "$HOME/Applications"
    ```

=== "Install Without Auto-Launching"

    ```bash
    ./scripts/install-local.sh --no-launch
    ```

=== "Package Distributable DMG & ZIP"

    ```bash
    # Native architecture
    ./scripts/package-app.sh --version 1.17.1 --arch native

    # Universal binary (Apple Silicon + Intel)
    ./scripts/package-app.sh --version 1.17.1 --arch universal
    ```

=== "Run Unit Tests"

    ```bash
    swift test --parallel
    ```

---

## In-App Auto-Updater

Ceptra checks GitHub Releases automatically (configurable in **Settings** ++cmd+comma++) or on demand via **Ceptra → Check for Updates…**:

1. Queries the latest GitHub Release for `kobenguyent/Ceptra`.
2. Selects the optimal macOS asset (`universal` or matching host architecture).
3. Verifies the downloaded archive's SHA-256 digest against `SHA256SUMS.txt` using Apple's `CryptoKit`.
4. Atomically replaces `Ceptra.app` with rollback protection and relaunches cleanly.
