# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Internationalization (i18n) — English & Simplified Chinese, auto-detected from system language
- English README.md and Chinese README_zh-CN.md
- GitHub Actions CI/CD — automatic build, test, and release on tag push
- CONTRIBUTING.md, LICENSE (MIT), CHANGELOG.md
- Installation instructions in DMG release notes

### Changed
- All UI strings now go through centralized `L10n` localization layer
- Info.plist permission descriptions are localized

## [1.0.0] — 2026-09-19

### Added
- Area, window, full screen, timed, and scrolling capture
- Screen recording with system audio + microphone, pause/resume
- Object-based annotation: rectangle, ellipse, arrow, line, pen, highlighter, spotlight, pixelate, blur, text, counter, eraser, crop
- Inline editing directly on capture overlay
- Live Text (OCR) with text selection and copy
- macOS Translation framework integration
- Pin to screen with drag-resize and scroll-zoom
- Color picker with magnifier and hex copy
- 8 customizable global hotkeys
- Theme support: system / light / dark
- Recent history for screenshots and recordings
- Post-recording trim and GIF export
- Multi-display support
- Launch at login

[Unreleased]: https://github.com/ixxxxoooo/jietu/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/ixxxxoooo/jietu/releases/tag/v1.0.0
