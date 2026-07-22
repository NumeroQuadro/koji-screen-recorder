#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="${ROOT_DIR}/Sources/Resources/Info.plist"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/bump-version.sh major|minor|patch

What it does:
  - Reads CFBundleShortVersionString from Sources/Resources/Info.plist
  - Bumps semantic version (major/minor/patch)
  - Writes CFBundleShortVersionString and CFBundleVersion to the new version
  - Commits the Info.plist change
  - Creates an annotated git tag: v<version>
  - Prints the new version
EOF
}

BUMP_KIND="${1:-}"
if [[ -z "${BUMP_KIND}" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -f "${INFO_PLIST}" ]]; then
  echo "error: Info.plist not found at ${INFO_PLIST}" >&2
  exit 1
fi

cd "${ROOT_DIR}"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: not a git repository" >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: working tree has uncommitted changes; commit or stash first" >&2
  exit 1
fi

CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${INFO_PLIST}" 2>/dev/null || true)"
if [[ -z "${CURRENT_VERSION}" ]]; then
  echo "error: could not read CFBundleShortVersionString from ${INFO_PLIST}" >&2
  exit 1
fi

if [[ ! "${CURRENT_VERSION}" =~ ^([0-9]+)\\.([0-9]+)\\.([0-9]+)$ ]]; then
  echo "error: expected semantic version X.Y.Z, got '${CURRENT_VERSION}'" >&2
  exit 1
fi

MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"

case "${BUMP_KIND}" in
  major)
    MAJOR="$((MAJOR + 1))"
    MINOR="0"
    PATCH="0"
    ;;
  minor)
    MINOR="$((MINOR + 1))"
    PATCH="0"
    ;;
  patch)
    PATCH="$((PATCH + 1))"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
TAG="v${NEW_VERSION}"

if git rev-parse "${TAG}" >/dev/null 2>&1; then
  echo "error: tag already exists: ${TAG}" >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEW_VERSION}" "${INFO_PLIST}"

if /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${INFO_PLIST}" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEW_VERSION}" "${INFO_PLIST}"
else
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${NEW_VERSION}" "${INFO_PLIST}"
fi

git add "${INFO_PLIST}"
git commit -m "Bump version to ${NEW_VERSION}"
git tag -a "${TAG}" -m "${TAG}"

echo "${NEW_VERSION}"
