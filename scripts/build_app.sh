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
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>AuraSense requires Bluetooth access to discover companion proximity devices and monitor RSSI.</string>
</dict>
</plist>
EOF

echo "==> AuraSense.app bundle created successfully."
