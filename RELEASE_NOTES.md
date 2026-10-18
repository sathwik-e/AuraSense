# AuraSense v1.0 Release Notes

## What's New in v1.0

- **Neon Orbit Eclipse Identity and Typography**: Updated app icon, DMG installer window, dashboard, and mobile web trigger with the Neon Orbit Eclipse emblem and `Λ U R Λ S E N S E` geometric typography.
- **Eclipse + Proximity Orbit Menu Bar Icon**: Custom macOS template menu bar icon combining an inner solar/lunar eclipse crescent with an outer BLE proximity orbit ring and signal node that adapts to in-range, grace countdown, calibrating, and locked states.
- **Instant Auto-Fill on Browser Open**: Opening `http://<mac-ip>:8765/api/v1/faceid-autofill` or `http://<mac-ip>:8765/faceid` immediately wakes connected displays and fills the active macOS password prompt on page load.
- **10-Second Desk Signal Calibration**: Samples resting BLE RSSI on your desk for 10 seconds and automatically configures unlock and lock thresholds.
- **External Monitor Display Wake**: Sends active DisplayPort, HDMI, and USB-C wake signals before entering credentials.

## Quick Setup

1. Open `AuraSense.dmg` and drag `AuraSense.app` to `Applications`.
2. Grant **Accessibility** and **Bluetooth** permissions when prompted.
3. Save your Mac password in **Security & Keychain** and run the **10s Desk Signal Scan**.
4. On your iPhone, open `http://192.168.1.8:8765/api/v1/faceid-autofill` in Safari and tap **Share > Add to Home Screen** for one-tap password auto-fill.

## Release Assets

- `releases/v1.0/AuraSense.dmg`
- `releases/v1.0/AuraSense-1.0.dmg`
- `releases/v1.0/AuraSense.app`
- `releases/v1.0/AuraSense.app.zip`
