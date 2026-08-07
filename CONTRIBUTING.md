# Contributing to Folio

Thanks for looking. Folio is a spare-time project with one maintainer, so the most useful
contributions are small, verified and easy to review.

- [What Folio is, and is not](#what-folio-is-and-is-not)
- [Getting set up](#getting-set-up)
- [The layout of the code](#the-layout-of-the-code)
- [Running the tests](#running-the-tests)
- [Verifying the interface](#verifying-the-interface)
- [A machine without Xcode](#a-machine-without-xcode)
- [Style](#style)
- [Commits and pull requests](#commits-and-pull-requests)
- [Common tasks](#common-tasks)
- [Releasing](#releasing)

## What Folio is, and is not

Three constraints shape every decision, and a change that breaks one of them will not be
merged:

1. **Reading is the default; writing is narrow and explicit.** Diffs are read-only and
   always will be — the patch is applied in memory. Markdown gained an editor, and it may
   write to exactly one file: the one open in that tab, when the reader asks. No
   auto-save, no writing anywhere else. Committing follows the same rule — one file per
   commit, named in the pathspec, leaving anything else the reader has staged alone.
2. **It goes online only when the reader presses Push.** Nothing at build time, and
   nothing else at run time: no telemetry, no update check, no remote images or fonts.
   mermaid is vendored for exactly this reason. Push is the single exception and must
   stay a deliberate, visible action; a feature that opens a connection on its own will
   not be merged.
3. **It does not execute what it renders.** Markdown is escaped except for a whitelist of
   attribute-free formatting tags, and the rendered page runs under a strict CSP.

Beyond that: it favours being *correct about diffs* over being feature-rich, and itÓ
prefers native Swift over adding dependencies. There is exactly one third-party component
in the project and adding a second needs a good argument.

## Getting set up

```bash
git clone https://github.com/rwijnen/folio-viewer.git
cd folio-viewer
swift build          # compile
swift test           # 286 tests, ~15 seconds
./build.sh           # assemble build/Folio.app
open -a build/Folio.app Samples/example.md
```

You need macOS 14+ and a Swift 6 toolchain. **Xcode is optional** — the Command Line
Tools are enough for everything including the app bundle and the icon.

## The layout of the code

```
Sources/Folio/
  Model/      pure logic, no UI, all of it unit-tested
    DiffParser              unified diffs → [FileDiff]
    PatchApplier            applies (and reverses) hunks, located by content
    SideBySideDocument      alignment into rows, folds, filler cells
    WordDiff                token LCS for intra-line highlighting
    SyntaxHighlighter       one-pass lexer, carries state across lines
    LanguageSpec            the ~30 language definitions and the fence-info mapping
    MarkdownConverter       Markdown → HTML, outline, diagram detection
    MarkdownSyntax          Markdown highlighting for source mode
    Git                     runs `git` as a subprocess: environment, pipes, timeouts
    GitRepository           the handful of git commands Folio needs, as typed calls
    GitHistory              reading the log, and one commit's change to one file
    LineDiff                the only diff Folio computes rather than reads
    FileWatcher             tells you when something else writes an open file
    PathResolver            works out which folder a diff's paths belong to
    TextNormalizer          line splitting, tab expansion, encoding tolerance
  State/
    DocumentTab             everything belonging to ONE open document
    AppState                the open tabs, shared find bar, window preferences
    DiffPreparation         reads the original, applies the patch, builds the document
    TextDocumentLoading     opening Markdown/source, page callbacks, reading modes
    Editing                 drafts, saving, the prompts before anything is lost
    GitIntegration          status refresh, commit, push, and what the buttons may offer
    GitHistoryLoading       the history list and showing one commit in the pane
    ExternalChanges         what to do when a file changes underneath a tab
  Views/
    ContentView             tab bar + sidebar + detail
    TabBar                  the strip of open documents
    SplitDiffView           the two panels, headers, banners
    DiffRowView             one aligned row
    SourceListingView       single-column source with line numbers
    DocumentView            Markdown/source pane, mode switch, outline sidebar
    GitStatusView           the branch pill in the header and the commit sheet
    HistorySidebar          the Outline/History switch, the commit list, the commit pane
    ExternalChangeView      the "changed on disk" bar and its side-by-side view
    MarkdownWebView         container for the rendered page
    MarkdownPageController  owns one document's live WKWebView
    HTMLPage                the page template: CSS, CSP, find and diagram scripts
    ScrollOffsetKeeper      AppKit bridge that gives scroll views their memory
    LineRenderer            syntax + word diff + search → AttributedString
    FindBar, Theme, FileListView
Sources/Register/           folio-register, the fallback default-handler tool
Tools/make-icon.swift       draws the icon with Core Graphics
```

[Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) explains why the interesting pieces are
built the way they are — read that before a structural change.

The rule of thumb: **logic belongs in `Model/`, where it can be tested**. Views should
assemble and display, not compute.

## Running the tests

```bash
swift test                                   # everything
swift test --filter MarkdownBlockTests       # one suite
swift test --filter rendersPipeTables        # one test
```

Tests use [Swift Testing](https://developer.apple.com/documentation/testing) (`@Test`,
`#expect`, `#require`), not XCTest — deliberately, since XCTest is unavailable without
Xcode.

The git suites build throwaway repositories under the temporary directory and run the
real `git` against them, including pushes between two local repositories — no network is
involved. They set `GIT_CONFIG_GLOBAL=/dev/null` so your own `~/.gitconfig` cannot decide
whether they pass; keep that up if you add one. They skip themselves if `/usr/bin/git` is
missing.

Two suites drive AppKit and WebKit directly (`ScrollOffsetKeeperTests`,
`ScrollMemoryTests`). If you are on a machine or CI runner without a GUI session, skip
just those:

```bash
FOLIO_SKIP_UI_TESTS=1 swift test
```

**New behaviour needs a test.** If it lives in `Model/`, that is straightforward. If it
lives in a view, look for the seam: most view logic worth testing can be moved into a
model type or a small `@MainActor` class, as `ScrollOffsetStore` was.

## Verifying the interface

Please do not send a UI change with "looks right to me" as the only evidence. Two
techniques in this repo let you actually look at the result, both of which work
headlessly:

**SwiftUI views** — render them offscreen with `ImageRenderer`. Note that `ScrollView`,
`List` and other AppKit-backed views come out blank, so rasterise the inner row or content
stack instead. The screenshots in `Docs/` were produced this way and are labelled as such.

**The rendered Markdown page** — put the `WKWebView` in an offscreen `NSWindow`
(`alphaValue = 0`, `orderBack`) and call `takeSnapshot`. This needs no screen-recording
permission and captures fully rendered JavaScript, diagrams included. Grow the web view
to `document.body.scrollHeight` first to capture the whole page, and pump
`RunLoop.current.run(mode:before:)` rather than blocking on a semaphore, because WebKit's
callbacks arrive on the main queue.

**Menus** — `Folio --dump-menu path/to/file.md` prints every menu item with its key
equivalent and whether it is enabled. Menus are worth checking explicitly, because a
disabled item silently swallows its keyboard shortcut: that is how ⌘F went missing for
Markdown. Note the app needs a moment to activate first — dumping too early reports
everything as disabled, which is a property of the diagnostic, not of the app.

There is deliberately **no `.disabled(...)` in the `commands` block**. Those predicates
were measured not to re-evaluate reliably, leaving shortcuts permanently dead; each menu
action guards itself instead.

`CGWindowListCopyWindowInfo` needs no permission either and is enough to check that a
window exists with the right title and size. It reports more than one entry per window, so
count distinct bounds if you are counting windows.

## Style

Match the surrounding code; there is no formatter to run.

- Four-space indentation, ~96 column soft limit.
- Full words for names: `originalIndex`, not `origIdx`. Types are nouns, functions are
  verbs.
- `// MARK: -` sections in anything over about 100 lines.
- **Comments explain why, not what.** The codebase has a lot of "this is not the obvious
  approach, and here is the reason" comments — for instance why the live-page cap is
  enforced at creation, or why `<style>` inside an SVG must be excluded from search.
  Those are the valuable ones. Do not narrate the code.
- British spelling in prose is used throughout, including in comments.
- No new dependencies without discussing it first.

## Commits and pull requests

**Nothing is committed straight to `main`.** Every change — features, fixes, even
documentation — goes on a branch and reaches `main` through a pull request, so there is
always a diff to read and a green CI run before anything lands.

```bash
git switch main && git pull
git switch -c feature/what-it-does      # or fix/… or docs/…
# work, commit
git push -u origin feature/what-it-does
gh pr create --base main --fill
```

- One concern per pull request. A refactor and a feature in the same diff is hard to
  review.
- Commit subjects in the imperative, under ~72 characters:
  `Keep the scroll position when switching tabs`.
- Explain the *why* in the body when it is not obvious.
- Fill in the pull request template's **How it was verified** section honestly, including
  what you did not check. "I could not test the Finder association because …" is a
  perfectly good answer; a false claim is not.
- CI must be green: build, tests, and a bundle check on macOS.

## Common tasks

**Add a language for syntax highlighting.** Add a `LanguageSpec` in
`Model/LanguageSpec.swift`, wire its extensions into `spec(forPath:)` and its fence names
into `spec(forFenceInfo:)`. The lexer is shallow by design — keywords, strings, comments,
numbers — so a spec is usually 15 lines. Add a case to the extension-mapping test.

**Add Markdown support for something.** Block constructs go in
`MarkdownConverter.Builder.blocks`, inline ones in `inline`. Order matters in `inline`:
code spans are lifted out first, then everything is escaped, then tags are generated. Add
a test in `MarkdownTests.swift` — there is one per construct already.

**Change the rendered page's look.** `HTMLPage.stylesheet`. It is driven by CSS variables
with a `data-theme` attribute set from the app's appearance, so any colour you add needs
both a light and a dark value.

**Touch the icon.** `Tools/make-icon.swift`, pure Core Graphics. Palette constants are at
the top. Always check the 16 and 32 pixel variants: the drawing takes a different, much
simpler path below 32 pixels, because detail turns to mush there.

**Add a git command.** Think hard first — the charter above is the reason there are only
two write paths. Reading is fine. If you do add one, it goes in `GitRepository` as a typed
call, never as a string a caller assembles, and it takes no argument that could widen what
it touches. Add a test that arranges the repository state and asserts on what git did
afterwards, not on what Folio said.

**Change how a default handler is claimed.** `FileAssociation` in `App/FolioApp.swift`,
with `Sources/Register/main.swift` as the fallback. Both verify by probing Launch Services
afterwards, with retries — the binding lands asynchronously and the calling process caches
the old answer, which produced a convincing false negative before the retries existed.

## Releasing

1. Update `CHANGELOG.md` — move items out of *Unreleased* into the new version.
2. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
3. `swift test && ./build.sh` one more time.
4. Tag and push: `git tag -a v1.1.0 -m "Folio 1.1.0" && git push origin v1.1.0`.

The release workflow builds the app, runs the tests, and attaches a zip plus its SHA-256
to a GitHub release. The artifact is ad-hoc signed and not notarised, and the release notes
say so.
