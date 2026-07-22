# Features — Kōji Screen Recorder

Status tracking for implemented features. Updated by agents after each milestone.

---

## Core

| Feature | Status | Milestone | Notes |
|---------|--------|-----------|-------|
| Menu bar app shell (NSStatusItem) | ⬜ Not started | M1 | |
| SwiftUI popover with Record/Stop | ⬜ Not started | M1 | |
| Permission checking & guidance | ⬜ Not started | M1 | |
| Screen capture (SCStream video) | ⬜ Not started | M2 | |
| AVAssetWriter encoding pipeline | ⬜ Not started | M2 | |
| Full-screen recording to .mov | ⬜ Not started | M2 | |
| System audio capture | ⬜ Not started | M3 | |
| Audio-video sync | ⬜ Not started | M3 | |
| Microphone capture | ⬜ Not started | M4 | |
| Audio mixing (system + mic) | ⬜ Not started | M4 | |
| Mic toggle in UI | ⬜ Not started | M4 | |

## UI & UX

| Feature | Status | Milestone | Notes |
|---------|--------|-----------|-------|
| Recording timer display | ⬜ Not started | M5 | |
| Recording indicator (icon change) | ⬜ Not started | M5 | |
| Display / window picker | ⬜ Not started | M5 | |
| Microphone device picker | ⬜ Not started | M5 | |
| "Reveal in Finder" after save | ⬜ Not started | M5 | |

## Settings

| Feature | Status | Milestone | Notes |
|---------|--------|-----------|-------|
| Settings window (tabbed) | ⬜ Not started | M6 | |
| Output directory picker | ⬜ Not started | M6 | |
| Video codec selection (H.264/HEVC) | ⬜ Not started | M6 | |
| Format selection (.mov/.mp4) | ⬜ Not started | M6 | |
| Frame rate selection (30/60) | ⬜ Not started | M6 | |
| Global hotkey | ⬜ Not started | M6 | |
| Launch at login | ⬜ Not started | M6 | |
| Show/hide cursor toggle | ⬜ Not started | M6 | |

## Reliability

| Feature | Status | Milestone | Notes |
|---------|--------|-----------|-------|
| Graceful stream error handling | ⬜ Not started | M7 | |
| Partial file recovery | ⬜ Not started | M7 | |
| Disk space monitoring | ⬜ Not started | M7 | |
| Completion notification | ⬜ Not started | M7 | |
| Audio edge case handling | ⬜ Not started | M7 | |

## Distribution

| Feature | Status | Milestone | Notes |
|---------|--------|-----------|-------|
| Release build script | ✅ Done | M8 | `scripts/build.sh`, `scripts/build-dmg.sh` |
| DMG creation | ✅ Done | M8 | Custom background + Finder layout |
| README | ✅ Done | M8 | Install, uninstall, updates, Pages, Homebrew |
| Code signing + hardened runtime | ✅ Done | M8 | Ad-hoc by default; Developer ID supported |
| Auto-updates (Sparkle 2) | ✅ Done | M8 | Settings + menu item + key/appcast scripts |
| GitHub Actions CI | ✅ Done | M8 | `swift build` + fail on warnings |
| GitHub Actions release workflow | ✅ Done | M8 | Tag `v*` builds DMG + GitHub Release |
| GitHub Pages landing page | ✅ Done | M8 | `docs/index.html` + `docs/og-image.png` |
| Homebrew Cask template | ✅ Done | M8 | `homebrew/koji.rb` + `scripts/update_cask.sh` |
