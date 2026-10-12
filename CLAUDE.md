# Folio — notes for Claude

Native macOS viewer for diffs and Markdown, built with SwiftPM (no Xcode project).
Architecture is in `Docs/ARCHITECTURE.md`; contributor rules in `CONTRIBUTING.md`.

## Working on changes

- Always work on a branch (`feature/<name>`, `fix/<name>`), never on `main`.
- Commit as you go; open a PR only when asked.
- Logic goes in `Sources/Folio/Model/` and gets a test in `Tests/FolioTests/`.
- **Every PR that changes `Sources/` or `Resources/` is a release** — it bumps the version
  and adds its CHANGELOG heading itself (see Releasing). CI's *Version bump* check fails
  the PR otherwise. Docs-, test- and CI-only PRs need no bump.

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

A release follows the version in the bundle, not a tag: merging to `main` publishes only
when `CFBundleShortVersionString` names a version with no tag yet. Feature and fix PRs used
to land without the bump and the Release workflow then logged `vX.Y.Z is already released.
Nothing to publish.` (a green run, no release) — three in a row went out that way. So the
bump is part of the PR that changes the app, not a separate step afterwards.

In every PR that changes `Sources/` or `Resources/`, before committing the last change:

1. Pick the version by SemVer against `main`: fix only → patch, new feature → minor,
   breaking → major. If `main` moved while the PR was open, re-check it is still above
   `main`'s version.
2. `CHANGELOG.md`: put this PR's entries under a new `## [X.Y.Z] — YYYY-MM-DD` heading
   directly under `## [Unreleased]` (leave `Unreleased` empty), and update the compare
   links at the bottom: `[Unreleased]: …/compare/vX.Y.Z...HEAD` and add
   `[X.Y.Z]: …/compare/vPREV...vX.Y.Z`.
3. `Resources/Info.plist`: set `CFBundleShortVersionString` to `X.Y.Z` and increment
   `CFBundleVersion` by one.
   ```bash
   /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString X.Y.Z" -c "Set :CFBundleVersion N" Resources/Info.plist
   ```
4. `.github/scripts/check-version-bump.sh main` — the same check CI runs; it must end with
   `Merging this publishes Folio X.Y.Z.`
5. `swift test && ./build.sh`, then commit and push.
6. After the merge, confirm the release went out: `gh run list --workflow Release` and
   `gh release view vX.Y.Z`. A run of ~15 s means nothing was published.

To publish a version whose bump already landed, push the tag by hand:
`git tag -a vX.Y.Z -m "Folio X.Y.Z" && git push origin vX.Y.Z` (must match `Info.plist`).
