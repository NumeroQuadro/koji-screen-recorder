#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_BIN_DIR="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="$SPARKLE_BIN_DIR/generate_appcast"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/generate_appcast.sh <archives_dir>

Environment variables (optional):
  SPARKLE_DOWNLOAD_URL_PREFIX       Prefix URL where DMGs are hosted (eg: https://example.com/downloads/)
  SPARKLE_RELEASE_NOTES_URL_PREFIX  Prefix URL for release notes files (if present)

Signing (choose one):
  - Default: uses your private key stored in Keychain (created by generate_keys)
  - SPARKLE_EDDSA_PRIVATE_KEY_FILE: path to exported private key file (from generate_keys -x)
  - SPARKLE_EDDSA_PRIVATE_KEY:      base64 secret; will be piped to generate_appcast via stdin

Example:
  SPARKLE_DOWNLOAD_URL_PREFIX="https://yourdomain.com/releases/" \
  SPARKLE_EDDSA_PRIVATE_KEY_FILE="$HOME/.secrets/koji_sparkle_private_key" \
  ./scripts/generate_appcast.sh ./dist/releases
EOF
}

ARCHIVES_DIR="${1:-}"
if [[ -z "$ARCHIVES_DIR" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -x "$GENERATE_APPCAST" ]]; then
  echo "Sparkle tools not found at $GENERATE_APPCAST"
  echo "Running 'swift build' to fetch Sparkle..."
  (cd "$ROOT_DIR" && swift build >/dev/null)
fi

ARGS=()

if [[ -n "${SPARKLE_DOWNLOAD_URL_PREFIX:-}" ]]; then
  ARGS+=(--download-url-prefix "$SPARKLE_DOWNLOAD_URL_PREFIX")
fi

if [[ -n "${SPARKLE_RELEASE_NOTES_URL_PREFIX:-}" ]]; then
  ARGS+=(--release-notes-url-prefix "$SPARKLE_RELEASE_NOTES_URL_PREFIX")
fi

OUTPUT_PATH="$ARCHIVES_DIR/appcast.xml"
ARGS+=(-o "$OUTPUT_PATH")

if [[ -n "${SPARKLE_EDDSA_PRIVATE_KEY_FILE:-}" ]]; then
  ARGS+=(--ed-key-file "$SPARKLE_EDDSA_PRIVATE_KEY_FILE")
  "$GENERATE_APPCAST" "${ARGS[@]}" "$ARCHIVES_DIR"
elif [[ -n "${SPARKLE_EDDSA_PRIVATE_KEY:-}" ]]; then
  # Secret is a base64-encoded key file (as exported by generate_keys -x).
  echo "$SPARKLE_EDDSA_PRIVATE_KEY" | "$GENERATE_APPCAST" "${ARGS[@]}" --ed-key-file - "$ARCHIVES_DIR"
else
  # Falls back to Keychain
  "$GENERATE_APPCAST" "${ARGS[@]}" "$ARCHIVES_DIR"
fi

echo "Generated appcast: $OUTPUT_PATH"
