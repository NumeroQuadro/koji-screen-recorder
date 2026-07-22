#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_DEVICE=""
MOUNT_POINT=""

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${DMG_DEVICE}" ]]; then
    hdiutil detach "${DMG_DEVICE}" -quiet 2>/dev/null || hdiutil detach "${DMG_DEVICE}" -force -quiet 2>/dev/null || true
  elif [[ -n "${MOUNT_POINT}" ]]; then
    hdiutil detach "${MOUNT_POINT}" -quiet 2>/dev/null || hdiutil detach "${MOUNT_POINT}" -force -quiet 2>/dev/null || true
  fi
}
trap cleanup EXIT

info() {
  echo "==> $*"
}

info "Building DMG"
(
  cd "${ROOT_DIR}"
  ./scripts/build-dmg.sh --skip-assets >/dev/null
)

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${ROOT_DIR}/Sources/Resources/Info.plist" 2>/dev/null || true)"
[[ -n "${VERSION}" ]] || fail "Could not read version from Info.plist"

DMG_PATH="${ROOT_DIR}/build/Koji-${VERSION}.dmg"
[[ -f "${DMG_PATH}" ]] || fail "DMG not found: ${DMG_PATH}"

info "Mounting DMG: ${DMG_PATH}"
ATTACH_OUT="$(hdiutil attach "${DMG_PATH}" -nobrowse -readonly -noverify -noautoopen)"
MOUNT_LINE="$(echo "${ATTACH_OUT}" | awk '/\/Volumes\// {print; exit}')"
DMG_DEVICE="$(echo "${MOUNT_LINE}" | awk '{print $1}')"
MOUNT_POINT="$(echo "${MOUNT_LINE}" | sed -n 's|^.*\(/Volumes/.*\)$|\1|p' | xargs)"

[[ -n "${DMG_DEVICE}" ]] || fail "Could not detect DMG device"
[[ -n "${MOUNT_POINT}" ]] || fail "Could not detect mount point"

info "Mounted at: ${MOUNT_POINT}"

APP_PATH="${MOUNT_POINT}/Koji.app"
[[ -d "${APP_PATH}" ]] || fail "Missing app bundle: ${APP_PATH}"

info "Verifying code signature"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}" >/dev/null

info "Verifying Applications symlink"
[[ -L "${MOUNT_POINT}/Applications" ]] || fail "Missing Applications symlink"
[[ "$(readlink "${MOUNT_POINT}/Applications")" == "/Applications" ]] || fail "Applications link does not point to /Applications"

info "Verifying background image"
[[ -f "${MOUNT_POINT}/.background/background.png" ]] || fail "Missing DMG background at .background/background.png"

info "Unmounting"
hdiutil detach "${DMG_DEVICE}" -quiet
DMG_DEVICE=""
MOUNT_POINT=""

echo "PASS"
