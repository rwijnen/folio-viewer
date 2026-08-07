# Changelog

All notable changes to Folio are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **The git pill now says whether the file needs committing.** A small coloured dot told
  you something was different without saying what, so you had to open the menu to find
  out. It now reads `main · +12 −3` for a file edited since the last commit, `unsaved`
  for edits still in the editor, `new file`, or `conflict`, and takes a colour to match.
  A file with nothing outstanding stays quiet.

- **Commit is no longer offered when there is nothing to commit.** The menu item was
  always live, the sheet opened on a clean file, and its Commit button would run a commit
  that git then rejected. Three places decided availability for themselves and disagreed;
  they now share one answer. ⌥⌘C, which cannot be disabled without losing its shortcut,
  says why instead of opening a sheet that could only fail. Push does the same when the
  branch has nothing to send.

### Added

- **Folio notices when something else writes a file you have open.** A model, a script or
  another editor changing a document no longer leaves you reading stale text. With no
  unsaved edits of your own it reloads and keeps your place; with unsaved edits it touches
  nothing and offers **See What Changed**, putting your version and the file's side by
  side. Folio's own saves do not trip it, and neither does `touch` or a tool rewriting
  identical bytes — the text is compared, not the timestamp. Automatic reloading can be
  turned off under Document.

### Added

- **A document's history, in the split diff view.** The sidebar switches between Outline
  and History; History lists every commit that touched the open file, newest first, and
  clicking one shows that commit's change side by side — left is the file going in, right
  is the file coming out. It is the same view an opened patch gets, so word-level
  highlighting, collapsible context, ⌘F and scroll memory all come with it. ⌥⌘↑ and ⌥⌘↓
  step between commits without returning to the list. The log follows renames, so work
  done under a previous filename is still there, and the commit that added the file shows
  the whole thing as new. Right-click a commit to copy its hash.

- **Commit and push Markdown from inside Folio.** A document in a git repository gets a
  pill in the header showing the branch, `↑`/`↓` for commits to push and pull, and a
  coloured dot when the file has changes. ⌥⌘C opens a commit sheet; ⌥⌘P pushes. Unsaved
  edits are saved first, because git records what is on disk. Exactly one file is
  committed — anything else you have staged in a terminal stays staged. Push goes only to
  the upstream the branch already tracks: no force, no `--set-upstream`, and no pull,
  rebase or merge. A rejected push is reported with the commit intact. Folio shells out to
  the `git` on your machine, so your config, credential helper, SSH agent, hooks and
  signing key all apply, and it declines to commit with no `user.name`/`user.email`, on a
  detached `HEAD`, on an ignored file, or during an unresolved merge.

- **Markdown can be edited and saved.** Source mode is now a real editor — undo, find,
  line numbers, live syntax colouring — with a Save button and ⌘S. Nothing is auto-saved.
  The tab shows a dot and the header shows *Edited* while there is unsaved work; the
  preview and outline catch up when you switch to the preview or save; closing, quitting
  and reloading all ask before losing anything; and if the file changed on disk since you
  opened it, saving asks before overwriting. Saves are atomic and keep the file's original
  text encoding. Diffs and other text files remain read-only.

- **The outline folds.** Headings nest into a tree, and each section with anything under
  it gets a disclosure triangle: collapse an `H1` and its `H2`s and `H3`s fold away with
  it. The menu at the top of the sidebar folds the whole document to one, two or three
  levels, so a long file's shape fits on one screen without scrolling. ⌥-click a triangle
  to take the whole subtree with it, a folded section shows how many headings it hides,
  the highlight falls back to the nearest visible parent, and what you folded is
  remembered per document between launches.

- An AI-transparency note in the README and SECURITY.md: Folio was vibecoded in Claude
  Code, and every commit carries a `Co-Authored-By: Claude` trailer.

- **Folio reopens where you left off.** The open documents, their order, which one was in
  front, each one's reading mode and scroll position all come back next launch. Files that
  have moved or been deleted are dropped quietly. A document opened from Finder at launch
  joins the restored tabs rather than replacing them.
- **Tabs can be dragged into any order**, and the new order is what gets remembered.

### Fixed

