on run argv
    set volName to item 1 of argv
    tell application "Finder"
        tell disk volName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 160, 860, 628}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 96
            set text size of viewOptions to 13
            set background picture of viewOptions to file ".background:dmg_background.png"
            set position of item "AuraSense.app" of container window to {175, 220}
            set position of item "Applications" of container window to {485, 220}
            if exists item "Install AuraSense.app" of container window then
                set position of item "Install AuraSense.app" of container window to {330, 345}
            end if
            close
            open
            update without registering applications
            delay 1
            close
        end tell
    end tell
end run
