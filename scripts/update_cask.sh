#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASK_PATH="${ROOT_DIR}/homebrew/koji.rb"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/update_cask.sh <version> <path-to-dmg>

Example:
  ./scripts/update_cask.sh 1.0.1 ./build/Koji-1.0.1.dmg

What it does:
  - Computes SHA256 of the DMG
  - Updates homebrew/koji.rb (version + sha256)
  - Prints next-step instructions (Homebrew/homebrew-cask PR or your own tap)
EOF
}

VERSION="${1:-}"
DMG_PATH="${2:-}"

if [[ -z "${VERSION}" || -z "${DMG_PATH}" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -f "${DMG_PATH}" ]]; then
  echo "error: DMG not found: ${DMG_PATH}" >&2
  exit 1
fi

if [[ ! -f "${CASK_PATH}" ]]; then
  echo "error: cask formula not found: ${CASK_PATH}" >&2
  exit 1
fi

SHA256="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
if [[ -z "${SHA256}" ]]; then
  echo "error: failed to compute sha256" >&2
  exit 1
fi

perl -pi -e "s/^\\s*version\\s+\\\"[^\\\"]+\\\"/  version \\\"${VERSION}\\\"/" "${CASK_PATH}"
perl -pi -e "s/^\\s*sha256\\s+\\\"[^\\\"]+\\\"/  sha256 \\\"${SHA256}\\\"/" "${CASK_PATH}"

echo "Updated: ${CASK_PATH}"
echo "  version: ${VERSION}"
echo "  sha256:  ${SHA256}"
echo ""
echo "Next steps:"
echo "  1) Publish the DMG at:"
echo "     https://github.com/<user>/<repo>/releases/download/v${VERSION}/Koji-${VERSION}.dmg"
echo ""
echo "  2) Install from your own tap (recommended while iterating):"
echo "     - Create a tap repo (e.g. github.com/<user>/homebrew-tap)"
echo "     - Put this file at: Casks/koji.rb"
echo "     - Then:"
echo "         brew tap <user>/tap"
echo "         brew install --cask koji"
echo ""
echo "  3) Or submit to Homebrew/homebrew-cask:"
echo "     - Fork Homebrew/homebrew-cask"
echo "     - Add Casks/koji.rb"
echo "     - Open a PR"
