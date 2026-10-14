# AuraSense 0.1 Release Notes

## Summary

AuraSense 0.1 is the initial release of the Rust-based Bluetooth Low Energy (BLE) proximity locking and Accessibility auto-unlocking system for macOS. It monitors the RSSI signal strength of a paired Bluetooth device to automatically unlock your Mac when the device enters range and lock the screen when the device leaves range.

## Key Capabilities in 0.1

- **Rust Proximity Engine (`aurasense-rs`)**: Implements a 1D Kalman and Exponential Moving Average (EMA) RSSI filter, dual-threshold hysteresis deadband, departure grace countdown, and Apple Continuity (`0x004C` type `0x10`) packet inspection.
- **Menu-Bar-Only Operation**: Displays a persistent status icon in the macOS menu bar and automatically hides the Dock icon (`NSApplication.ActivationPolicy.accessory`) whenever the main configuration window is closed.
- **10-Second Desk Signal Calibration**: Samples BLE RSSI on your desk for 10 seconds to record the baseline signal strength and standard deviation, automatically calculating optimal unlock and lock thresholds, smoothing factor, and grace period.
- **External Monitor Display Input Wake**: Detects connected external monitors via CoreGraphics (`CGGetActiveDisplayList`) and triggers `IOPMAssertionDeclareUserActivity`, `IODisplayWrangler`, `caffeinate`, and an external display coordinate cursor wake pulse before entering credentials.
- **iCloud Keychain and System Prompt Auto-Fill**:
  - Prioritizes the local HTTP `POST /api/v1/faceid-autofill` endpoint for iOS Home Screen Shortcuts.
  - Serves an unlocked mobile web trigger page at `http://<mac-ip>:8765/faceid`.
  - Provides global on-demand keyboard shortcuts (`Control+Option+Command+Space` to type the stored password and `Control+Option+Command+V` to copy the password to a concealed clipboard that automatically clears after 4 seconds).
  - Includes a one-click macOS `login.keychain-db` timeout optimizer.

## Release Assets

- `AuraSense.dmg` / `releases/v0.1/AuraSense-0.1.dmg`: Custom-styled macOS Disk Image installer containing `AuraSense.app`, `Install AuraSense.app`, and the `Applications` symlink.
