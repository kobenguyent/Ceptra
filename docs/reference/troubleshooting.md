# Troubleshooting & FAQ

Quick solutions for the most common macOS, runtime, and framework setup questions.

---

## macOS Gatekeeper warns "Ceptra cannot be opened"

Prebuilt community releases are ad-hoc signed without an Apple Developer notarization ticket. Clear the macOS quarantine attribute once in Terminal:

```bash
xattr -cr /Applications/Ceptra.app
```

---

## CodeceptJS 4.x TypeScript ESM errors (`ERR_MODULE_NOT_FOUND` or `uuid` named import)

1. Ensure your project's `package.json` includes `"type": "module"` and each `.ts` suite's `codecept.conf.ts` includes `require: ['tsx/esm']`.
2. Verify **Node ESM/CJS Compatibility Hook** is enabled in **Run Options** (enabled by default). Ceptra injects a Node `module.registerHooks` loader that resolves extensionless TS imports, `tsconfig.json` path aliases, and CommonJS named-export packages like `uuid` across both `run` and `run-workers`.

---

## Switching from `npm` to `Bun` hits module interop errors

Avoid mixing `npm install` and `bun install` inside the same `node_modules` directory. If Bun reports an interop error in a previously `npm`-installed repository, perform a clean reinstall:

```bash
rm -rf node_modules && bun install
```

---

## Playwright Python: `ModuleNotFoundError: No module named 'pages'`

Ceptra automatically prepends your workspace root onto `PYTHONPATH` when launching `pytest`. If you also run `pytest` manually in your own terminal, add `pythonpath = .` under `[pytest]` in `pytest.ini` (or `[tool.pytest.ini_options]` in `pyproject.toml`) — Ceptra's starter Python scaffold includes this automatically.

---

## Playwright Python: Replay HTML only shows 1 step or missing API requests

Ensure you are running **Ceptra v1.15.0+** and that **Time-Travel Trace** is enabled in Run Options. Ceptra automatically passes `--tracing=on -p ceptra_pw_time_travel`, hydrates `trace.zip` during `pytest-playwright`'s `teardown` phase, reconstructs Playwright 1.50+/1.60 delta DOM snapshots, and captures standalone `APIRequestContext` calls in-process even when no browser `page` fixture is used.

---

## Mobilewright: Simulator or Android device not detected

1. Click **Connect Mobile Device…** (in the **Tools** popover or **View** menu) to run `mobilewright doctor` inline.
2. For **iOS Simulator** (free, no signing): make sure Xcode Command Line Tools are selected (`xcode-select -p`) and at least one iOS Simulator runtime is installed in Xcode → Settings → Components.
3. For **Android**: install ADB (`brew install android-platform-tools`), enable **USB Debugging** on the device, and verify `adb devices` shows `device` (not `unauthorized`).

---

## Local Ollama AI Assistant cannot connect

Open the **AI Assistant** (++cmd+option+a++), open **Configure AI Providers…**, and use the guided **Local Ollama** controls to start the local Ollama server (`http://127.0.0.1:11434`) and pull a coding model (such as `qwen2.5-coder:7b`) with live progress streaming.
