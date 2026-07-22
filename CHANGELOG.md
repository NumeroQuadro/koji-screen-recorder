# Changelog

## [1.0.0] - 2026-04-05

### Added

- Menu-bar-only app shell with SwiftUI popover UI
- Screen video capture via ScreenCaptureKit
- System audio capture (including Bluetooth output)
- Microphone capture as a separate audio track
- AVAssetWriter encoding pipeline (.mov/.mp4, H.264/HEVC)
- Preferences window (format, codec, frame rate, cursor, output directory, hotkey, launch at login)
- Hardening: partial-file recovery, disk-space monitoring, and graceful error handling
- Distribution: `scripts/build.sh` to create a signed `.app` and `.dmg`
