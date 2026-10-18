# AuraSense v1.0

AuraSense is a Bluetooth Low Energy (BLE) proximity lock, external monitor wake, and instant Keychain password auto-fill app for macOS. It lives in your macOS menu bar with an Eclipse + Proximity Orbit icon and hides from the Dock whenever you close its window.

## Quick Setup (3 Steps)

1. **Install**: Open `AuraSense.dmg` and drag `AuraSense.app` into `Applications`.
2. **Grant Permissions**: Open `AuraSense.app` and enable **Accessibility** in **System Settings > Privacy & Security > Accessibility** and **Bluetooth** when prompted.
3. **Save Password & Calibrate**: Enter your Mac password in the **Security & Keychain** tab, place your iPhone or Apple Watch on your desk, and click **Scan Desk Signal (10s)** in **Range & Thresholds**.

## Instant iPhone Password Auto-Fill

When your Mac is connected to an external monitor and asks for a password:

1. **Open in Browser (Zero Tap)**: Open `http://192.168.1.8:8765/api/v1/faceid-autofill` (or `http://192.168.1.8:8765/faceid`) in Safari on your iPhone. Your Mac password auto-fills as soon as the page opens.
2. **Add to Home Screen**: In Safari, tap **Share > Add to Home Screen** to create a one-tap icon on your iPhone.
3. **Optional iOS POST Shortcut**: In the **Shortcuts** app, add **Get Contents of URL** with `http://192.168.1.8:8765/api/v1/faceid-autofill`, set Method to `POST`, and add it to your Home Screen.

## Keyboard Shortcuts on Mac

- `Control + Option + Command + Space`: Immediately fills your saved password into the active prompt.
- `Control + Option + Command + V`: Copies your password for 4 seconds and then clears the clipboard.

## Release Files

- `AuraSense.dmg` / `releases/v1.0/AuraSense-1.0.dmg`: macOS Disk Image installer.
- `AuraSense.app` / `releases/v1.0/AuraSense.app`: Native macOS application bundle.
- `releases/v1.0/AuraSense.app.zip`: Zipped macOS application bundle.

## Build from Source

```bash
cargo build --release
cd macos-host && ./Scripts/build_and_package.sh
```

## License

MIT License.
