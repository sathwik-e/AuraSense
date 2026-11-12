#!/bin/bash
# Builds AuraSense.app and a drag-to-Applications AuraSense.dmg.
#
#   ./Scripts/build_and_package.sh
#
# Optional environment:
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   stable code identity (default: ad-hoc "-")
#   UNIVERSAL=1                                                also build x86_64 and lipo a universal binary
#   SKIP_DMG_LAYOUT=1                                          skip the Finder window layout (headless builds)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CRATE_DIR="$(cd "${PROJECT_ROOT}/.." && pwd)"
RELEASES_DIR="${CRATE_DIR}/releases/v1"
BUILD_DIR="${PROJECT_ROOT}/build"
STAGING_DIR="${BUILD_DIR}/dmg_staging"
RESOURCES_DIR="${PROJECT_ROOT}/Resources"
ENTITLEMENTS="${RESOURCES_DIR}/AuraSense.entitlements"
INFO_PLIST="${RESOURCES_DIR}/Info.plist"
VOLUME_NAME="AuraSense"
MIN_MACOS="14.0"

# Code-signing identity. Defaults to ad-hoc ("-").
# NOTE: an ad-hoc signature's designated requirement is its cdhash, so EVERY rebuild gets a new
# code identity: macOS drops the Accessibility (TCC) grant and the Keychain item's ACL no longer
# matches, so users must re-grant Accessibility and may see a Keychain access prompt after updating.
# For stable identity across builds set SIGN_IDENTITY to a Developer ID or a persistent
# self-signed certificate name, e.g.  SIGN_IDENTITY="Developer ID Application: Name (TEAMID)".
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
UNIVERSAL="${UNIVERSAL:-0}"
SKIP_DMG_LAYOUT="${SKIP_DMG_LAYOUT:-0}"

MOUNT_POINT=""
ASSET_GEN=""

cleanup() {
    if [[ -n "${MOUNT_POINT}" && -d "${MOUNT_POINT}" ]]; then
        hdiutil detach "${MOUNT_POINT}" -force -quiet >/dev/null 2>&1 || true
    fi
    if [[ -n "${ASSET_GEN}" ]]; then
        rm -f "${ASSET_GEN}"
    fi
}
trap cleanup EXIT

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: '$1' was not found. $2" >&2
        exit 1
    fi
}

# Runs a command, killing it if it has not finished after N seconds (macOS has no `timeout`).
run_with_timeout() {
    local seconds="$1"
    shift
    "$@" &
    local pid=$!
    # Detached from stdout/stderr so a leftover sleep never holds a pipe open (CI log capture).
    ( sleep "${seconds}"; kill "${pid}" 2>/dev/null ) >/dev/null 2>&1 &
    local watchdog=$!
    local rc=0
    wait "${pid}" || rc=$?
    kill "${watchdog}" 2>/dev/null || true
    wait "${watchdog}" 2>/dev/null || true
    return "${rc}"
}

# Signs the inner executable, then the bundle (no --deep), with an explicit identifier and the
# app entitlements. Hardened runtime is enabled only for real (non ad-hoc) identities.
sign_bundle() {
    local bundle="$1"
    local identifier="$2"
    local -a opts=(--force --sign "${SIGN_IDENTITY}" --identifier "${identifier}" --entitlements "${ENTITLEMENTS}" --timestamp=none)
    if [[ "${SIGN_IDENTITY}" != "-" ]]; then
        opts=(--force --sign "${SIGN_IDENTITY}" --identifier "${identifier}" --entitlements "${ENTITLEMENTS}" --options runtime --timestamp)
    fi
    codesign "${opts[@]}" "${bundle}/Contents/MacOS/AuraSense"
    codesign "${opts[@]}" "${bundle}"
}

compile_arch() {
    local arch="$1"
    local output="$2"
    swiftc -parse-as-library -target "${arch}-apple-macos${MIN_MACOS}" -O "${SOURCES[@]}" -o "${output}"
}

# Copies the DMG contents into the staging folder: the app, an /Applications shortcut,
# the hidden window background and the volume icon.
stage_dmg_contents() {
    rm -rf "${STAGING_DIR}"
    mkdir -p "${STAGING_DIR}/.background"
    cp -R "${APP_BUNDLE}" "${STAGING_DIR}/AuraSense.app"
    ln -s /Applications "${STAGING_DIR}/Applications"
    cp "${RESOURCES_DIR}/AppIcon.icns" "${STAGING_DIR}/.VolumeIcon.icns"
}

