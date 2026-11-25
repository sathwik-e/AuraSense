-- Lays out the mounted AuraSense disk image window: icon view, light background artwork,
-- the app on the left and the Applications shortcut on the right. Hidden support files are
-- also parked outside the visible area, so they stay out of sight even when Finder is set
-- to show hidden files.
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
            try
                set sidebar width of container window to 0
            end try
            -- 660 x 400 artwork plus the 28 pt title bar.
            set the bounds of container window to {200, 160, 860, 588}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 112
            set text size of viewOptions to 13
            set shows item info of viewOptions to false
            set shows icon preview of viewOptions to false
            set background picture of viewOptions to file (".background:" & backgroundName)
            set position of item "AuraSense.app" of container window to {170, 190}
            set position of item "Applications" of container window to {490, 190}
            repeat with hiddenName in {".background", ".fseventsd", ".VolumeIcon.icns", ".DS_Store", ".Trashes"}
                try
                    set position of item (hiddenName as text) of container window to {900, 900}
                end try
            end repeat
            update without registering applications
            delay 2
            close
            open
            delay 1
            close
        end tell
    end tell
end run
