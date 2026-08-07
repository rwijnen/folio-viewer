import Foundation

/// Noticing when something else writes the file you have open.
///
/// The case this is built for: a model rewrites a note while Folio is showing it. Before
/// this, the reader saw stale text until they happened to press ⌘R, and if they had typed
/// anything the first sign of trouble was the overwrite warning at save time — by which
/// point they had to choose between two versions without being able to see either.
///
/// The rule is that Folio never discards work. A document with no unsaved edits is
/// reloaded, because showing text that is no longer in the file is worse than moving it
/// under the reader. A document with edits is never touched; it says what happened and
/// offers to show the difference.
extension AppState {

    // MARK: - Watching

    /// Starts watching a document's file. Safe to call more than once for a tab.
    func startWatching(_ tab: DocumentTab) {
        guard tab.textDocument != nil, tab.watcher == nil else { return }
        let id = tab.id
        tab.watcher = FileWatcher(url: tab.url) { [weak self] in
            // The watcher reports from its own queue, and says only that something
            // happened; whether anything actually differs is decided on the main actor,
            // by reading the file.
            Task { @MainActor in self?.fileChangedOnDisk(tabID: id) }
        }
    }

    func stopWatching(_ tab: DocumentTab) {
        tab.watcher?.cancel()
        tab.watcher = nil
    }

    // MARK: - Reacting

    /// Called when the watcher reports activity. Decides whether anything really changed.
    func fileChangedOnDisk(tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }), let document = tab.textDocument
        else { return }

        guard let onDisk = try? TextNormalizer.read(at: tab.url).text else {
            // Unreadable or gone. Not an error — the reader still has the text, and
            // saving would put it back — but they should know.
            tab.externalChange = .removed
            return
        }

        // The watcher fires on `touch`, on a tool rewriting identical bytes, and on
        // Folio's own saves. Comparing the text is what separates those from a real
        // change, the same reasoning as the check before an overwrite.
        guard onDisk != document.rawText else {
            tab.externalChange = nil
            return
        }

        if !tab.isDirty, reloadsChangedFilesAutomatically {
            // Nothing of the reader's to lose, so catch up rather than nagging. The
            // scroll position is restored by key, so their place is kept.
            reloadTextDocument(for: tab.id, confirmingDiscard: { _ in true })
            statusMessage = "\(tab.name) changed on disk and was reloaded."
            return
        }
        tab.externalChange = .changed(onDisk)
    }

    /// Takes the version on disk, discarding anything unsaved.
    func acceptExternalChange(for requested: DocumentTab? = nil) {
        guard let tab = requested ?? active else { return }
        tab.externalChange = nil
        if tab.isShowingComparison { closeCommit(for: tab) }
        reloadTextDocument(for: tab.id, confirmingDiscard: { _ in true })
    }

    /// Keeps what is in the editor. The file on disk is left exactly as it is until the
    /// reader saves, which is still their decision and still asks.
    func dismissExternalChange(for requested: DocumentTab? = nil) {
        guard let tab = requested ?? active else { return }
        tab.externalChange = nil
        if case .externalChange = tab.pane { tab.pane = .document; tab.loadState = .empty }
    }

    // MARK: - Showing the difference

    /// Puts the incoming change in the pane, side by side against what this tab holds.
    ///
    /// Left is what Folio has, right is what is on disk, so the view reads as "here is
    /// what arrived" — and reloading turns the left into the right.
    func showExternalDifference(for requested: DocumentTab? = nil) {
        guard let tab = requested ?? active,
              case let .changed(onDisk) = tab.externalChange,
              tab.textDocument != nil else { return }

        tab.commitTask?.cancel()
        tab.pane = .externalChange
        tab.loadState = .loading
        tab.files = []
        tab.selectedFileID = nil
        tab.expandedFolds = []
        tab.matches = []
        tab.currentMatchIndex = 0

        // What the reader is looking at, which is their draft when they have one.
        let mine = TextNormalizer.splitLines(tab.currentText)
        let theirs = TextNormalizer.splitLines(onDisk)
        let name = tab.name
        let query = searchQuery

        tab.commitTask = Task { [weak self, weak tab] in
            let prepared = await DiffPreparation.prepare(comparing: mine, with: theirs, named: name)
            guard !Task.isCancelled, let tab, case .externalChange = tab.pane else { return }
            let entry = FileEntry(diff: prepared.diff, resolvedOriginal: nil)
            tab.files = [entry]
            tab.selectedFileID = entry.id
            tab.loadState = prepared.state
            if !query.isEmpty { self?.recomputeMatches() }
        }
    }
}
