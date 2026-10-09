#!/usr/bin/env bash
set -euo pipefail

if [ -d "/Library/Developer/CommandLineTools" ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_PATH="${BUILD_DIR}/AuraSense.app"
DMG_PATH="${BUILD_DIR}/AuraSense.dmg"
TEMP_DMG="${BUILD_DIR}/AuraSense-rw.dmg"
STAGING_DIR="${BUILD_DIR}/dmg_staging"
STAGING_VOLUME="AuraSense Staging $$"
OUTPUT_DMG="${BUILD_DIR}/AuraSense-output-$$.dmg"
MOUNT_DIR=""
DEVICE_PATH=""

echo "==> Building AuraSense.app..."
"${SCRIPT_DIR}/build_app.sh"

echo "==> Signing app bundle (ad-hoc; not for distribution)..."
codesign --force --deep --sign - "${APP_PATH}"

echo "==> Creating branded installer background..."
mkdir -p "${STAGING_DIR}/.background"
swift "${SCRIPT_DIR}/create_dmg_background.swift" "${STAGING_DIR}/.background/AuraSenseBackground.png"
cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

cleanup() {
    if [ -n "${DEVICE_PATH}" ] && diskutil info "${DEVICE_PATH}" >/dev/null 2>&1; then
        hdiutil detach "${DEVICE_PATH}" -quiet || true
    fi
    rm -rf "${STAGING_DIR}"
    if [ -n "${MOUNT_DIR}" ]; then rm -rf "${MOUNT_DIR}"; fi
    rm -f "${TEMP_DMG}" "${OUTPUT_DMG}"
}
trap cleanup EXIT

rm -f "${DMG_PATH}" "${TEMP_DMG}"
echo "==> Creating writable image for Finder layout..."
hdiutil create -size 180m -fs HFS+ -volname "${STAGING_VOLUME}" -format UDRW -srcfolder "${STAGING_DIR}" "${TEMP_DMG}"
ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "${TEMP_DMG}")"
IFS=$'\t' read -r DEVICE_PATH MOUNT_DIR < <(printf '%s\n' "${ATTACH_OUTPUT}" | awk -F '\t' '$3 ~ /^\/Volumes\// { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); print $1 "\t" $3; exit }')
if [ -z "${DEVICE_PATH}" ] || [ -z "${MOUNT_DIR}" ]; then
    echo "Error: could not identify the mounted staging volume."
    exit 1
fi
ACTUAL_VOLUME_NAME="$(diskutil info -plist "${MOUNT_DIR}" | plutil -extract VolumeName raw -o - -)"

echo "==> Applying AuraSense Finder layout..."
osascript <<APPLESCRIPT &
tell application "Finder"
    tell disk "${ACTUAL_VOLUME_NAME}"
        open
        set containerWindow to container window
        set current view of containerWindow to icon view
        set toolbar visible of containerWindow to false
        set statusbar visible of containerWindow to false
        set bounds of containerWindow to {120, 100, 840, 600}
        set iconOptions to icon view options of containerWindow
        set arrangement of iconOptions to not arranged
        set icon size of iconOptions to 96
        set text size of iconOptions to 12
        set background picture of iconOptions to (POSIX file "${MOUNT_DIR}/.background/AuraSenseBackground.png")
        set position of item "AuraSense.app" of containerWindow to {190, 270}
        set position of item "Applications" of containerWindow to {530, 270}
        update without registering applications
        delay 1
        close containerWindow
        open
        delay 1
    end tell
end tell
APPLESCRIPT
FINDER_PID=$!
for _ in {1..15}; do
    if ! kill -0 "${FINDER_PID}" 2>/dev/null; then
        break
    fi
    sleep 1
done
if kill -0 "${FINDER_PID}" 2>/dev/null; then
    kill "${FINDER_PID}" 2>/dev/null || true
    wait "${FINDER_PID}" 2>/dev/null || true
    echo "Warning: Finder layout timed out; image remains usable with the branded background included."
elif ! wait "${FINDER_PID}"; then
    echo "Warning: Finder layout could not be saved; image remains usable with the branded background included."
fi

echo "==> Compressing branded DMG..."
diskutil rename "${MOUNT_DIR}" AuraSense
hdiutil detach "${DEVICE_PATH}" -quiet
DEVICE_PATH=""
hdiutil convert "${TEMP_DMG}" -format UDZO -imagekey zlib-level=9 -o "${OUTPUT_DMG}"
mv -f "${OUTPUT_DMG}" "${DMG_PATH}"
rm -rf "${STAGING_DIR}"
rm -f "${TEMP_DMG}"
trap - EXIT
echo "==> Created ${DMG_PATH}"
ls -lh "${DMG_PATH}"
