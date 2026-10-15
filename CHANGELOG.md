# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Online updates.** Settings › About has a new *Software Update* section and the menu bar has *Check for Updates…*. Lucent checks GitHub Releases (automatically at most every 6 hours, or on demand), shows the release notes, and can download, verify and install the new version, then restart itself. Before anything is replaced it verifies the package's SHA-256, its code signature, and that it is signed by the same identity as the installed app — so your Screen Recording permission survives the update. You can skip a version or turn automatic checks off.
- Releases now ship `Lucent-<version>-macOS.zip` (with a `.sha256`) next to the DMG; it is what the in-app updater downloads. Note: the first release that contains it is the first one you can update *to* in-app — earlier versions have to be updated from the DMG once.

## [0.1.1] — 2026-10-16

### Fixed
- **Window capture now captures the window you click.** Clicking a window that was partly covered by another one used to produce an image with the covering window baked in, because the editor cropped the frozen screen photo. The clicked window is now captured on its own (occlusion-free) and swapped into the frozen frame, so what you edit and save is that window only.
- The window under the pointer is resolved from the actual click position (on mouse-down and mouse-up) instead of the last hover state, so a click can no longer pick a stale window when the pointer did not move before clicking.
- Capturing a single window no longer waits for a full off-screen window enumeration (about a second); it looks at on-screen windows first and only falls back to the full list when needed.

### Added
- `--selftest-window` (DEBUG): captures the frontmost windows one by one through the real window-capture path and reports success and size.

## [0.1.0] — 2026-10-16

### Changed
- **Renamed to Lucent (澄影)** — new app name, bundle display name, DMG (`Lucent-<version>.dmg`), menu bar, notifications and documentation. The bundle identifier, code-signing identity and Screen Recording grant are unchanged, so upgrading needs no re-authorization. The default save folder stays `~/Pictures/Jietu` if it already exists (new installs use `~/Pictures/Lucent`), and older `Jietu …` screenshot names are still recognized in history.
- **Requires macOS 27** (built with Xcode 27 / Swift 6.4, approachable concurrency enabled).
- **Liquid Glass everywhere** — the inline annotation toolbar, Quick Access cards, pixel loupe, tooltips, toasts, recording and GIF-export panels, history and settings surfaces now use the native glass material (`glassEffect` / `NSGlassEffectView`); the hand-made frosted material and ink scrim are gone.
- **New app icon** — a layered Icon Composer icon (violet-to-azure gradient, glass viewfinder and lens) and a matching accent color.
- **Recording and GIF export use the macOS 27 AVFoundation receiver / provider APIs** (`AVAssetWriter` input receivers, `AVAssetReader.outputProvider`, typed sample buffers) instead of callback polling.
- **Multi-display capture is concurrent**: every display is frozen in parallel, so selection starts sooner on multi-monitor setups.
- Notifications use async/await `UserNotifications`.

### Fixed
- Background-thread and main-actor hazards in the text-field observers and Quick Access panel (`isolated deinit`, `MainActor.assumeIsolated`), and all Swift 6 strict-concurrency warnings in the codebase.

## [0.0.5] — 2026-10-15

### Added
- Open-source project documents: `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, issue / pull-request templates, and `docs/ARCHITECTURE.md` (layers, capture pipeline, scrolling capture, recording, persistence, permissions and signing)
- `Scripts/check-release.sh` — fails unless every `MARKETING_VERSION` agrees with the top `CHANGELOG.md` entry (and with the pushed tag, when given)
- Unified logging through `os.Logger` (`Log.<category>`, subsystem = bundle identifier), replacing scattered `print` / `NSLog`
- CI hardening: least-privilege workflow permissions, `.xcresult` upload on failure, ShellCheck for `Scripts/*.sh`, a non-blocking SwiftLint pass and Dependabot for GitHub Actions
- Release pipeline: the tag is verified against the project version and changelog and the tests run before packaging; the GitHub Release body comes from this changelog and ships `SHA256SUMS.txt` next to the DMG

### Changed
- The inline editor (`OverlayCanvasView+Inline*`) and the DEBUG self-test scripts (`CaptureSelfTest+*`) were split by responsibility so no file exceeds the ~500-line guideline; behavior is unchanged
- Development notes moved from the old progress log into `docs/ARCHITECTURE.md` and this changelog; `README` hotkey wording now matches the defaults (area capture is ⌃⌘A, the rest start unbound)

### Fixed
- Cancelling a recording while it was still starting could leave the stream running; start and cancel are now serialized
- Stopping a recording reports the real failure instead of always claiming "no frames"
- A recording whose video file could not be moved into history no longer leaves an orphan cover image behind
- Loading a history entry's image falls back to the stored history file when the primary lookup fails
- Global hotkeys unregister their Carbon event handler when the center is released, and ignore hotkey events that are not ours
- Windows without a window number are skipped instead of being treated as window `0`
- Overlays remember the screen they were created for, and the force-unwrapped `NSScreen.main!` fallbacks were replaced by a proper capture-failure path
- Pinned-image callbacks no longer retain the app delegate; floating buttons come back after Live Text is turned off; closing onboarding stops its permission polling; the history card copy-feedback task runs on the main actor

### Removed
- The tracked development log (`开发进度.md`) and `.specstory/` documents; `.specstory/` is now git-ignored

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

[Unreleased]: https://github.com/ixxxxoooo/jietu/compare/v0.0.5...HEAD
[0.0.5]: https://github.com/ixxxxoooo/jietu/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/ixxxxoooo/jietu/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/ixxxxoooo/jietu/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/ixxxxoooo/jietu/releases/tag/v0.0.2
[0.0.1]: https://github.com/ixxxxoooo/jietu/releases/tag/v0.0.1
