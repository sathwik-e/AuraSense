# AuraSense v1 Release Notes

## What's Fixed & Included in v1

- **Fixed `/Applications` Installation**: Fixed HFS+ catalog B-tree FastUnicodeCompare key ordering (`_CodeSignature` sorting after `Info.plist` and `MacOS`) and `.app` bundle bit (`0x2000`) inside `AuraSense.dmg`, and added automatic `/usr/bin/ditto` installation into `/Applications/AuraSense.app` whenever `Install AuraSense.app` or `AuraSense.app` is opened from the DMG.
- **4-Step Guided Setup & Permission Re-Prompting**: Launches the interactive 4-step Guided Setup Wizard on startup whenever setup or permissions are incomplete, clears stale TCC CDHash entries (`tccutil reset Accessibility com.aurasense.mac.app`) so macOS prompts again for Accessibility permission, and prompts for Bluetooth scanning permission.
- **Neon Orbit Eclipse Identity & Menu Bar Icon**: Features the Neon Orbit Eclipse app icon, `Λ U R Λ S E N S E` geometric typography, and the custom Eclipse + Proximity Orbit menu bar template icon.
- **Instant Auto-Fill on Browser Open**: Opening `http://<mac-ip>:8765/api/v1/faceid-autofill` or `http://<mac-ip>:8765/faceid` immediately wakes connected displays and fills the active macOS password prompt on page load.

## Release Assets

- `releases/v1/AuraSense.dmg`
- `releases/v1/AuraSense-v1.dmg`
- `releases/v1/AuraSense.app`
- `releases/v1/AuraSense.app.zip`
