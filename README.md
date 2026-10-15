# AuraSense 0.1

AuraSense is a macOS Bluetooth Low Energy (BLE) proximity locking and Accessibility auto-unlocking system built in Rust (`aurasense-rs`) with a native macOS menu bar interface. It monitors the real-time signal strength (RSSI) of a selected Bluetooth device (such as an iPhone, Apple Watch, AirPods, or BLE security tag) to automatically unlock your Mac when the device is within range and lock the screen when you step away.

## Overview

AuraSense is designed for low-latency background operation from the macOS menu bar and addresses common workflow pain points on both standalone MacBooks and MacBooks connected to external monitors in closed-clamshell mode:

1. **BLE Proximity Auto-Lock and Auto-Unlock**: Continuously tracks your bound device using a 1D Kalman and Exponential Moving Average (EMA) RSSI filter with a configurable hysteresis deadband and departure grace timer.
2. **Menu-Bar-Only Operation**: Lives persistently as an icon in the macOS menu bar. Closing the configuration window automatically switches the application activation policy to `.accessory`, removing the icon from the Dock and application switcher.
3. **10-Second Desk Signal Calibration**: Samples your device's resting signal strength on your desk over a 10-second window to calculate the median RSSI and multipath standard deviation, automatically configuring optimal unlock and lock thresholds, smoothing factor, and grace period.
4. **External Monitor Display Input Wake**: Detects connected external monitors via CoreGraphics (`CGGetActiveDisplayList`) and sends a multi-stage wake signal (`IOPMAssertionDeclareUserActivity`, `IODisplayWrangler`, `caffeinate`, and an external display coordinate cursor pulse) so external DisplayPort, HDMI, and USB-C monitors wake and switch input before credentials are entered.
5. **Instant Browser and HTTP POST Keychain Auto-Fill**: Opening `http://<your-mac-lan-ip>:8765/api/v1/faceid-autofill` or `http://<your-mac-lan-ip>:8765/faceid` in any browser immediately triggers macOS password auto-fill on page load (both server-side on `GET` and client-side via an automatic `POST /api/v1/faceid-autofill` call, with a 1.5-second deduplication guard so credentials are entered once). Also includes global keyboard shortcuts (`Control+Option+Command+Space` and `Control+Option+Command+V`) and a login Keychain timeout optimizer.

## Repository Structure

```text
AuraSense/
├── Cargo.toml                  # Rust crate manifest (v0.1.0)
├── build.rs                    # Apple framework linker configuration
├── build_rust.sh               # Build script for the standalone Rust binary
├── README.md                   # Project documentation
├── RELEASE_NOTES.md            # Release 0.1 documentation and changelog
├── AuraSense.dmg               # macOS Disk Image installer (v0.1)
├── AuraSense.app/              # Compiled macOS application bundle
├── releases/
│   └── v0.1/
│       ├── AuraSense.dmg       # Release 0.1 DMG installer package
│       ├── AuraSense-0.1.dmg   # Versioned Release 0.1 DMG installer
│       ├── AuraSense.app/      # Release 0.1 macOS application bundle
│       └── AuraSense.app.zip   # Zipped Release 0.1 macOS application bundle
├── src/
│   ├── main.rs                 # Daemon entry point, CLI flags, and 10Hz watcher loop
│   ├── models.rs               # 1D Kalman + EMA filter and Apple Continuity 0x004C parser
│   ├── keychain.rs             # macOS Security.framework Keychain wrapper
│   ├── accessibility_autofill.rs # AXUIElement prompt detector, monitor wake, and CGEvent synthesis
│   ├── ble_engine.rs           # BLE proximity state machine and 10s desk calibration optimizer
│   └── faceid_passkey_bridge.rs  # Local HTTP POST /api/v1/faceid-autofill and /faceid server
└── macos-host/                 # Native macOS MenuBarExtra and window host
```

## Installation

1. Open `AuraSense.dmg` (or `releases/v0.1/AuraSense.dmg`).
2. Drag `AuraSense.app` into the `Applications` folder, or launch `Install AuraSense.app` for the guided setup assistant.
3. Grant **Accessibility** permission in **System Settings > Privacy & Security > Accessibility** and **Bluetooth** permission when prompted.
4. Save your macOS login password in the **Security & Keychain** tab (encrypted inside your local macOS login Keychain under `com.aurasense.mac.unlock-credentials`).
5. Place your device on your desk and click **Scan Desk Signal (10s)** in the **Range & Thresholds** tab to calibrate your thresholds.

## iPhone Browser Auto-Fill and POST Shortcut Setup

When using an external monitor with your MacBook lid closed, you can trigger password entry from your iPhone over your local network:

- **Instant Browser Open Auto-Fill**: Open `http://<your-mac-lan-ip>:8765/api/v1/faceid-autofill` or `http://<your-mac-lan-ip>:8765/faceid` (for example, `http://192.168.1.8:8765/api/v1/faceid-autofill`) in Safari on your iPhone. As soon as the URL is opened or brought to the foreground, AuraSense immediately wakes the display and fills the active macOS password field. You can also tap **Add to Home Screen** in Safari for one-tap launching without opening the Shortcuts app.
- **iOS Home Screen POST Shortcut**:
  1. Open the **Shortcuts** app on your iPhone, tap **+**, and name the shortcut **Mac Keychain Fill**.
  2. Add the **Get Contents of URL** action.
  3. Set the URL to `http://<your-mac-lan-ip>:8765/api/v1/faceid-autofill` and change the HTTP method from `GET` to `POST`.
  4. Tap the Share or Info icon at the bottom and select **Add to Home Screen**.
  5. Optional: To restrict access to the Shortcut on your iPhone, touch and hold the Shortcuts app icon on your Home Screen and select **Require Face ID**.

## Building from Source

To build the Rust binary with Cargo:

```bash
cargo build --release
```

To rebuild the macOS application bundle and `.dmg` installer:

```bash
cd macos-host
./Scripts/build_and_package.sh
```

## License

MIT License. Copyright (c) 2026 AuraSense Project.
