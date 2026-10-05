# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The version is the firmware version the display reports.

## [Unreleased]

## [2.8.0] - 2026-10-05

### Added
- **Standby.** After 60 s without data from the PC (asleep, undocked, collector not running)
  the backlight turns off; it comes back on as soon as data arrives again. A tap wakes the
  display for 30 s. Previously it kept showing "Waiting for data" or "Offline", e.g. while
  the PC woke up after docking.
- This changelog.

### Changed
- README: status badges in the header (latest release, platform, PowerShell, license);
  clearer repository description and topics on GitHub.

## [2.7.0] - 2026-10-04

### Added
- **Self-update from the display.** When a newer release is on GitHub, the home page shows
  an "Update x.y.z" banner; tapping it twice runs `host/update.ps1`, which downloads the
  setup ZIP, verifies its SHA256 against the value GitHub lists, downloads Espressif's
  esptool (pinned version, checksum-verified), flashes the matching firmware and reinstalls
  the collector (`config.json` is kept). The device never goes online — only the PC talks to
  GitHub. Firmware built with custom panel flags reports itself as "custom" and gets no
  banner.
- **Session detail sheet.** Long-pressing a session row or the session line shows status and
  age, where it runs (this PC / terminal / remote label), project, branch, model and effort,
  context usage (e.g. "512k / 1M (51%)") and start time. Works for local and remote sessions.

### Changed
- Collector log messages are now in English.

### Security
- Serial fields received from the display (firmware version, tap coordinates) are sanitized
  before they are written to `collector.log`, preventing log injection from a malfunctioning
  or tampered board.

## [2.6.0] - 2026-10-04

First public release.

### Added
- **Usage display (Home page).** Two ring gauges for the 5-hour session and 7-day week,
  colored green/yellow/red, each with a countdown to its reset and a forecast
  ("Limit ~HH:MM" or "~XX% @ Reset").
- **Session line** on the home page: the session that is waiting for you (or, failing that,
  the one working), with its title, how long it has been waiting, and a count of further
  active sessions.
- **Local and Remote session pages** (3 pages total: Home → Local → Remote) with a status
  dot, title, context-window fill and age per session, and a summary line at the bottom.
- **Context-window fill** per session in the lists (orange from 75%, red from 90%).
- **"Done" flash:** the screen briefly inverts when a session that worked for at least 10 s
  becomes idle or starts waiting for you. Not while Windows is locked.
- **Limit warning:** the gauge ring pulses from 90%, and the display flashes twice when a
  value crosses 90%; "Limit reached" at 100%; "New 5h window" / "New week" when a window
  resets.
- **Tap to open:** tap a session to open it in Claude Desktop (local and remote alike);
  swipe sideways to switch pages; back to Home after 60 s without a tap.
- **Offline** and **"Waiting for data"** screens; backlight off while Windows is locked.
- **Plug & play setup assistant** (`Setup.cmd` / `setup/Setup.ps1`) and a background service
  via Task Scheduler (no admin rights), plus `host/install.ps1`, `host/uninstall.ps1` and
  `tools/make-release.ps1`.
- Usage is read through the Claude CLI's `get_usage` control request (no quota used); remote
  sessions come from the Remote Control session list. **USB serial only — no Wi-Fi and no
  token on the device.**

[Unreleased]: https://github.com/Tim-Schaller/ClaudeDisplay/compare/v2.8.0...HEAD
[2.8.0]: https://github.com/Tim-Schaller/ClaudeDisplay/releases/tag/v2.8.0
[2.7.0]: https://github.com/Tim-Schaller/ClaudeDisplay/releases/tag/v2.7.0
[2.6.0]: https://github.com/Tim-Schaller/ClaudeDisplay/releases/tag/v2.6.0
