#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CRATE_DIR="$(cd "${PROJECT_ROOT}/.." && pwd)"
RUST_OUT_DIR="${CRATE_DIR}"
RELEASES_DIR="${CRATE_DIR}/releases/v1"
BUILD_DIR="${PROJECT_ROOT}/build"
STAGING_DIR="${BUILD_DIR}/dmg_staging"

echo "==> [1/6] Generating AuraSense v1 Neon Orbit Eclipse icons, Menu Bar template icons, and DMG artwork..."
cd "${PROJECT_ROOT}"
swiftc Scripts/generate_assets.swift -o /tmp/aurasense_asset_gen
/tmp/aurasense_asset_gen

echo "==> [2/6] Compiling AuraSense native macOS binary (Release -O)..."
mkdir -p "${BUILD_DIR}"
swiftc -parse-as-library -target arm64-apple-macos14.0 -O $(find Sources/AuraSense -name "*.swift") -o "${BUILD_DIR}/AuraSense"

echo "==> [3/6] Assembling AuraSense.app and Install AuraSense.app bundles..."
APP_BUNDLE="${BUILD_DIR}/AuraSense.app"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/AuraSense" "${APP_BUNDLE}/Contents/MacOS/AuraSense"
chmod +x "${APP_BUNDLE}/Contents/MacOS/AuraSense"
cp "${PROJECT_ROOT}/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "${PROJECT_ROOT}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
cp "${PROJECT_ROOT}/Resources/AppIcon.png" "${APP_BUNDLE}/Contents/Resources/AppIcon.png"
cp "${PROJECT_ROOT}/Resources/"AuraEclipse*Template*.png "${APP_BUNDLE}/Contents/Resources/"
printf "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

codesign --force --deep --sign - "${APP_BUNDLE}"

INSTALLER_BUNDLE="${BUILD_DIR}/Install AuraSense.app"
rm -rf "${INSTALLER_BUNDLE}"
mkdir -p "${INSTALLER_BUNDLE}/Contents/MacOS"
mkdir -p "${INSTALLER_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/AuraSense" "${INSTALLER_BUNDLE}/Contents/MacOS/AuraSense"
chmod +x "${INSTALLER_BUNDLE}/Contents/MacOS/AuraSense"
sed 's/<string>AuraSense<\/string>/<string>Install AuraSense<\/string>/g; s/com.aurasense.mac.app/com.aurasense.mac.installer/g' \
    "${PROJECT_ROOT}/Resources/Info.plist" > "${INSTALLER_BUNDLE}/Contents/Info.plist"
cp "${PROJECT_ROOT}/Resources/AppIcon.icns" "${INSTALLER_BUNDLE}/Contents/Resources/AppIcon.icns"
cp "${PROJECT_ROOT}/Resources/AppIcon.png" "${INSTALLER_BUNDLE}/Contents/Resources/AppIcon.png"
cp "${PROJECT_ROOT}/Resources/"AuraEclipse*Template*.png "${INSTALLER_BUNDLE}/Contents/Resources/"
printf "APPL????" > "${INSTALLER_BUNDLE}/Contents/PkgInfo"

codesign --force --deep --sign - "${INSTALLER_BUNDLE}"

rm -rf "${RUST_OUT_DIR}/AuraSense.app"
cp -R "${APP_BUNDLE}" "${RUST_OUT_DIR}/AuraSense.app"

echo "==> [4/6] Preparing DMG staging directory..."
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}/.background"

cp -R "${APP_BUNDLE}" "${STAGING_DIR}/AuraSense.app"
cp -R "${INSTALLER_BUNDLE}" "${STAGING_DIR}/Install AuraSense.app"
ln -s /Applications "${STAGING_DIR}/Applications"
cp "${PROJECT_ROOT}/Resources/dmg_background.png" "${STAGING_DIR}/.background/dmg_background.png"
cp "${PROJECT_ROOT}/Resources/dmg_background@2x.png" "${STAGING_DIR}/.background/dmg_background@2x.png"
cp "${PROJECT_ROOT}/Resources/AppIcon.icns" "${STAGING_DIR}/.VolumeIcon.icns"
SetFile -a C "${STAGING_DIR}" 2>/dev/null || true

echo "==> [5/6] Building AuraSense.dmg installer..."
DMG_PATH="${RUST_OUT_DIR}/AuraSense.dmg"
rm -f "${DMG_PATH}"
python3 "${PROJECT_ROOT}/Scripts/create_dmg_image.py" "${STAGING_DIR}" "${DMG_PATH}"

echo "==> [6/6] Syncing release bundles into releases/v1..."
rm -rf "${BUILD_DIR}"
rm -rf "${CRATE_DIR}/releases/v0.1" "${CRATE_DIR}/releases/v1.0"
mkdir -p "${RELEASES_DIR}"
rm -rf "${RELEASES_DIR}/AuraSense.app"
cp -R "${RUST_OUT_DIR}/AuraSense.app" "${RELEASES_DIR}/AuraSense.app"
cp -f "${DMG_PATH}" "${RELEASES_DIR}/AuraSense.dmg"
cp -f "${DMG_PATH}" "${RELEASES_DIR}/AuraSense-v1.dmg"
cd "${RELEASES_DIR}"
rm -f "${RELEASES_DIR}/AuraSense.app.zip"
zip -r -y -q "${RELEASES_DIR}/AuraSense.app.zip" "AuraSense.app"

echo "==> Build & packaging v1 complete!"
ls -lh "${RUST_OUT_DIR}/AuraSense.dmg" "${RELEASES_DIR}/AuraSense.dmg" "${RELEASES_DIR}/AuraSense-v1.dmg" "${RELEASES_DIR}/AuraSense.app.zip"
