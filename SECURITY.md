# Security Policy (Kōji)

Kōji is a macOS screen + audio recorder designed for privacy-sensitive recording workflows. This document explains how to report vulnerabilities, what is supported, and what users can expect from the security design.

## Supported Versions

Security fixes are provided for:
- The latest released version only.

If you need longer support windows, open a request with your use case.

## Reporting a Vulnerability

Please report security issues **privately** through GitHub's
[private vulnerability reporting](https://github.com/NumeroQuadro/koji-screen-recorder/security/advisories/new).

Include the affected version, macOS version, steps to reproduce, impact assessment,
and any proof-of-concept code.

Do **not** open a public GitHub issue for vulnerabilities.

## Response Time Commitment

- Acknowledgement: within **3 business days**
- Initial triage: within **7 business days**
- Fix timeline: best-effort; critical issues are prioritized for the next patch release

## Security Design Overview (User-Facing)

### Offline behavior

Kōji contains no first-party analytics/telemetry. The only expected network activity is for **software updates** (when enabled) via Sparkle.

### macOS permissions

Kōji’s core functionality requires:
- Screen Recording (to capture the display/window/app)
- Microphone (optional; only if you enable mic capture)

Depending on configuration, Kōji may also request:
- Notifications (to show “Recording saved” and warnings)
- Input Monitoring (only if the global hotkey implementation relies on global keyDown monitoring on your macOS version)

### Updates and integrity

Kōji is intended to ship as a code-signed and notarized macOS app. If Sparkle updates are enabled:
- The appcast feed URL should be HTTPS
- The app embeds an EdDSA public key for signed updates (`SUPublicEDKey`)

Users can verify integrity of an official release on macOS with:
```bash
spctl --assess --type open --context context:primary-signature Koji-*.dmg
codesign --verify --deep --strict Koji.app
```

### Data on disk

Recordings are stored locally in the output directory you choose (default `~/Movies/Koji/`). Kōji does not upload recordings.

## Coordinated Disclosure

We support coordinated disclosure and will credit reporters who want to be acknowledged after a fix ships.
