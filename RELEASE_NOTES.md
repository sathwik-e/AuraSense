# AuraSense v1.3 Release Notes

## No more lock-outs while you are working

- **Doesn't lock while you're using the Mac.** Auto-lock now waits until the keyboard, mouse and trackpad have been idle for 20 seconds. A phone on the bed, in a pocket or behind your body can read 20–30 dB weaker than on the desk; if you are typing, you are there. Turn it off in **Range & Locking** if you want signal-only locking.
- **Longer, safer timings.** Grace period 8 s → 15 s, signal-loss timeout 15 s → 30 s, and at least 14 dB between the unlock and lock thresholds. Existing installs are moved up to these values once.
- Desk calibration and presets use the wider gap and longer grace periods.
- **Only one AuraSense runs at a time.** Opening AuraSense just as it starts at login could leave two copies running, both locking and unlocking the Mac. The login copy now always takes over and the other closes.

## New

- **Two new unlock animations.** Pick one on the **Sound** page: **Aperture**, a camera iris that spins open to reveal your desktop, or **Stardust**, where light spirals into a ring and bursts into sparks. **Eclipse** is still there. Hover a tile to watch it; click to use it and see it full screen.
- **Desk calibration is required on first launch.** Setup won't finish until the 10-second desk scan has run, because it sets the lock and unlock levels for your room.
- **"Did you change your password?"** If macOS rejects the saved password, AuraSense asks once you're back at your Mac. **Yes** opens the Password page so you can save the new one.
- **Automatic updates.** AuraSense checks GitHub Releases once a day and offers to install new versions. Use **Check for Updates…** in the menu bar panel or the AuraSense menu; turn it off under Settings › Updates.

## Cleaner interface

- New **Overview** page: status, your device, one signal meter, Lock Now and Pause. The animated radar, simulator and signal chart are gone.
- Sidebar pages: Overview, Device, Range & Locking, Password, Sound, Activity.
- **iPhone Auto-Fill** moved to Settings (⌘,).
- Smaller menu bar panel: status, device, Lock Now / Pause, Open, Quit.
- Plainer status text ("Nearby · Unlocked", "Locking in 12s", "Away · Locked").

## Installer

- Light, minimal disk-image window: one arrow, one caption, and hidden support files stay hidden.
