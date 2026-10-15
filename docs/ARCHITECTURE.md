# Architecture

Lucent (formerly *Jietu*; the Xcode target, Swift module and source root keep the original codename) is a menu-bar (`LSUIElement`) macOS app written in Swift 6 with AppKit and SwiftUI. It targets macOS 27+ and has **no third-party dependencies** — everything is built on system frameworks (ScreenCaptureKit, Vision, AVFoundation, Carbon hot keys, Translation).

This document explains how the code is organized and why. For build and contribution steps see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Layers

```
App/ (lifecycle, wiring)  →  Overlay/ (capture overlay)  and  UI/ (resident interface)  →  Core/ (UI-free domain logic)
```

Dependencies only point along the arrows:

- **`Core/`** never imports the interface layers. It is organized by domain (`Annotation`, `Capture`, `History`, `Hotkeys`, `ImageIO`, `Notifications`, `OCR`, `Permissions`, `Recording`, `Scrolling`, `Settings`, `Logging`, `Diagnostics`).
- **`UI/`** talks to `Core/` through its public types, never through its internals.
- **`UI/DesignSystem/`** is the single source of UI style (`Theme` tokens, `.floatingSurface()`, glass controls). New UI must not hard-code colors, radii or shadows.
- **`App/`** (`AppDelegate` + `+Capture`, `+Recording`, `+Scrolling`, `+Delivery`, `+VideoTools`) only wires things together and owns the app lifecycle.

Large types are split into a main file (lifecycle and assembly) plus `+Feature` extensions, one feature area per file (for example `OverlayCanvasView` + `+Selection`, `+Zoom`, `+InlineMouse`, `+InlineToolbar` …). Soft limit is ~500 lines per file.

## Capture pipeline

1. A hotkey (Carbon `RegisterEventHotKey`, no Accessibility permission needed) or a menu item starts a capture.
2. `CaptureEngine` freezes **every display** — concurrently, one task per display — with ScreenCaptureKit into a `DisplaySnapshot` (pixels + scale + geometry). Only displays and applications are requested; the on-screen window list is read separately (`WindowHitTester`) because enumerating off-screen windows costs ~1 s.
3. `OverlayCoordinator` puts one borderless overlay window (`OverlayWindowController` → `OverlayCanvasView`) on each display. The user drags a region, or clicks a snapped window.
4. In the default **inline editing** mode the overlay stays up and shows `InlineAnnotationToolbar` under the selection. All editing (new capture, Quick Access card, pinned image, history item) goes through this one editor.
5. On confirm, `AnnotationRenderer` bakes the annotations into the cropped image and `AppDelegate+Delivery` hands the result to the clipboard, disk (`CaptureOutput`), Quick Access card, history (`HistoryStore`) and notifications.

Coordinates are the main source of bugs, so each space has a dedicated helper: `DisplayGeometry` converts between AppKit "local" points (origin bottom-left), CoreGraphics points (origin top-left) and pixels; `SelectionGeometry` handles selection math. Annotation geometry is stored in **image pixels with a top-left origin**, independent of the screen.

## Annotations

Annotations are objects (`Annotation` + `AnnotationKind`), not pixels, so they stay editable (move, resize, rotate, re-style) until the image is exported. `AnnotationGeometry` provides hit-testing and handles; `AnnotationRenderer` (+ `Arrows`, `BrushText`, `BlockEffects`) is the only code that draws them, so the preview and the exported image use the same path. Undo/redo snapshots the annotation list.

## Scrolling capture

`ScrollingCaptureSession` samples the selected region repeatedly while the content scrolls (manually, or with synthetic wheel events from `AutoScroller`). `ScrollStitcher` aligns consecutive frames with row signatures, using a Vision translation estimate when the expected step is unknown, and `ScrollStitcherSession` accumulates the long image. Auto-scroll needs the Accessibility permission (`CGEvent.post` is silently dropped without it); without it the session falls back to manual scrolling.

## Recording

