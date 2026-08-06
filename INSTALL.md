# Installing Folio

Folio is a small macOS app with no installer and no dependencies to fetch. Building it
from source takes about ten seconds and is the recommended route, because it sidesteps
Gatekeeper entirely.

- [Requirements](#requirements)
- [Build from source](#build-from-source)
- [Install it](#install-it)
- [File associations](#file-associations)
- [Using a downloaded release](#using-a-downloaded-release)
- [Updating](#updating)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)

## Requirements

| | |
|---|---|
| macOS | 14 (Sonoma) or later |
| Toolchain | Swift 6 — the **Command Line Tools are enough**, Xcode is not needed |
| Disk | ~6 MB for the installed app |
| Network | None, ever — not to build, not to run |

If you do not have a toolchain yet:

```bash
xcode-select --install
```

That gives you `swift`, `codesign` and `iconutil`, which is everything `build.sh` uses.
Check it worked:

```bash
swift --version   # expect 6.x
```

Folio is written against SwiftUI, AppKit and WebKit, all of which ship inside the Command
Line Tools SDK — see [CONTRIBUTING.md](CONTRIBUTING.md#a-machine-without-xcode) if you are
curious how a full app is built without Xcode.

## Build from source

```bash
git clone https://github.com/rwijnen/folio-viewer.git
cd folio-viewer
./build.sh
```

That produces `build/Folio.app`: ad-hoc signed, with a generated icon, and with mermaid
bundled inside it. Try it before installing:

```bash
open -a build/Folio.app Samples/example.md      # Markdown, three diagrams
open -a build/Folio.app Samples/example.diff    # a real git diff and the files it applies to
```

## Install it

```bash
./build.sh --install
```

Copies the app to `/Applications` — falling back to `~/Applications` if that is not
writable — and registers it with Launch Services so it appears in Finder's *Open With*.

To also make Folio the default app for everything it handles:

```bash
./build.sh --set-default
```

This claims `.diff`, `.patch`, `.rej`, `.md`, `.markdown`, `.mdown`, `.mkd`, `.mdx` and
`.mdc`, then **verifies each one** by asking Launch Services which app would open a probe
file, and prints a line per extension:

```
  ✓ .diff opens with Folio.app
  ✓ .md opens with Folio.app
  …
```

The app launches for a second during this step and quits by itself: Launch Services' API
for setting a default handler only answers from inside a registered app bundle, so the
install step borrows the app to make the call. A brief window flash is expected.

## File associations

If you would rather claim one family and not the other, the **View** menu has
*Set Folio as Default for Diffs* and *Set Folio as Default for Markdown*.

To hand a file type back to another app: select a file of that type in Finder, press ⌘I,
open **Open with**, choose the app and click **Change All…**.

Two things are worth knowing if an association refuses to stick:

- Extensions like `.mdown`, `.mkd`, `.mdx` and `.mdc` have **no system content type** —
  they resolve to dynamic `dyn.…` identifiers — so each extension has to be claimed
  individually rather than through one shared UTI. Folio does this.
- An editor that claims a raw *extension* outranks an app that only claims the *UTI*.
  Folio declares both, at `LSHandlerRank: Owner`.

## Using a downloaded release

Release builds are **ad-hoc signed, not notarised** — this project has no paid Apple
Developer certificate. macOS will therefore refuse to open a downloaded build until you
clear the download quarantine:

```bash
unzip Folio.app.zip -d /Applications
xattr -dr com.apple.quarantine /Applications/Folio.app
open /Applications/Folio.app
```

Or, without the terminal: right-click the app in Finder, choose **Open**, and confirm the
warning once. macOS remembers the decision.

Verify what you downloaded against the published checksum:

```bash
shasum -a 256 Folio.app.zip   # compare with Folio.app.zip.sha256 from the release
```

If an unverifiable publisher is not acceptable to you, build from source instead. The
result is identical and carries your own ad-hoc signature.

## Updating

```bash
git pull
./build.sh --install
```

Settings are kept in `UserDefaults` under `com.robinwijnen.Folio` and survive a reinstall.
Folio stores two things only: which folder a given diff's originals were found in, and the
session — the documents that were open, their order, and where you were in them.

## Uninstalling

```bash
rm -rf /Applications/Folio.app
defaults delete com.robinwijnen.Folio 2>/dev/null || true
```

Then hand the file types back to your editor of choice with ⌘I → **Open with** →
**Change All…**, as above. Folio writes nothing else anywhere: no caches, no support
folder, no login items.

## Troubleshooting

**`xcodebuild: error: tool 'xcodebuild' requires Xcode`**
You do not need `xcodebuild`, and `build.sh` never calls it. If something else on your
machine does, this message is unrelated to Folio.

**`./build.sh: Permission denied`**
`chmod +x build.sh`.

**The icon did not build**
`build.sh` prints `skipped (icon generation unavailable — the app still builds)` and
carries on. The app works; only the icon is missing. It needs `iconutil`, which ships with
the Command Line Tools.

**`WARNING: Resources/Web/mermaid.min.js missing`**
The vendored mermaid bundle is not in your checkout — likely a partial clone or a
downloaded source archive that skipped it. Diagrams will show their source with an
explanation instead of rendering. Re-clone, or fetch the file recorded in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) to that path.

**A diff shows "the file on disk looks like a different revision"**
Folio tried the patch forwards and backwards and neither applied, so the file on disk is
neither the original nor the changed version. It falls back to showing the hunks alone.
Point it at the right file with **Locate Original…**, or at the right folder with ⇧⌘B.

**A diff says the originals could not be found**
Diff paths are relative, so Folio has to guess the folder they belong to. Set it with
⇧⌘B — the choice is remembered for that diff.

**Diagrams do not appear**
A banner will say why. If it mentions mermaid failing to parse, the diagram's own source
is shown underneath with mermaid's error message — usually a syntax problem in the
diagram, not in Folio.

**Nothing above matches**
[Open an issue](https://github.com/rwijnen/folio-viewer/issues/new/choose) with your macOS
version, how you installed, and a small sample of the file that misbehaved.
