# AuraSense v1.2

AuraSense is a Bluetooth Low Energy (BLE) proximity lock, external monitor wake, and instant Keychain password auto-fill app for macOS. It lives in your macOS menu bar and hides from the Dock whenever you close its window.

## Install

1. Open `AuraSense.dmg`.
2. Drag **AuraSense** onto **Applications**.
3. Open AuraSense from Applications. Guided Setup starts on first launch.

AuraSense is not notarized. If macOS says it cannot verify the app the first time you open it, go to **System Settings › Privacy & Security** and choose **Open Anyway**.

If you open AuraSense straight from the disk image (or from Downloads), the first Setup step offers **Install in Applications**. It copies the app, then reopens it from Applications so your permissions, login item and Keychain item all belong to the installed copy.

## Guided Setup

1. **Install**: only shown when AuraSense is not running from Applications.
2. **Permissions**: grant **Accessibility** and **Bluetooth**. System Settings opens only when you press the button, and the step updates by itself once macOS reports the permission.
3. **Device**: select your iPhone or Apple Watch, leave it on your desk, and run the 10-second signal scan.
4. **Password**: save your Mac login password to the local Keychain. If the Keychain write fails, Setup shows the error instead of reporting success. Optionally scan the QR code with your iPhone to set up password fill from the phone.

Setup takes over the window only until you have finished it once. After that, anything missing (for example Accessibility after an update) appears as a banner at the top of the dashboard, and **Open Setup** takes you to the step that needs attention.

## Trusted Device Protection

Changing or removing the trusted (bound) Bluetooth device requires your **Mac password**, entered in AuraSense's password panel and checked by macOS. AuraSense's own auto-fill can never fill that panel, the hotkeys and the iPhone bridge included. Anyone who sits down at your unlocked Mac therefore can't swap in their own phone.

## Keeps Running After Quit

- **Quit** hides AuraSense, and proximity protection keeps running from the menu bar.
- A per-user LaunchAgent (`KeepAlive`) relaunches AuraSense quietly into the menu bar after login, a force quit or a crash.
- To fully stop AuraSense, choose **Stop AuraSense Completely…** in the menu bar popover or the **Aura Protection** menu. Stopping it, and turning off background protection, both require your Mac password.

## Unlock Sound & Animation

- In **Sound & Animation**, pick separate unlock and lock sounds from the built-in and system sounds, or import your own audio file. Imported sounds are stored in `~/Library/Application Support/AuraSense/Sounds`.
- An unlock animation plays after macOS confirms an AuraSense unlock. You can switch it off, and it follows **Reduce Motion** in System Settings › Accessibility › Display.

## Instant iPhone Password Auto-Fill

When your Mac is connected to an external monitor and asks for a password:

1. **Open the pairing URL**: Open AuraSense › **Instant Auto-Fill** (or Guided Setup Step 4) and copy the **tokenized URL shown in the app**. It contains your Mac's local address and a private pairing token (`…?t=<token>`). Open it in Safari on your iPhone. Requests without the right token are refused.
2. **Add to Home Screen**: In Safari, tap **Share > Add to Home Screen** for one-tap access.
3. **Optional iOS Shortcut**: In the **Shortcuts** app, add **Get Contents of URL** with the tokenized `/api/v1/faceid-autofill` URL shown in the app, set Method to `POST`, and add the shortcut to your Home Screen.

> **Upgrading from v1.0:** the old bookmark without a token no longer works. Re-add the Home Screen bookmark (and update any Shortcut) using the new tokenized URL shown in the app. Keep the URL private; anyone who has it can ask your Mac to fill its password prompt.

## Release Files

- `releases/v1/AuraSense.dmg`: compressed disk image (AuraSense.app and an Applications shortcut).
- `releases/v1/AuraSense.app.zip`: zipped application bundle.

Pushing a `v*` tag (for example `v1.2`) builds the app from source on macOS and publishes these files as a GitHub Release. The tag must match `CFBundleShortVersionString` in `macos-host/Resources/Info.plist`.

## Build from Source

Requires macOS 14 or later with the Xcode Command Line Tools (`xcode-select --install`).

```bash
cd macos-host && ./Scripts/build_and_package.sh
```

The script compiles the app, signs it, and builds `AuraSense.dmg` with `hdiutil`. The first run asks to let your terminal control Finder; allow it so the disk image window gets its background and icon layout. Without that permission the DMG still works, it just opens as a plain Finder window.

Options (environment variables):

- `SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"`: sign with a stable identity.
- `UNIVERSAL=1`: also build for Intel Macs (universal binary). The default is Apple Silicon only.
- `SKIP_DMG_LAYOUT=1`: skip the Finder layout step on headless machines.

The build signs ad-hoc by default. An ad-hoc signature changes the app's code identity on every build, so after installing a new build macOS may ask you to grant Accessibility again and to allow Keychain access. A Developer ID or a persistent self-signed certificate avoids that.

## Experimental Rust Daemon

`src/` holds a standalone Rust prototype of the fill bridge (`./build_rust.sh`, needs `cargo`). It is not part of AuraSense.app and has no Bluetooth scanning of its own. It uses the same pairing token and port as the app, so do not run both at once.

## License

MIT License.
