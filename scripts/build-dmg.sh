#!/usr/bin/env bash
#
# build-dmg.sh — Fully automated DMG build pipeline for Kōji
#
# Pipeline:
#   1. (Optional) Regenerate branding assets
#   2. Build release binary via swift build -c release
#   3. Assemble .app bundle (binary, Info.plist, AppIcon.icns, resources)
#   4. Codesign with hardened runtime + entitlements
#   5. Create read-write DMG with custom background
#   6. Style DMG via AppleScript (icon positions, window size, background)
#   7. Convert to compressed read-only DMG
#   8. Codesign the DMG itself
#
# Usage:
#   ./scripts/build-dmg.sh                  # Full build
#   ./scripts/build-dmg.sh --skip-assets    # Skip asset regeneration
#   ./scripts/build-dmg.sh --skip-sign      # Skip codesigning
#
# Environment variables:
#   SIGNING_IDENTITY  — Codesign identity (default: "-" = ad-hoc)
#
set -euo pipefail

# ────────────────────────────────────────────────────────
# Configuration
# ────────────────────────────────────────────────────────

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Koji"
DISPLAY_NAME="Kōji"
BUNDLE_ID="com.koji.screenrecorder"

SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
IS_ADHOC_SIGNING=false
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
    IS_ADHOC_SIGNING=true
fi
BUILD_DIR="${ROOT_DIR}/build"
DIST_DIR="${ROOT_DIR}/dist"
SCRIPTS_DIR="${ROOT_DIR}/scripts"
RESOURCES_DIR_PROJECT="${ROOT_DIR}/resources"

INFO_PLIST_SRC="${ROOT_DIR}/Sources/Resources/Info.plist"
RESOURCES_SRC_DIR="${ROOT_DIR}/Sources/Resources"
ENTITLEMENTS_SRC="${ROOT_DIR}/Koji.entitlements"

# Extract version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${INFO_PLIST_SRC}" 2>/dev/null || echo "1.0.0")

# DMG layout — matches generate_dmg_background.swift
DMG_WINDOW_WIDTH=660
DMG_WINDOW_HEIGHT=400
DMG_ICON_SIZE=128
APP_ICON_X=170
APP_ICON_Y=190
ALIAS_ICON_X=490
ALIAS_ICON_Y=190

# Parse flags
SKIP_ASSETS=false
SKIP_SIGN=false
for arg in "$@"; do
    case "$arg" in
        --skip-assets) SKIP_ASSETS=true ;;
        --skip-sign)   SKIP_SIGN=true ;;
        -h|--help)
            echo "Usage: $0 [--skip-assets] [--skip-sign]"
            echo ""
            echo "Flags:"
            echo "  --skip-assets  Skip regenerating branding assets"
            echo "  --skip-sign    Skip codesigning"
            echo ""
            echo "Environment:"
            echo "  SIGNING_IDENTITY  Codesign identity (default: - = ad-hoc)"
            exit 0
            ;;
        *) echo "Unknown flag: $arg (use --help)"; exit 1 ;;
    esac
done

# ────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────

info()  { echo "==> $*"; }
ok()    { echo "  ✅ $*"; }
warn()  { echo "  ⚠️  $*"; }
fail()  { echo "  ❌ $*" >&2; exit 1; }

codesign_target() {
    local target="$1"
    local -a command=(codesign --force --sign "${SIGNING_IDENTITY}")

    if [[ "${IS_ADHOC_SIGNING}" == "false" ]]; then
        command+=(--options runtime)
    fi

    command+=("${target}")
    "${command[@]}"
}

codesign_app_bundle() {
    local app_bundle="$1"
    local -a command=(codesign --force --sign "${SIGNING_IDENTITY}")

    if [[ "${IS_ADHOC_SIGNING}" == "false" ]]; then
        command+=(--options runtime)
    fi

    command+=(--entitlements "${ENTITLEMENTS_SRC}" "${app_bundle}")
    "${command[@]}"
}

# ────────────────────────────────────────────────────────
# Step 1: Regenerate branding assets
# ────────────────────────────────────────────────────────

if [[ "$SKIP_ASSETS" == "false" ]]; then
    info "Generating branding assets"

    if [[ -f "${SCRIPTS_DIR}/generate_icon.swift" ]]; then
        info "  → App icon"
        swift "${SCRIPTS_DIR}/generate_icon.swift" 2>/dev/null
        ok "App icon generated"
    fi

    if [[ -f "${SCRIPTS_DIR}/generate_menubar_icons.swift" ]]; then
        info "  → Menu bar icons"
        swift "${SCRIPTS_DIR}/generate_menubar_icons.swift" 2>/dev/null
        ok "Menu bar icons generated"
    fi

    if [[ -f "${SCRIPTS_DIR}/generate_dmg_background.swift" ]]; then
        info "  → DMG background"
        swift "${SCRIPTS_DIR}/generate_dmg_background.swift" 2>/dev/null
        ok "DMG background generated"
    fi
else
    info "Skipping asset generation (--skip-assets)"
