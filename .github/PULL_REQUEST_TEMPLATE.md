## What this changes

<!-- One or two sentences. If it fixes an issue, add "Fixes #123". -->

## How it was verified

<!--
Please be specific, and honest about what you did not check. For example:
- `swift test` — all suites pass
- Opened Samples/example.md and stepped through both reading modes
- Rendered the view offscreen (see CONTRIBUTING.md) and looked at the result
-->

- [ ] Changes `Sources/` or `Resources/`? Then this PR bumps the version in
      `Resources/Info.plist` and adds its `## [X.Y.Z]` CHANGELOG heading, or merging
      publishes nothing (CI's *Version bump* check enforces it)
- [ ] `swift test` passes
- [ ] `./build.sh` produces a working app bundle
- [ ] Checked the behaviour in the running app, or explained below why not

## Notes for the reviewer

<!-- Trade-offs, things you were unsure about, follow-up work you left out. -->