`RecordingEngine` drives an `SCStream` and writes frames through `RecordingWriter`, which uses the macOS 27 AVFoundation receiver model (`AVAssetWriter.inputPixelBufferReceiver` / `inputReceiver`, strongly typed `CMReadySampleBuffer`) instead of `requestMediaDataWhenReady` + `isReadyForMoreMediaData`; the timeline and pause state live behind `Synchronization.Mutex`. Pausing drops frames and shifts later timestamps, so the paused span never appears in the file. System audio comes from the stream; the microphone is captured independently (`MicrophoneRecorder`) and written to a separate track. Finished recordings land in the history directory first; saving elsewhere is a copy. `GifExporter` (reads frames through `AVAssetReader.outputProvider`) and `VideoTrimmer` post-process finished videos.

## Persistence

- Preferences: `SettingsStore` (`UserDefaults`, injectable for tests).
- History: `HistoryStore` keeps PNG/MP4 files plus a JSON index under `Application Support/<bundle id>/History`, capped by count and total size.
- Nothing is uploaded. All processing is local.

## Permissions and signing

- **Screen Recording** is required. TCC ties the grant to the app's *code-signing identity*. Releases are signed with one stable self-signed certificate (`Jietu`), so the designated requirement is `identifier + certificate leaf` and survives upgrades. An ad-hoc signature would reduce it to a per-build `cdhash` and force users to re-authorize on every update — `Scripts/build-dmg.sh` refuses to produce such a build unless `JIETU_ALLOW_ADHOC=1`.
- **Accessibility** is optional (auto-scroll only) and is read live, so no restart is needed after granting.
- Because the app is self-signed (no Developer ID / notarization), the first launch needs the quarantine flag removed; the DMG ships a copyable note for that.

## Build channels

| | Debug | Release |
|---|---|---|
| Product | `Lucent Dev` | `Lucent` |
| Bundle ID | `com.ixxxxoooo.jietu.dev` | `com.ixxxxoooo.jietu` |
| Output | `.build/Build/Products/Debug/Lucent Dev.app` | `…/Release/Lucent.app` |

The channels are independent: separate TCC grants, preferences and login items. Debug builds must keep `ENABLE_DEBUG_DYLIB = NO`, otherwise the main executable is a tiny shell and TCC cannot resolve a stable identity.

Each channel runs a single instance (`AppDelegate.handOffToExistingInstance()`); do not launch with `open -n`.

## Testing

- **Unit tests** (`JietuTests/`, Swift Testing) — one test file per source file, shared scaffolding only in `JietuTests/TestSupport/`. See [`JietuTests/COVERAGE.md`](../JietuTests/COVERAGE.md) for the source → test matrix.
- **Self-tests** (`Core/Diagnostics/`, DEBUG builds only) — real-window checks driven from the command line, for what unit tests cannot reach (overlay timing, injected mouse events, recording, scrolling). Run the Debug binary with `--selftest-<name>`; each prints `RESULT: PASS|FAIL`. They need Screen Recording permission and a real display.
- **Release consistency** — `Scripts/check-release.sh` (and `ReleaseConsistencyTests`) verify the project version, the top `CHANGELOG.md` entry and the git tag agree.

## UI design system

Rules from `UI/DesignSystem/` (Liquid Glass, macOS 27):

1. **Floating surfaces are native Liquid Glass.** SwiftUI uses `.glassEffect(_:in:)` (wrapped by `.floatingSurface()`); AppKit uses `NSGlassEffectView` (wrapped by `NSGlassEffectView.floatingSurface(cornerRadius:content:)`). There is no hand-made frosted material or ink scrim any more.
2. **No glass on glass.** A glass panel hosts content, never another glass layer; controls inside a panel use plain fills from the ink ramp.
3. One alpha ramp of ink (white on dark, black on light); secondary text, separators and control fills all come from it.
4. Floating bars are transparent layers above the content, not window chrome.
5. Glass is for floating controls and panels; the settings window uses the native split view and unified toolbar, and lets the system draw its material.

All tokens live in `Theme.swift`.
