#!/usr/bin/env bash
set -euo pipefail

if [ -d "/Library/Developer/CommandLineTools" ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Ensuring AuraSense.app is built..."
"${SCRIPT_DIR}/build_app.sh"

APP_PATH="${ROOT_DIR}/build/AuraSense.app"
DMG_PATH="${ROOT_DIR}/build/AuraSense.dmg"
STAGING_DIR="${ROOT_DIR}/build/dmg_staging"

echo "==> Signing application bundle (ad-hoc)..."
codesign --force --deep --sign - "${APP_PATH}"

echo "==> Preparing DMG staging area..."
rm -rf "${STAGING_DIR}" "${DMG_PATH}"
mkdir -p "${STAGING_DIR}"
cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "==> Creating DMG image at ${DMG_PATH}..."
hdiutil create \
    -volname "AuraSense" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

rm -rf "${STAGING_DIR}"

echo "==> AuraSense.dmg created successfully at ${DMG_PATH}!"
ls -lh "${DMG_PATH}"
