# Ceptra Mobilewright Demo (`@codeceptjs/mobilewright`)

Ready-to-run **CodeceptJS 4.x + [`@codeceptjs/mobilewright`](https://github.com/codeceptjs/mobilewright-helper)** workspace for **Ceptra**.

## Quick Start

```bash
cd examples/mobilewright-demo
npm install
npm test
```

## Multi-Config Profiles (Auto-Detected in Ceptra)

1. **`codecept.conf.js` (Default — Zero-Emulator Virtual Driver):**
   - Runs all 4 mobile scenarios (`@smoke`, `@cart`, `@auth`, `@device`) in **< 1 second** with no booted simulator or emulator required.
   - Emits real PNG screen frames and interactive accessibility view-tree hierarchies so you can inspect **Before/After Mobile Screenshots**, **Red Target Bounding-Box Reticles**, and the **Accessibility Tree** inside Ceptra's **Time-Travel Replay Inspector (`⌘⌥T`)**.
2. **`codecept.ios.conf.js` (Live iOS Simulator):**
   - Runs against a booted Xcode iOS Simulator (`npx mobilewright doctor` to check setup).
3. **`codecept.android.conf.js` (Live Android Emulator / Device):**
   - Runs against a booted Android emulator or USB-connected device.
