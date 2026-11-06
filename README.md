# AuraSense v1.1

AuraSense is a Bluetooth Low Energy (BLE) proximity lock, external monitor wake, and instant Keychain password auto-fill app for macOS. It lives in your macOS menu bar with an Eclipse + Proximity Orbit icon and hides from the Dock whenever you close its window.

## Quick Setup (Guided in App)

1. **Install**: Open `AuraSense.dmg` and either drag `AuraSense.app` into `Applications`, or open `Install AuraSense.app`. The installer only copies `AuraSense.app` into `/Applications`, opens it, and quits. If it can't copy the app, it shows **Show in Finder** so you can drag the app over yourself.
2. **Guided Setup**: `/Applications/AuraSense.app` opens the 4-step Guided Setup. Setup always runs inside the installed app, so your device, calibration, permissions and Keychain item all belong to it.
3. **Grant Permissions**: In **Step 2**, click **Prompt Permission** to grant **Accessibility** and **Bluetooth**.
4. **Select Device & Calibrate**: In **Step 3**, select your iPhone or Apple Watch, place it on your desk, and click **Start 10s Desk Signal Scan**.
5. **Save Password & Auto-Fill**: In **Step 4**, save your Mac login password to the local Keychain. If the Keychain write fails, Setup shows the error instead of reporting success.

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

- `releases/v1/AuraSense.dmg`: macOS disk image (AuraSense.app, Install AuraSense.app, Applications shortcut).
- `releases/v1/AuraSense.app.zip`: zipped macOS application bundle.

Pushing a `v*` tag (for example `v1.1`) builds the app from source on macOS and publishes these files as a GitHub Release. The tag must match `CFBundleShortVersionString` in `macos-host/Resources/Info.plist`.

## Build from Source

```bash
cd macos-host && ./Scripts/build_and_package.sh
```

The build signs ad-hoc by default. An ad-hoc signature changes the app's code identity on every build, so after installing a new build macOS may ask you to grant Accessibility again and to allow Keychain access. To keep a stable identity, sign with a Developer ID or a persistent self-signed certificate:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/build_and_package.sh
```

## License

MIT License.
