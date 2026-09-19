# Contributing to Jietu

Thank you for your interest in contributing! Here's how to get started.

## Development Setup

1. **Clone the repo**

   ```bash
   git clone https://github.com/ixxxxoooo/jietu.git
   cd jietu
   ```

2. **Requirements**
   - macOS 26+ (Tahoe)
   - Xcode 26+ / Swift 6

3. **Build & Run**

   ```bash
   # Debug build (Jietu Dev.app — separate bundle ID)
   xcodebuild -project Jietu.xcodeproj -scheme Jietu -configuration Debug \
     -destination 'platform=macOS' -derivedDataPath .build build

   # Or use the convenience script
   bash Scripts/restart-dev.sh
   ```

4. **Grant permissions** to `Jietu Dev.app`:
   - Screen Recording (required)
   - Accessibility (optional, for scrolling capture)

## Code Guidelines

- **Language**: Code and comments in English; commit messages use [Conventional Commits](https://www.conventionalcommits.org/) in English.
- **File size**: Keep files under ~500 lines. Split large types using `+Extension` files.
- **Architecture**: `App/ → Overlay/ & UI/ → Core/`. Core never imports UI layers.
- **Design system**: All styling goes through `UI/DesignSystem/` tokens. No hardcoded colors/shadows.
- **Dead code**: Remove it. Don't comment it out "for later."

## Testing

- One source file → one test file, with matching names.
- Shared test helpers go in `JietuTests/TestSupport/`.
- Run tests:

  ```bash
  xcodebuild -project Jietu.xcodeproj -scheme Jietu -configuration Debug \
    -destination 'platform=macOS' test
  ```

## Pull Request Process

1. Fork the repo and create a feature branch from `main`.
2. Make your changes, ensuring builds succeed and tests pass.
3. Write a clear PR description explaining **what** and **why**.
4. One approval required before merging.

## Commit Convention

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add new annotation tool
fix: correct selection offset on Retina displays
change: rename EditorMode.window to quickAccess
docs: update architecture diagram
test: add unit tests for CropTool
refactor: extract AnnotationRenderer from OverlayCanvasView
```

## Reporting Issues

- Use [GitHub Issues](https://github.com/ixxxxoooo/jietu/issues).
- Include macOS version, steps to reproduce, expected vs. actual behavior.
- Screenshots or screen recordings are very helpful.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