# Standard compressed disk image built by hdiutil, with the Finder window laid out by AppleScript.
# Returns non-zero (without exiting) if the image could not be produced.
build_dmg_with_hdiutil() {
    local dmg_out="$1"
    local rw_dmg="${BUILD_DIR}/AuraSense-rw.dmg"
    local background_name="background.png"

    stage_dmg_contents || return 1
    # One multi-resolution TIFF so the background is sharp on Retina displays.
    if command -v tiffutil >/dev/null 2>&1 && tiffutil -cathidpicheck \
        "${RESOURCES_DIR}/dmg_background.png" "${RESOURCES_DIR}/dmg_background@2x.png" \
        -out "${STAGING_DIR}/.background/background.tiff" >/dev/null 2>&1; then
        background_name="background.tiff"
    else
        cp "${RESOURCES_DIR}/dmg_background.png" "${STAGING_DIR}/.background/background.png" || return 1
    fi

    local staged_mb
    staged_mb="$(du -sm "${STAGING_DIR}" | awk '{print $1}')"
    local image_mb=$(( staged_mb + 24 ))

    rm -f "${rw_dmg}"
    hdiutil create -quiet -ov -volname "${VOLUME_NAME}" -srcfolder "${STAGING_DIR}" \
        -fs HFS+ -format UDRW -size "${image_mb}m" "${rw_dmg}" || return 1

    # A volume with the same name that is still mounted would make Finder address the wrong disk.
    if [[ -d "/Volumes/${VOLUME_NAME}" ]]; then
        hdiutil detach "/Volumes/${VOLUME_NAME}" -quiet >/dev/null 2>&1 || true
    fi

    local attach_output
    # Newer macOS deprecates `hdiutil attach` in favour of `diskutil image attach`; both print
    # tab-separated lines ending in the mount point. Older systems (and CI) only have hdiutil.
    if diskutil image attach --help >/dev/null 2>&1; then
        attach_output="$(diskutil image attach "${rw_dmg}")" || return 1
    else
        attach_output="$(hdiutil attach "${rw_dmg}" -readwrite -noverify -noautoopen)" || return 1
    fi
    MOUNT_POINT="$(printf '%s\n' "${attach_output}" | awk -F '\t' '/\/Volumes\// {print $NF; exit}')"
    if [[ -z "${MOUNT_POINT}" || ! -d "${MOUNT_POINT}" ]]; then
        echo "warning: could not find the mounted volume." >&2
        return 1
    fi

    if [[ "${SKIP_DMG_LAYOUT}" == "1" ]]; then
        echo "    Skipping Finder window layout (SKIP_DMG_LAYOUT=1)."
    elif [[ "${MOUNT_POINT}" != "/Volumes/${VOLUME_NAME}" ]]; then
        echo "warning: another '${VOLUME_NAME}' volume is mounted; eject it and rebuild to get the styled window." >&2
    else
        # The first run asks to let your terminal control Finder; allow it once.
        if run_with_timeout 90 osascript "${SCRIPT_DIR}/configure_dmg_window.applescript" "${VOLUME_NAME}" "${background_name}"; then
            # Give Finder a moment to write the window layout (.DS_Store) to the volume.
            local waited=0
            while [[ ! -f "${MOUNT_POINT}/.DS_Store" && "${waited}" -lt 20 ]]; do
                sleep 0.5
                waited=$(( waited + 1 ))
            done
        else
            echo "warning: Finder layout was skipped (no Automation permission or no GUI session). The DMG still works." >&2
        fi
    fi

    # Finder can discard .VolumeIcon.icns while laying out the window (the volume is not yet
    # flagged as having a custom icon), so put it back before setting that flag.
    if [[ ! -f "${MOUNT_POINT}/.VolumeIcon.icns" ]]; then
        cp "${RESOURCES_DIR}/AppIcon.icns" "${MOUNT_POINT}/.VolumeIcon.icns" || true
    fi
    if command -v SetFile >/dev/null 2>&1; then
        SetFile -a C "${MOUNT_POINT}" 2>/dev/null || true
    fi
    chmod -Rf go-w "${MOUNT_POINT}" 2>/dev/null || true
    sync

    local detached=0
    local _attempt
    for _attempt in 1 2 3 4 5; do
        if hdiutil detach "${MOUNT_POINT}" -quiet >/dev/null 2>&1; then
            detached=1
            break
        fi
        sleep 2
    done
    if [[ "${detached}" != "1" ]]; then
        hdiutil detach "${MOUNT_POINT}" -force -quiet >/dev/null 2>&1 || return 1
    fi
    MOUNT_POINT=""

    rm -f "${dmg_out}"
    hdiutil convert "${rw_dmg}" -quiet -format UDZO -imagekey zlib-level=9 -o "${dmg_out}" || return 1
    rm -f "${rw_dmg}"
    hdiutil verify -quiet "${dmg_out}" || return 1

    if [[ "${SIGN_IDENTITY}" != "-" ]]; then
        codesign --force --sign "${SIGN_IDENTITY}" --timestamp "${dmg_out}" || return 1
    fi
    return 0
}

# Fallback only: the hand-written HFS+ image writer used before v1.2. It produces a raw,
# uncompressed image, so it is used only when hdiutil cannot build one.
build_dmg_legacy() {
    local dmg_out="$1"
    stage_dmg_contents
    cp "${RESOURCES_DIR}/dmg_background.png" "${STAGING_DIR}/.background/dmg_background.png"
    cp "${RESOURCES_DIR}/dmg_background@2x.png" "${STAGING_DIR}/.background/dmg_background@2x.png"
    rm -f "${dmg_out}"
    python3 "${SCRIPT_DIR}/create_dmg_image.py" "${STAGING_DIR}" "${dmg_out}"
}

