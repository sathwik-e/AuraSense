#!/usr/bin/env bash
set -euo pipefail

if [ -d "/Library/Developer/CommandLineTools" ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
fi

# Build the Swift package in release mode
echo "==> Building AuraSense in release mode..."
swift build -c release

BIN_PATH=$(swift build -c release --show-bin-path)/AuraSense
APP_DIR="build/AuraSense.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Creating macOS Application Bundle at ${APP_DIR}..."
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/AuraSense"

# Generate AppIcon.icns from root Icon.png if iconutil and sips are available
if [ -f "Icon.png" ] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    echo "==> Generating AppIcon.icns from Icon.png..."
    ICONSET_DIR="build/AuraSense.iconset"
    rm -rf "${ICONSET_DIR}"
    mkdir -p "${ICONSET_DIR}"
    sips -z 16 16     Icon.png --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null 2>&1 || true
    sips -z 32 32     Icon.png --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null 2>&1 || true
    sips -z 32 32     Icon.png --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null 2>&1 || true
    sips -z 64 64     Icon.png --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null 2>&1 || true
    sips -z 128 128   Icon.png --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null 2>&1 || true
    sips -z 256 256   Icon.png --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null 2>&1 || true
    sips -z 256 256   Icon.png --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null 2>&1 || true
    sips -z 512 512   Icon.png --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null 2>&1 || true
    sips -z 512 512   Icon.png --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null 2>&1 || true
    sips -z 1024 1024 Icon.png --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null 2>&1 || true
    iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns" 2>/dev/null || true
    rm -rf "${ICONSET_DIR}"
    cp "Icon.png" "${RESOURCES_DIR}/Icon.png"
fi

cat << 'EOF' > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AuraSense</string>
    <key>CFBundleIdentifier</key>
    <string>com.aurasense.AuraSense</string>
    <key>CFBundleName</key>
    <string>AuraSense</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>AuraSense requires Bluetooth access to discover companion proximity devices and monitor RSSI.</string>
</dict>
</plist>
EOF

echo "==> AuraSense.app bundle created successfully."
