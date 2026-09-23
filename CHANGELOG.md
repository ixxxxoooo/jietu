# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.0.4] — 2026-09-23

### Added
- **Area capture now ships with ⌃⌘A as its default global hotkey**; the other actions still start unset, and clearing this one in Settings keeps it cleared instead of being filled back in
- **⌘D pins the current image** from the capture UI: press it while selecting to pin the region as-is, or inside the inline editor to pin the annotated result. The toolbar's pin button carries the shortcut in its tooltip
- Settings gained an **Appearance** section (theme, language, pinned-image styling); theme and language moved out of General into it
- **Pin border glow** (off by default): a pinned image can carry a halo in the selection green instead of the plain window shadow. It follows the image as it moves and scales, and applies to images pinned after the switch is turned on
- The DMG ships `安装说明.txt` — a short bilingual note whose second line is the quarantine command, so it can be selected and copied as a whole (the same line drawn on the window artwork is a PNG and cannot be selected). Permission guidance stays in the app's own onboarding instead of being duplicated there
- The drag-to-authorize panel explains the stale-row case: if the app is **already listed but still reports "not granted"**, that row is left over from an earlier build — select it, remove it with `−`, then drag the app in again

### Changed
- `Scripts/build-dmg.sh` prints the app's designated requirement ("identity") and **refuses to produce an ad-hoc-signed DMG** unless `JIETU_ALLOW_ADHOC=1` is set: an ad-hoc requirement is a `cdhash`, which changes on every build, so every upgrade would make users re-authorize screen recording all over again
- The release workflow imports the self-signed `Jietu` identity from repository secrets (`JIETU_CERT_P12_BASE64` / `JIETU_CERT_P12_PASSWORD`) into a temporary keychain, so CI-built releases carry the same stable identity as local builds; the keychain is deleted right after the build
- DMG window layout: the `Jietu.app` / `Applications` icons moved up, and the install-notes file takes the third slot below them with its caption drawn alongside

### Removed
- `Fix Gatekeeper.app` and `Scripts/helper-icon.swift` — a downloaded executable cannot remove its own quarantine flag, so the DMG hands the command over as text instead

### Fixed
- `AppBundleDragSourceView.hitTest(_:)` compared a point given in the **superview's** coordinate space against its own bounds, moving the card's drag hot zone whenever SwiftUI placed it away from its superview's origin
- The drag panel no longer re-snaps and re-orders itself while a drag is in progress — it used to be lifted back above the System Settings window every 0.4 s, fighting the pass-through that lets the drop land there
- The screenshot path no longer asks ScreenCaptureKit for **off-screen windows**: that made the daemon enumerate and serialize every window and measured 1.1–1.3 s per hotkey press before the overlay could appear. Screenshot and region capture only need displays and applications, so they now request on-screen windows, leaving the full list to window capture
- Selecting an annotation no longer switches the toolbar to that annotation's drawing tool, so picking **Select** and clicking an annotation keeps Select active for the next click
- The text tool now types over an existing annotation instead of letting it swallow the click, and a blank click that merely ends an edit no longer spawns a fresh empty field (which made the box look like it had shrunk)
- Annotations can be moved by dragging the **selection box**: any tool can grab the box border (a move cursor appears), and Select can grab anywhere inside it; text control points resize the font again instead of only moving the annotation

## [0.0.3] — 2026-09-20

### Added
- `Scripts/helper-icon.swift` draws the `Fix Gatekeeper.app` icon (amber tile with a shield check, deliberately distinct from the blue `Jietu.app` tile)

### Changed
- Redesigned the DMG installer window: a 660×420 layout on custom artwork, with fixed positions for `Jietu.app`, `Applications` and `Fix Gatekeeper.app`, centered on screen and without toolbar/status bar
- Install notes are now drawn on the DMG window artwork instead of shipped as a text file
- `Scripts/build-dmg.sh` packages through a writable intermediate image, saves the window geometry / background / icon positions into the image's `.DS_Store`, and verifies the result before reporting size and checksum
- Cut the DMG from 4.2 MB to 2.9 MB (−31%) with no visible change: LZMA (`ULMO`) compression instead of zlib, an alpha-free RGB window backdrop, and a self-drawn icon for `Fix Gatekeeper.app` instead of the 409 KB stock asset catalog `osacompile` ships

### Removed
- `00-请先读我.txt` from the DMG — its install notes moved into the window artwork
- `CONTRIBUTING.md`, and the `Contributing` / `Acknowledgments` sections of the READMEs

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

[Unreleased]: https://github.com/ixxxxoooo/jietu/compare/v0.0.4...HEAD
[0.0.4]: https://github.com/ixxxxoooo/jietu/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/ixxxxoooo/jietu/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/ixxxxoooo/jietu/releases/tag/v0.0.2
[0.0.1]: https://github.com/ixxxxoooo/jietu/releases/tag/v0.0.1
