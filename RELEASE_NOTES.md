# AuraSense v1.1 Release Notes

## New in v1.1

- **Mac-password-protected trusted device**: Replacing or unbinding the trusted Bluetooth device requires your Mac password, checked by macOS. AuraSense's auto-fill (hotkeys, menu bar Fill Password, iPhone bridge, auto-unlock) can never fill this panel.
- **Keeps running after Quit**: Quit hides AuraSense, and protection keeps running from the menu bar. A LaunchAgent relaunches it quietly after login, a force quit or a crash. **Stop AuraSense Completely…** (password-protected) fully quits it, and turning off background protection also requires the password.
- **Selectable and custom unlock & lock sounds**: Choose separate unlock and lock sounds, or import your own. Custom sounds are stored in `~/Library/Application Support/AuraSense/Sounds`.
- **Unlock animation**: Plays only after macOS confirms the unlock. It can be switched off and follows Reduce Motion.
- **iPhone bridge pairing token**: The iPhone auto-fill URL now carries a private pairing token, and requests without it are refused. **Re-add your Home Screen bookmark** (and update any Shortcut) using the tokenized URL shown in the app.
- **Installer hand-off**: `Install AuraSense.app` now only installs. It copies AuraSense.app into `/Applications`, opens it with Guided Setup, and quits, so all settings, permissions and the Keychain item belong to the real app. If the copy fails, it offers a Show in Finder / drag-to-Applications fallback.

## Security & Reliability Fixes

- Auto-unlock reports success only after macOS confirms the screen unlocked, and backs off instead of retyping a wrong password. The success chime and animation play only on a real unlock.
- Password typing goes through one guarded path: it refuses to type while a protected prompt is open or AuraSense itself is focused, fills only genuine macOS system password prompts (never web pages or other apps, whose scripts could read the password), ignores held modifier keys, and won't run twice at once.
- **Removed the "4s Copy" clipboard assist (⌃⌥⌘V).** Putting the Mac password on the clipboard let anyone at the Mac paste and read it, which would defeat the password protection on trusted-device changes.
- The trusted-device binding is also kept in a Keychain record; if the setting is changed outside AuraSense (e.g. with `defaults`), AuraSense restores it.
- The iPhone relay requires the pairing token, and Continuity wake only reacts to the bound device. An unknown or stale device no longer counts as "in range".
- Signal-loss lock, the auto-lock toggle, "Lock Mac Immediately", scheduled pauses and desk calibration all behave as described. Calibration no longer silently binds an arbitrary device.
- Simulated devices and Sim Mode are debug-only and never ship in release builds.
- The stored password is never pre-filled into revealable fields. Checking whether a password exists no longer decrypts it.
- Guided Setup shows Keychain save errors instead of reporting "Saved".
- Installing into `/Applications` happens only when you ask for it and runs off the main thread. AuraSense no longer reinstalls and re-signs itself at every launch, and Accessibility re-prompts no longer reset the permission you are granting.
- The Instant-Fill hotkey (⌃⌥⌘Space) fires once per press, and "Open Dashboard" reuses the existing window.
- Build: bundles are signed with an explicit identifier and `AuraSense.entitlements` (inner binary, then bundle). An optional `SIGN_IDENTITY` gives a stable code identity. The DMG builder now fails loudly instead of writing a corrupt image when the catalog or bitmap overflows.
- Releases are built from source on macOS for `v*` tags, and the tag must match the app version.

## Release Assets

- `releases/v1/AuraSense.dmg`
- `releases/v1/AuraSense.app.zip`
