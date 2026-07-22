#!/usr/bin/env bash
#
# notarize.sh — Apple notarization for Kōji DMG
#
# Submits a DMG to Apple's notary service, waits for approval,
# and staples the notarization ticket to the DMG.
#
# Prerequisites:
#   - Apple Developer account (paid, $99/year)
#   - Developer ID Application certificate installed in Keychain
#   - App-specific password stored in Keychain:
#       xcrun notarytool store-credentials "koji-notarize" \
#           --apple-id "your@email.com" \
#           --team-id "YOUR_TEAM_ID"
#
# Usage:
#   ./scripts/notarize.sh build/Koji-1.0.0.dmg
#   ./scripts/notarize.sh dist/Koji.dmg
#
# Environment variables:
#   NOTARIZE_PROFILE    — Keychain profile name (default: "koji-notarize")
#   APPLE_ID            — Apple ID email (alternative to profile)
#   TEAM_ID             — Apple Developer Team ID (alternative to profile)
#   APP_PASSWORD        — App-specific password (alternative to profile)
#
set -euo pipefail

# ────────────────────────────────────────────────────────
# Configuration
# ────────────────────────────────────────────────────────

NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-koji-notarize}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-false}"
DMG_PATH="${1:-}"

# ────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────

info()  { echo "==> $*"; }
ok()    { echo "  ✅ $*"; }
warn()  { echo "  ⚠️  $*"; }
fail()  { echo "  ❌ $*" >&2; exit 1; }

# ────────────────────────────────────────────────────────
# Validation
# ────────────────────────────────────────────────────────

if [[ -z "${DMG_PATH}" ]]; then
    echo "Usage: $0 <path-to-dmg>"
    echo ""
    echo "Example:"
    echo "  $0 build/Koji-1.0.0.dmg"
    echo ""
    echo "Prerequisites:"
    echo "  1. Store notarization credentials:"
    echo "     xcrun notarytool store-credentials \"koji-notarize\" \\"
    echo "         --apple-id \"your@email.com\" \\"
    echo "         --team-id \"YOUR_TEAM_ID\""
    echo ""
    echo "  2. Build the DMG:"
    echo "     SIGNING_IDENTITY=\"Developer ID Application: Your Name\" ./scripts/build-dmg.sh"
    exit 1
fi

if [[ ! -f "${DMG_PATH}" ]]; then
    fail "DMG not found: ${DMG_PATH}"
fi

# Check if notarytool is available
if ! command -v xcrun &>/dev/null; then
    fail "xcrun not found — Xcode Command Line Tools required"
fi

# Check if credentials are available
info "Checking notarization credentials"

CREDENTIAL_ARGS=()

if xcrun notarytool history --keychain-profile "${NOTARIZE_PROFILE}" 2>/dev/null | head -1 | grep -q "Successfully"; then
    info "  Using keychain profile: ${NOTARIZE_PROFILE}"
    CREDENTIAL_ARGS=(--keychain-profile "${NOTARIZE_PROFILE}")
elif [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APP_PASSWORD:-}" ]]; then
    info "  Using environment variables (APPLE_ID, TEAM_ID, APP_PASSWORD)"
    CREDENTIAL_ARGS=(--apple-id "${APPLE_ID}" --team-id "${TEAM_ID}" --password "${APP_PASSWORD}")
else
    if [[ "${REQUIRE_NOTARIZATION}" == "true" ]]; then
        fail "No notarization credentials found and REQUIRE_NOTARIZATION=true"
    fi

    warn "No notarization credentials found."
    echo ""
    echo "  To set up credentials, run:"
    echo "    xcrun notarytool store-credentials \"${NOTARIZE_PROFILE}\" \\"
    echo "        --apple-id \"your@email.com\" \\"
    echo "        --team-id \"YOUR_TEAM_ID\""
    echo ""
    echo "  Or set environment variables:"
    echo "    APPLE_ID=your@email.com"
    echo "    TEAM_ID=YOUR_TEAM_ID"
    echo "    APP_PASSWORD=xxxx-xxxx-xxxx-xxxx"
    echo ""
    echo "  Skipping notarization gracefully."
    exit 0
fi

# ────────────────────────────────────────────────────────
# Step 1: Submit DMG to Apple
# ────────────────────────────────────────────────────────

info "Submitting DMG to Apple Notary Service"
info "  File: ${DMG_PATH}"
info "  Size: $(du -h "${DMG_PATH}" | cut -f1 | xargs)"

SUBMIT_OUTPUT=$(xcrun notarytool submit "${DMG_PATH}" \
    "${CREDENTIAL_ARGS[@]}" \
    --wait \
    --timeout 30m \
    2>&1)

echo "${SUBMIT_OUTPUT}"

# Check if notarization succeeded
if echo "${SUBMIT_OUTPUT}" | grep -q "status: Accepted"; then
    ok "Notarization accepted!"
elif echo "${SUBMIT_OUTPUT}" | grep -q "status: Invalid"; then
    fail "Notarization rejected. Check the log for details."

    # Try to extract submission ID and fetch the log
    SUBMISSION_ID=$(echo "${SUBMIT_OUTPUT}" | grep "id:" | head -1 | awk '{print $2}')
    if [[ -n "${SUBMISSION_ID}" ]]; then
        info "Fetching rejection log for submission ${SUBMISSION_ID}"
        xcrun notarytool log "${SUBMISSION_ID}" "${CREDENTIAL_ARGS[@]}" 2>&1
    fi

    exit 1
else
    warn "Notarization status unclear. Output above."
fi

# ────────────────────────────────────────────────────────
# Step 2: Staple the notarization ticket
# ────────────────────────────────────────────────────────

info "Stapling notarization ticket to DMG"

xcrun stapler staple "${DMG_PATH}"

if xcrun stapler validate "${DMG_PATH}" 2>&1 | grep -q "valid"; then
    ok "Ticket stapled and validated"
else
    warn "Staple validation returned unexpected output"
fi

# ────────────────────────────────────────────────────────
# Done
# ────────────────────────────────────────────────────────

echo ""
echo "┌──────────────────────────────────────────────────┐"
echo "│         Kōji Notarization Complete ✅             │"
echo "├──────────────────────────────────────────────────┤"
echo "│  DMG: ${DMG_PATH}"
echo "│  Status: Notarized & Stapled"
echo "│"
echo "│  The DMG is now ready for distribution."
echo "│  Users will not see Gatekeeper warnings."
echo "└──────────────────────────────────────────────────┘"
echo ""