fi

# ────────────────────────────────────────────────────────
# Step 2: Build release binary
# ────────────────────────────────────────────────────────

info "Building release binary (swift build -c release)"
(
    cd "${ROOT_DIR}"
    swift build -c release 2>&1 | tail -5
)

BIN_DIR="$(cd "${ROOT_DIR}" && swift build -c release --show-bin-path 2>/dev/null)"
BIN_PATH="${BIN_DIR}/${APP_NAME}"

if [[ ! -f "${BIN_PATH}" ]]; then
    fail "Binary not found at ${BIN_PATH}"
fi
ok "Binary: ${BIN_PATH}"

# ────────────────────────────────────────────────────────
# Step 3: Assemble .app bundle
# ────────────────────────────────────────────────────────
#
# Koji.app/
# ├── Contents/
# │   ├── Info.plist
# │   ├── MacOS/
# │   │   └── Koji          (binary)
# │   ├── Resources/
# │   │   ├── AppIcon.icns
# │   │   └── Assets.car    (if compiled asset catalog)
# │   └── Frameworks/       (future: Sparkle, etc.)
# └── _CodeSignature/

info "Assembling .app bundle"
rm -rf "${DIST_DIR}"

APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
APP_RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"

mkdir -p "${MACOS_DIR}" "${APP_RESOURCES_DIR}" "${FRAMEWORKS_DIR}"

# Copy binary
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

# Copy Info.plist
cp "${INFO_PLIST_SRC}" "${CONTENTS_DIR}/Info.plist"

# Copy all resources (excluding Info.plist itself)
if [[ -d "${RESOURCES_SRC_DIR}" ]]; then
    rsync -a --exclude 'Info.plist' "${RESOURCES_SRC_DIR}/" "${APP_RESOURCES_DIR}/"
fi

# Embed Sparkle.framework (SwiftPM binary dependency)
if [[ -d "${BIN_DIR}/Sparkle.framework" ]]; then
    rsync -a "${BIN_DIR}/Sparkle.framework" "${FRAMEWORKS_DIR}/"
    ok "Embedded Sparkle.framework"

    # Ensure the executable can resolve @rpath frameworks inside the app bundle.
    if ! otool -l "${MACOS_DIR}/${APP_NAME}" | grep -q "@executable_path/../Frameworks"; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/${APP_NAME}"
        ok "Added Frameworks rpath"
    fi
fi

# Ensure CFBundleIconFile is in Info.plist
if ! grep -q "CFBundleIconFile" "${CONTENTS_DIR}/Info.plist"; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${CONTENTS_DIR}/Info.plist"
    ok "Added CFBundleIconFile to Info.plist"
fi

ok "App bundle: ${APP_BUNDLE}"

# ────────────────────────────────────────────────────────
# Step 4: Codesign with hardened runtime
# ────────────────────────────────────────────────────────

if [[ "$SKIP_SIGN" == "false" ]]; then
    info "Codesigning app (identity: ${SIGNING_IDENTITY})"
    if [[ "${IS_ADHOC_SIGNING}" == "true" ]]; then
        warn "Ad-hoc signing detected. Skipping hardened runtime so local builds can launch."
        warn "Use a Developer ID identity plus notarization for distributable artifacts."
    fi

    if [[ -d "${FRAMEWORKS_DIR}/Sparkle.framework" ]]; then
        codesign_target "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/Autoupdate"
        codesign_target "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
        codesign_target "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
        codesign_target "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/Updater.app"
        codesign_target "${FRAMEWORKS_DIR}/Sparkle.framework"
        ok "Embedded Sparkle framework signed"
    fi

    codesign_app_bundle "${APP_BUNDLE}"

    codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}" 2>&1 | tail -3
    ok "App codesigned and verified"
else
    info "Skipping codesign (--skip-sign)"
fi

# ────────────────────────────────────────────────────────
# Step 5: Create temporary read-write DMG
# ────────────────────────────────────────────────────────

info "Creating branded DMG (v${VERSION})"

mkdir -p "${BUILD_DIR}"

DMG_STAGING="${BUILD_DIR}/dmg-staging"
DMG_TMP="${BUILD_DIR}/temp.dmg"
DMG_FINAL="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"
DMG_FINAL_DIST="${DIST_DIR}/${APP_NAME}.dmg"
VOLUME_NAME="${DISPLAY_NAME}"
DMG_BG_SRC="${RESOURCES_DIR_PROJECT}/dmg-background@2x.png"

rm -rf "${DMG_STAGING}" "${DMG_TMP}" "${DMG_FINAL}"
mkdir -p "${DMG_STAGING}"

# Copy app and create Applications symlink
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/${APP_NAME}.app"
ln -sf /Applications "${DMG_STAGING}/Applications"

# Stage background image in hidden folder
mkdir -p "${DMG_STAGING}/.background"
if [[ -f "${DMG_BG_SRC}" ]]; then
    cp "${DMG_BG_SRC}" "${DMG_STAGING}/.background/background.png"
    ok "Background image staged"
