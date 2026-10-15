# Contributing to Lucent

Thanks for your interest in Lucent! Bug reports, fixes, translations and small features are all welcome. Please read [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) first, and see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the code is organized.

## Before you start

- **Bugs**: open an issue with the bug template (macOS version, Lucent version, permission state, steps).
- **Features**: open an issue first for anything larger than a small tweak, so we can agree on the approach before you invest time.
- **Security problems**: do not open a public issue — see [SECURITY.md](SECURITY.md).

## Development setup

Requirements: macOS 27+, Xcode 27+ (Swift 6.4). There are no package dependencies.

```bash
git clone https://github.com/ixxxxoooo/jietu.git
cd jietu

# Build the Debug channel ("Lucent Dev.app", separate bundle ID from the release app)
xcodebuild -project Jietu.xcodeproj -scheme Jietu -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build build

# Build, relaunch and verify the running process is the fresh build
bash Scripts/restart-dev.sh
```

### Signing

Keep the project's default signing settings. Screen Recording is granted per code-signing identity, and building with `CODE_SIGNING_ALLOWED=NO` (or ad-hoc) throws the grant away on every build. If you have no `Jietu` certificate, run `bash Scripts/generate-signing-cert.sh` once to create a local self-signed one. Contributors without it can still build and run the unit tests with `CODE_SIGN_IDENTITY="-"`, which is what CI does.

### Permissions

The Debug app shows up as **Lucent Dev** in *System Settings › Privacy & Security › Screen & System Audio Recording*. Use the menu-bar item "Drag to authorize Screen Recording…" if it is not listed. Accessibility is optional and only needed for auto-scroll.

## Tests

```bash
xcodebuild -project Jietu.xcodeproj -scheme Jietu -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build test
```

- New behavior needs a unit test; a bug fix needs a regression test.
- **One test file per source file**, named after it (`FooBar.swift` → `FooBarTests.swift`). Keep test files under ~700 lines.
- Shared fixtures (`TestImage`, `TestUserDefaults`, synthetic events, …) live **only** in `JietuTests/TestSupport/` — do not redefine them in test files.
- Update the source → test matrix in [`JietuTests/COVERAGE.md`](JietuTests/COVERAGE.md) when you add or move tests.
- UI behavior that unit tests cannot reach has DEBUG-only self-tests (`--selftest-*`, see `Jietu/Core/Diagnostics/`). Run the relevant ones when you change overlay, recording or scrolling code.

## Code style and organization

- **File size**: aim for ≤ ~500 lines per file; split at ~400. Types under ~50 lines can share a file; otherwise one type per file. Split large types into `Type.swift` + `Type+Feature.swift` extensions.
- **Layers**: `App/ → Overlay/ and UI/ → Core/`. `Core/` must not import interface code.
- **UI style comes only from `UI/DesignSystem/`** (`Theme` tokens, `.floatingSurface()`, glass components). Do not hard-code colors, radii or shadows.
- **Strings**: every user-visible string goes through `L10n` and both `en.lproj` and `zh-Hans.lproj` `Localizable.strings` — keys must exist in both.
- **Logging**: use `Log.<category>` (`os.Logger`); no `print` / `NSLog` in app code.
- **No duplication**: extract a shared helper instead of copy-pasting. Delete dead code instead of commenting it out.
- Source comments are written in Chinese in this repository; English comments are fine in new code too — match the file you are editing.

## Commits and pull requests

- Commit messages are in **English**, using a Conventional-Commits-style prefix: `feat:`, `fix:`, `change:`, `refactor:`, `test:`, `docs:`, `ci:`, `chore:`. Keep the subject short and describe *why* in the body when it is not obvious.
- Keep PRs focused. Fill in the PR template, and make sure:
  - the build succeeds and **all tests pass**;
  - new strings exist in both languages;
  - `CHANGELOG.md` has an entry under the unreleased/next version for user-visible changes.
- CI (`Build & Test` on macOS 27) must be green before review.

## Releasing (maintainers)

1. Bump `MARKETING_VERSION` (all four build configurations in `Jietu.xcodeproj`) and add a `## [x.y.z] — YYYY-MM-DD` section at the top of `CHANGELOG.md`.
2. Run `bash Scripts/check-release.sh` — it fails unless the project version and the top changelog entry agree.
3. Merge to `main` once CI is green, then tag: `git tag vX.Y.Z && git push origin vX.Y.Z`.
4. The `Release` workflow verifies the tag against the project version, runs the tests, builds and signs the DMG with `Scripts/build-dmg.sh`, writes `SHA256SUMS.txt`, and publishes a GitHub Release whose notes come from `CHANGELOG.md`.

The signing certificate is created **once** (`Scripts/generate-signing-cert.sh`) and exported to the repository secrets (`Scripts/export-signing-cert.sh --upload`). Never regenerate it or change the release bundle ID: that changes the designated requirement and every user would have to re-authorize Screen Recording.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
