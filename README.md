# AuraSense v1

AuraSense is a Bluetooth Low Energy (BLE) proximity lock, external monitor wake, and instant Keychain password auto-fill app for macOS. It lives in your macOS menu bar with an Eclipse + Proximity Orbit icon and hides from the Dock whenever you close its window.

## Quick Setup (Guided in App)

1. **Install**: Open `AuraSense.dmg` and either drag `AuraSense.app` into `Applications` or open `Install AuraSense.app` (which automatically installs `AuraSense.app` into `/Applications` and launches the 4-step Guided Setup Wizard).
2. **Grant Permissions**: In **Step 2** of the wizard, click **Prompt Permission** to grant **Accessibility** and **Bluetooth** permissions.
3. **Select Device & Calibrate**: In **Step 3**, select your iPhone or Apple Watch, place it on your desk, and click **Start 10s Desk Signal Scan**.
4. **Save Password & Auto-Fill**: In **Step 4**, save your Mac login password to the local Keychain.

## Instant iPhone Password Auto-Fill

When your Mac is connected to an external monitor and asks for a password:

1. **Open in Browser (Zero Tap)**: Open `http://192.168.1.8:8765/api/v1/faceid-autofill` (or `http://192.168.1.8:8765/faceid`) in Safari on your iPhone. Your Mac password auto-fills as soon as the page opens.
2. **Add to Home Screen**: In Safari, tap **Share > Add to Home Screen** to create a one-tap icon on your iPhone.
3. **Optional iOS POST Shortcut**: In the **Shortcuts** app, add **Get Contents of URL** with `http://192.168.1.8:8765/api/v1/faceid-autofill`, set Method to `POST`, and add it to your Home Screen.

## Release Files

- `AuraSense.dmg` / `releases/v1/AuraSense-v1.dmg`: macOS Disk Image installer.
- `AuraSense.app` / `releases/v1/AuraSense.app`: Native macOS application bundle.
- `releases/v1/AuraSense.app.zip`: Zipped macOS application bundle.

## Build from Source

```bash
cargo build --release
cd macos-host && ./Scripts/build_and_package.sh
```

## License

MIT License.
