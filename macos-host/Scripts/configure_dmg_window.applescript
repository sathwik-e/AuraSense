-- Lays out the mounted AuraSense disk image window: icon view, background artwork, and the
-- app icon on the left pedestal with the Applications shortcut on the right.
-- Usage: osascript configure_dmg_window.applescript <volume name> <background file name>
on run argv
    set volName to item 1 of argv
    set backgroundName to "background.tiff"
    if (count of argv) > 1 then set backgroundName to item 2 of argv

    tell application "Finder"
        tell disk volName
            open
            delay 1
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            -- 660 x 440 artwork plus the 28 pt title bar.
            set the bounds of container window to {200, 160, 860, 628}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 96
            set text size of viewOptions to 13
            set background picture of viewOptions to file (".background:" & backgroundName)
            set position of item "AuraSense.app" of container window to {175, 220}
            set position of item "Applications" of container window to {485, 220}
            update without registering applications
            delay 2
            close
        end tell
    end tell
end run
