# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- Cut the DMG from 4.2 MB to 2.9 MB (−31%) with no visible change: LZMA (`ULMO`) compression instead of zlib, an alpha-free RGB window backdrop, and a self-drawn icon for `Fix Gatekeeper.app` instead of the 409 KB stock asset catalog `osacompile` ships

### Added
- `Scripts/helper-icon.swift` draws the `Fix Gatekeeper.app` icon (amber tile with a shield check, deliberately distinct from the blue `Jietu.app` tile)

## [0.0.3] — 2026-09-20

### Changed
- Redesigned the DMG installer window: a 660×420 layout on custom artwork, with fixed positions for `Jietu.app`, `Applications` and `Fix Gatekeeper.app`, centered on screen and without toolbar/status bar
- Install notes are now drawn on the DMG window artwork instead of shipped as a text file
- `Scripts/build-dmg.sh` packages through a writable intermediate image, saves the window geometry / background / icon positions into the image's `.DS_Store`, and verifies the result before reporting size and checksum

### Removed
- `00-请先读我.txt` from the DMG — its install notes moved into the window artwork

### Fixed
- Release workflow: let `build-dmg.sh` do the build so it can fall back to ad-hoc signing when the self-signed `Jietu` certificate is absent, instead of failing with `No certificate matching 'Jietu' found`
- Package the DMG with either `diskutil image` (macOS 26+) or `hdiutil` (older systems), so the same script works locally and on CI
- Run CI and Release on `macos-26` — the project's deployment target is macOS 26, and on macOS 15 runners neither Xcode 26 nor the test host is usable
- Stop masking CI failures: the build/test pipelines piped into `xcbeautify` without `pipefail`, so a failing build was reported as a success

## [0.0.2] — 2026-09-19

### Fixed
- Replace `Remove Quarantine.command` with signed `Fix Gatekeeper.app` and document that the first open must be **right-click → Open** (Gatekeeper blocks plain double-clicks on any downloaded executable)

## [0.0.1] — 2026-09-19

### Added
- Internationalization (i18n) — English & Simplified Chinese
- English README.md and Chinese README_zh-CN.md
- GitHub Actions CI/CD — automatic build, test, and release on tag push
- CONTRIBUTING.md, LICENSE (MIT), CHANGELOG.md
- Installation instructions and quarantine-removal script in DMG
- Area, window, full screen, timed, and scrolling capture
- Screen recording with system audio + microphone, pause/resume
- Object-based annotation tools
- Live Text (OCR), Translation, Pin, Color picker
- Global hotkeys, theme support, recent history

[Unreleased]: https://github.com/ixxxxoooo/jietu/compare/v0.0.3...HEAD
[0.0.3]: https://github.com/ixxxxoooo/jietu/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/ixxxxoooo/jietu/releases/tag/v0.0.2
[0.0.1]: https://github.com/ixxxxoooo/jietu/releases/tag/v0.0.1
