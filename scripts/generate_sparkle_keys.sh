#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_BIN_DIR="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
GENERATE_KEYS="$SPARKLE_BIN_DIR/generate_keys"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/generate_sparkle_keys.sh [--account <name>] [--export <path>]

What it does:
  - Runs Sparkle's generate_keys tool (stores the private key in your login Keychain)
  - Prints the SUPublicEDKey snippet you must add to Info.plist
  - Optionally exports the private key to a file for CI / another machine

Notes:
  - NEVER commit exported private keys.
  - Prefer storing the exported private key in a password manager / CI secret store.
EOF
}

ACCOUNT="ed25519"
EXPORT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --account)
      ACCOUNT="${2:-}"
      shift 2
      ;;
    --export)
      EXPORT_PATH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -x "$GENERATE_KEYS" ]]; then
  echo "Sparkle tools not found at $GENERATE_KEYS"
  echo "Running 'swift build' to fetch Sparkle..."
  (cd "$ROOT_DIR" && swift build >/dev/null)
fi

echo "Generating / loading Sparkle signing key (private key stored in your Keychain)..."
"$GENERATE_KEYS" --account "$ACCOUNT"

if [[ -n "$EXPORT_PATH" ]]; then
  mkdir -p "$(dirname "$EXPORT_PATH")"
  echo ""
  echo "Exporting private key to: $EXPORT_PATH"
  "$GENERATE_KEYS" --account "$ACCOUNT" -x "$EXPORT_PATH"
  chmod 600 "$EXPORT_PATH" || true
  echo ""
  echo "Store the exported private key in a password manager or CI secret store, then delete the file."
  echo "Do NOT commit it to git."
fi
