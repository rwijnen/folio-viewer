# Folio — notes for Claude

Native macOS viewer for diffs and Markdown, built with SwiftPM (no Xcode project).
Architecture is in `Docs/ARCHITECTURE.md`; contributor rules in `CONTRIBUTING.md`.

## Working on changes

- Always work on a branch (`feature/<name>`, `fix/<name>`, `release/<x.y.z>`), never on `main`.
- Commit as you go; open a PR only when asked.
- Logic goes in `Sources/Folio/Model/` and gets a test in `Tests/FolioTests/`.
- Note user-visible changes under `## [Unreleased]` in `CHANGELOG.md`.

## Build, test, try

```bash
swift build
swift test
./build.sh                # build/Folio.app
./build.sh --install      # replaces /Applications/Folio.app — quit Folio first
```

`swift build` / `swift test` need Xcode's toolchain (`xcode-select -p` →
`/Applications/Xcode.app/Contents/Developer`). The Command Line Tools 26.6 install ships
mismatched SwiftPM and Testing binaries and crashes at launch.

## Releasing

A release follows the version in the bundle, not a tag. **Merging to `main` publishes
nothing unless the version was bumped** — the Release workflow sees the version is already
tagged, logs `vX.Y.Z is already released. Nothing to publish.` and stops (green run, no
release). So after feature PRs land, cut a release explicitly:

1. Branch `release/X.Y.Z` from an up-to-date `main`. Pick the number by SemVer: new
   features → minor, fixes only → patch.
2. `CHANGELOG.md`: insert `## [X.Y.Z] — YYYY-MM-DD` directly under `## [Unreleased]`
   (leave `Unreleased` empty above it), and update the compare links at the bottom:
   `[Unreleased]: …/compare/vX.Y.Z...HEAD` and add `[X.Y.Z]: …/compare/vPREV...vX.Y.Z`.
   The workflow refuses to publish without that heading.
3. `Resources/Info.plist`: set `CFBundleShortVersionString` to `X.Y.Z` and increment
   `CFBundleVersion` by one.
   ```bash
   /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString X.Y.Z" -c "Set :CFBundleVersion N" Resources/Info.plist
   ```
4. `swift test && ./build.sh`.
5. Commit ("Cut X.Y.Z"), push, open the PR `release/X.Y.Z` → `main`.
6. Merge it. The Release workflow (`.github/workflows/release.yml`) builds, tests, tags
   `vX.Y.Z` and publishes the zip + SHA-256. Check with `gh run list --workflow Release`.

To publish a version whose bump already landed, push the tag by hand:
`git tag -a vX.Y.Z -m "Folio X.Y.Z" && git push origin vX.Y.Z` (must match `Info.plist`).
