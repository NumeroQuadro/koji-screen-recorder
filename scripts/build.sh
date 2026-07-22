#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Koji"

find_apple_development_identity() {
  command -v security >/dev/null 2>&1 || return 0

  security find-identity -v -p codesigning 2>/dev/null \
    | awk '$0 ~ /"Apple Development:/ && $0 !~ /CSSMERR/ && !found { print $2; found = 1 }'
}

SIGNING_IDENTITY_SOURCE="explicit"
if [[ "${KOJI_SIGN_IDENTITY+x}" == "x" ]]; then
  SIGN_IDENTITY="${KOJI_SIGN_IDENTITY}"
else
  SIGN_IDENTITY="$(find_apple_development_identity)"
  if [[ -n "${SIGN_IDENTITY}" ]]; then
    SIGNING_IDENTITY_SOURCE="auto-detected Apple Development"
  else
    SIGN_IDENTITY="-"
    SIGNING_IDENTITY_SOURCE="ad-hoc fallback"
  fi
fi

IS_ADHOC_SIGNING=false
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
  IS_ADHOC_SIGNING=true
fi
DIST_DIR="${ROOT_DIR}/dist"

INFO_PLIST_SRC="${ROOT_DIR}/Sources/Resources/Info.plist"
RESOURCES_SRC_DIR="${ROOT_DIR}/Sources/Resources"
ENTITLEMENTS_SRC="${ROOT_DIR}/Koji.entitlements"

codesign_target() {
  local target="$1"
  local -a command=(codesign --force --sign "${SIGN_IDENTITY}")

  if [[ "${IS_ADHOC_SIGNING}" == "false" ]]; then
    command+=(--options runtime)
  fi

  command+=("${target}")
  "${command[@]}"
}

codesign_app_bundle() {
  local app_bundle="$1"
  local -a command=(codesign --force --sign "${SIGN_IDENTITY}")

  if [[ "${IS_ADHOC_SIGNING}" == "false" ]]; then
    command+=(--options runtime)
  fi

  if [[ -f "${ENTITLEMENTS_SRC}" ]]; then
    command+=(--entitlements "${ENTITLEMENTS_SRC}")
  fi

  command+=("${app_bundle}")
  "${command[@]}"
}

echo "==> swift build -c release"
(
  cd "${ROOT_DIR}"
  swift build -c release
)

BIN_DIR="$(cd "${ROOT_DIR}" && swift build -c release --show-bin-path)"
BIN_PATH="${BIN_DIR}/${APP_NAME}"

if [[ ! -f "${BIN_PATH}" ]]; then
  echo "error: binary not found at ${BIN_PATH}" >&2
  exit 1
fi

echo "==> assembling .app bundle"
rm -rf "${DIST_DIR}"

APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${FRAMEWORKS_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

cp "${INFO_PLIST_SRC}" "${CONTENTS_DIR}/Info.plist"

if [[ -d "${RESOURCES_SRC_DIR}" ]]; then
  rsync -a --exclude 'Info.plist' "${RESOURCES_SRC_DIR}/" "${RESOURCES_DIR}/"
fi

# Embed Sparkle.framework (SwiftPM binary dependency)
if [[ -d "${BIN_DIR}/Sparkle.framework" ]]; then
  rsync -a "${BIN_DIR}/Sparkle.framework" "${FRAMEWORKS_DIR}/"

  # Ensure the executable can resolve @rpath frameworks inside the app bundle.
  if ! otool -l "${MACOS_DIR}/${APP_NAME}" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/${APP_NAME}"
  fi
fi

if [[ -f "${ENTITLEMENTS_SRC}" ]]; then
  cp "${ENTITLEMENTS_SRC}" "${DIST_DIR}/Koji.entitlements"
fi

echo "==> codesign"
if [[ "${IS_ADHOC_SIGNING}" == "true" ]]; then
  if [[ "${SIGNING_IDENTITY_SOURCE}" == "ad-hoc fallback" ]]; then
    echo "warning: no valid Apple Development identity found; using ad-hoc signing" >&2
    echo "warning: rebuilt bundles may require Screen Recording and Camera re-authorization" >&2
  else
    echo "warning: explicit ad-hoc signing requested" >&2
  fi
  echo "warning: omitting hardened runtime for local launchability" >&2
else
  echo "==> signing mode: ${SIGNING_IDENTITY_SOURCE}"
fi

if [[ -d "${FRAMEWORKS_DIR}/Sparkle.framework" ]]; then
  codesign_target "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/Autoupdate"
  codesign_target "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
  codesign_target "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
  codesign_target "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/Updater.app"
  codesign_target "${FRAMEWORKS_DIR}/Sparkle.framework"
fi

codesign_app_bundle "${APP_BUNDLE}"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

echo "==> create dmg (hdiutil)"
STAGE_DIR="${DIST_DIR}/dmg"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"
cp -R "${APP_BUNDLE}" "${STAGE_DIR}/${APP_NAME}.app"
ln -sf /Applications "${STAGE_DIR}/Applications"

DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE_DIR}" -ov -format UDZO "${DMG_PATH}" >/dev/null

echo "==> done"
echo "App: ${APP_BUNDLE}"
echo "DMG: ${DMG_PATH}"