- ⌘F did not open the find bar. Two causes: the menu item asked whether a *diff* was
  loaded, which is never true for a Markdown document, and — the deeper one — a disabled
  menu item swallows its keyboard shortcut while `.disabled(…)` inside `commands` does not
  re-evaluate as state changes. Every menu action now guards itself instead, so ⌘F, ⌘G,
  ⌘R, ⌘W, ⌘1/⌘2, ⌃⇥, ⌘]/⌘[ and ⇧⌘B all fire. ⌘F also re-focuses the field when the bar is
  already open, and Escape closes it.
- Folio's own menu no longer appears as a second **View** menu next to the system one; it
  is now called **Document**.

- Right-clicking a rendered Markdown document and choosing **Reload** did nothing
  visible. The page is an HTML string Folio hands to WebKit, so WebKit's own Reload
  re-rendered the same bytes rather than re-reading the file. The context menu now offers
  **Reload from Disk**, and any reload asked of the web view is redirected to re-read the
  file — including the reload WebKit itself might still put there on a future macOS.
  Reloading keeps the reader's scroll position.
- The rendered page's context menu no longer offers Back, Forward, or any of WebKit's
  download items. There is nothing to navigate, and a viewer that never writes to disk
  should not offer to download.

## [1.0.0] — 2026-08-05

First public release. Folio shows diffs side by side and Markdown either rendered or raw,
in one window with tabs, without ever writing to your files or touching the network.

### Diffs

- Split view with the original on the left and the changed version on the right, rows
  aligned line-for-line, per-side line numbers and filler cells for one-sided changes.
- The changed side is produced by **applying the patch in memory** to the original read
  from disk — nothing is written back.
- Hunks are located by content rather than by line number, so a diff still applies after
  the file has drifted; offsets and whitespace-only matches are reported in a banner.
- **Works from either side.** If the file on disk is the *changed* version — the usual
  case once a patch has been applied — the patch is run backwards to reconstruct the
  original, and a banner says so. If neither direction applies, the hunks are shown on
  their own with `@@` markers rather than failing.
- Intra-line word diff, collapsible runs of unchanged context, and a sidebar listing
  every file in the diff with `+`/`−` counts and add / delete / rename / binary badges.
- Original files are located automatically: a remembered folder per diff, the enclosing
  git working copy, the diff's own folder and its ancestors, then one level of
  subfolders. Overridable per diff (⇧⌘B) or per file.
- Parses `git diff`, `git format-patch`, `diff -u` and `svn diff` output, including
  renames, mode changes, binary stubs and zero-context hunks.

### Markdown

- Rendered view (⌘1) and source view (⌘2), with a heading outline in the sidebar that
  jumps in either mode.
- Markdown is converted to HTML **in Swift**, covering ATX and setext headings, nested
  ordered/unordered/task lists, pipe tables with alignment, blockquotes, fenced and
  indented code, thematic breaks, reference links, images, autolinks, emphasis,
  strikethrough, inline code and hard breaks.
- **mermaid diagrams are drawn**, using mermaid 11.16.1 bundled inside the app, so they
  work with no network access. A diagram that fails to parse shows mermaid's own error
  next to its source rather than disappearing.
- Code fences are highlighted by the same lexer the diff panels use, across ~30
  languages including Swift, TypeScript, Python, Apex, JSON, YAML, XML and SQL.
- Source view highlights Markdown structure and lexes fenced code as the language it
  declares.
- Local images are inlined as `data:` URIs; remote images are reported, never fetched.

### The window

- One window with tabs. Each tab keeps its own reading mode, folds, scroll position and
  search results, and reopening a file that is already open brings its tab forward.
- Returning to a tab resumes exactly where you were, and a rendered page keeps its
  already-drawn diagrams instead of re-drawing them.
- ⌘F searches both diff panels and the source view natively, and the rendered page
  through injected JavaScript; both report `n of m` and step with ⌘G / ⇧⌘G.
- Follows links: to a sibling `.md` or `.diff` in Folio, to your browser for http(s).

### Security posture

- Raw HTML in Markdown is escaped except a whitelist of attribute-free formatting tags.
- `javascript:` and other exotic URL schemes are stripped from links.
- The rendered page runs under a strict `Content-Security-Policy` with a per-load nonce;
  the bundled mermaid bootstrap is the only script that can run.
- No network access at build time or run time.

### Building and installing

- Builds with the **Command Line Tools alone** — no Xcode required. `./build.sh` produces
  an ad-hoc signed `Folio.app` with a generated icon.
- `./build.sh --set-default` installs it and claims `.diff`, `.patch`, `.rej`, `.md`,
  `.markdown`, `.mdown`, `.mkd`, `.mdx` and `.mdc`, then verifies each association by
  asking Launch Services which app would open a probe file.
- 109 tests over the model, tab and scroll layers, run with Swift Testing.

[Unreleased]: https://github.com/rwijnen/folio-viewer/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/rwijnen/folio-viewer/releases/tag/v1.0.0