require_tool swiftc "Install the Xcode Command Line Tools with: xcode-select --install"
require_tool codesign "Install the Xcode Command Line Tools with: xcode-select --install"
require_tool hdiutil "This script must run on macOS."

if [[ ! -f "${ENTITLEMENTS}" ]]; then
    echo "error: missing entitlements file ${ENTITLEMENTS}" >&2
    exit 1
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")"
echo "==> Building AuraSense ${APP_VERSION} (build ${APP_BUILD})"

cd "${PROJECT_ROOT}"
mkdir -p "${BUILD_DIR}"

echo "==> [1/6] Generating app icon, menu bar icons and DMG artwork..."
ASSET_GEN="$(mktemp "${TMPDIR:-/tmp}/aurasense_asset_gen.XXXXXX")"
swiftc Scripts/generate_assets.swift -o "${ASSET_GEN}"
"${ASSET_GEN}"

echo "==> [2/6] Compiling AuraSense (Release -O)..."
SOURCES=()
while IFS= read -r source_file; do
    SOURCES+=("${source_file}")
done < <(find Sources/AuraSense -name "*.swift" | sort)
if [[ "${#SOURCES[@]}" -eq 0 ]]; then
    echo "error: no Swift sources found under Sources/AuraSense" >&2
    exit 1
fi

if [[ "${UNIVERSAL}" == "1" ]]; then
    compile_arch arm64 "${BUILD_DIR}/AuraSense-arm64"
    compile_arch x86_64 "${BUILD_DIR}/AuraSense-x86_64"
    lipo -create "${BUILD_DIR}/AuraSense-arm64" "${BUILD_DIR}/AuraSense-x86_64" -output "${BUILD_DIR}/AuraSense"
    rm -f "${BUILD_DIR}/AuraSense-arm64" "${BUILD_DIR}/AuraSense-x86_64"
else
    compile_arch arm64 "${BUILD_DIR}/AuraSense"
fi

echo "==> [3/6] Assembling and signing AuraSense.app..."
APP_BUNDLE="${BUILD_DIR}/AuraSense.app"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/AuraSense" "${APP_BUNDLE}/Contents/MacOS/AuraSense"
chmod +x "${APP_BUNDLE}/Contents/MacOS/AuraSense"
cp "${INFO_PLIST}" "${APP_BUNDLE}/Contents/Info.plist"
cp "${RESOURCES_DIR}/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
cp "${RESOURCES_DIR}/AppIcon.png" "${APP_BUNDLE}/Contents/Resources/AppIcon.png"
cp "${RESOURCES_DIR}/"AuraEclipse*Template*.png "${APP_BUNDLE}/Contents/Resources/"
printf "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

sign_bundle "${APP_BUNDLE}" "com.aurasense.mac.app"
codesign --verify --deep --strict "${APP_BUNDLE}"

rm -rf "${CRATE_DIR}/AuraSense.app"
cp -R "${APP_BUNDLE}" "${CRATE_DIR}/AuraSense.app"

echo "==> [4/6] Building AuraSense.dmg (drag AuraSense to Applications)..."
DMG_PATH="${CRATE_DIR}/AuraSense.dmg"
if ! build_dmg_with_hdiutil "${DMG_PATH}"; then
    echo "warning: hdiutil could not build the disk image; using the legacy image writer instead." >&2
    if [[ -n "${MOUNT_POINT}" ]]; then
        hdiutil detach "${MOUNT_POINT}" -force -quiet >/dev/null 2>&1 || true
        MOUNT_POINT=""
    fi
    build_dmg_legacy "${DMG_PATH}"
fi

echo "==> [5/6] Syncing release files into releases/v1..."
mkdir -p "${RELEASES_DIR}"
rm -rf "${CRATE_DIR}/releases/v0.1" "${CRATE_DIR}/releases/v1.0"
rm -rf "${RELEASES_DIR}/AuraSense.app"
cp -R "${APP_BUNDLE}" "${RELEASES_DIR}/AuraSense.app"
cp -f "${DMG_PATH}" "${RELEASES_DIR}/AuraSense.dmg"
# Older builds also wrote a duplicate image under this name.
rm -f "${RELEASES_DIR}/AuraSense-v1.dmg"
rm -f "${RELEASES_DIR}/AuraSense.app.zip"
ditto -c -k --sequesterRsrc --keepParent "${RELEASES_DIR}/AuraSense.app" "${RELEASES_DIR}/AuraSense.app.zip"

echo "==> [6/6] Cleaning up..."
rm -rf "${BUILD_DIR}"

echo "==> Done. AuraSense ${APP_VERSION} (build ${APP_BUILD})"
ls -lh "${DMG_PATH}" "${RELEASES_DIR}/AuraSense.dmg" "${RELEASES_DIR}/AuraSense.app.zip"
echo "    Open ${DMG_PATH} and drag AuraSense into Applications."