else
    warn "No DMG background at ${DMG_BG_SRC} — plain DMG"
fi

# Create read-write DMG
APP_SIZE_KB=$(du -sk "${DMG_STAGING}" | cut -f1)
DMG_SIZE_KB=$((APP_SIZE_KB + 20480))

hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDRW \
    -size "${DMG_SIZE_KB}k" \
    "${DMG_TMP}" >/dev/null 2>&1

ok "Read-write DMG created"

# ────────────────────────────────────────────────────────
# Step 6: Mount and style via AppleScript
# ────────────────────────────────────────────────────────

info "Styling DMG via AppleScript"

# Mount read-write
MOUNT_OUTPUT=$(hdiutil attach "${DMG_TMP}" -readwrite -noverify -noautoopen 2>/dev/null)
DEVICE=$(echo "${MOUNT_OUTPUT}" | grep '^/dev/' | head -1 | awk '{print $1}')
MOUNT_POINT="/Volumes/${VOLUME_NAME}"

# Fallback: find mount point from output
if [[ ! -d "${MOUNT_POINT}" ]]; then
    MOUNT_POINT=$(echo "${MOUNT_OUTPUT}" | grep '/Volumes/' | sed 's/.*\(\/Volumes\/.*\)/\1/' | head -1 | xargs)
fi

info "  Volume mounted at: ${MOUNT_POINT}"

# Calculate centered window position (assume ~1440×900 screen)
WIN_X=$(( (1440 - DMG_WINDOW_WIDTH) / 2 ))
WIN_Y=$(( (900 - DMG_WINDOW_HEIGHT) / 2 ))
WIN_R=$(( WIN_X + DMG_WINDOW_WIDTH ))
WIN_B=$(( WIN_Y + DMG_WINDOW_HEIGHT ))

# Apply Finder styling
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false

        -- Center the window on screen
        set the bounds of container window to {${WIN_X}, ${WIN_Y}, ${WIN_R}, ${WIN_B}}

        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to ${DMG_ICON_SIZE}
        set background picture of theViewOptions to file ".background:background.png"

        -- Position icons
        set position of item "${APP_NAME}.app" of container window to {${APP_ICON_X}, ${APP_ICON_Y}}
        set position of item "Applications" of container window to {${ALIAS_ICON_X}, ${ALIAS_ICON_Y}}

        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

ok "Finder view settings applied"
ok "  Window: ${DMG_WINDOW_WIDTH}×${DMG_WINDOW_HEIGHT} centered at (${WIN_X}, ${WIN_Y})"
ok "  App icon: (${APP_ICON_X}, ${APP_ICON_Y})"
ok "  Applications: (${ALIAS_ICON_X}, ${ALIAS_ICON_Y})"
ok "  Icon size: ${DMG_ICON_SIZE}px"

# Hide .background folder
SetFile -a V "${MOUNT_POINT}/.background" 2>/dev/null || true

# Unmount
sync
hdiutil detach "${DEVICE}" -quiet 2>/dev/null || hdiutil detach "${DEVICE}" -force -quiet 2>/dev/null || true
sleep 1

# ────────────────────────────────────────────────────────
# Step 7: Convert to compressed read-only DMG
# ────────────────────────────────────────────────────────

info "Compressing to final DMG"

hdiutil convert "${DMG_TMP}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${DMG_FINAL}" >/dev/null 2>&1

rm -f "${DMG_TMP}"
ok "Compressed DMG: ${DMG_FINAL}"

# Also copy to dist/ for convenience
cp "${DMG_FINAL}" "${DMG_FINAL_DIST}"

# ────────────────────────────────────────────────────────
# Step 8: Codesign the DMG itself
# ────────────────────────────────────────────────────────

if [[ "$SKIP_SIGN" == "false" ]]; then
    info "Codesigning DMG"
    codesign --sign "${SIGNING_IDENTITY}" "${DMG_FINAL}"
    codesign --sign "${SIGNING_IDENTITY}" "${DMG_FINAL_DIST}"
    ok "DMG codesigned"
else
    info "Skipping DMG codesign (--skip-sign)"
fi

# ────────────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────────────

DMG_SIZE=$(du -h "${DMG_FINAL}" | cut -f1 | xargs)

echo ""
echo "┌──────────────────────────────────────────────────┐"
echo "│              Kōji Build Complete ✅               │"
echo "├──────────────────────────────────────────────────┤"
echo "│  Version:  ${VERSION}"
echo "│  App:      dist/${APP_NAME}.app"
echo "│  DMG:      build/${APP_NAME}-${VERSION}.dmg"
echo "│  DMG copy: dist/${APP_NAME}.dmg"
echo "│  Size:     ${DMG_SIZE}"
echo "│  Signed:   ${SIGNING_IDENTITY}"
echo "│"
echo "│  Next: ./scripts/notarize.sh build/${APP_NAME}-${VERSION}.dmg"
echo "└──────────────────────────────────────────────────┘"
echo ""

# Clean up staging
rm -rf "${DMG_STAGING}"
