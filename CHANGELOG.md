# Changelog

All notable changes to this project are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/); versions use [SemVer](https://semver.org/).

## [0.1.0] — 2026-08-14

Initial release.

### Added
- `Set-SpacedeskDisplay.ps1` — finds the spacedesk virtual display and snaps it to a target
  resolution (default 2752×2064) and per-monitor DPI scale (default 250%). Idempotent; refuses
  to touch the primary monitor. Supports `-WhatIf`, `-Profile`, and manual `-Width/-Height/-Scale`.
- `Watch-Spacedesk.ps1` — event-driven (CIM indication) or polling watcher that auto-snaps the
  display on connect, with debounce and verify-then-act.
- `Register-AutoSnap.ps1` — installs/removes an at-logon, interactive, hidden scheduled task to
  run the watcher automatically.
- `config.json` — `lan` and `usb` presets that share the same logical desktop.
- `docs/how-it-works.md` — the DisplayConfig / undocumented per-monitor DPI write-up.
