import Foundation

/// Reading a document's past.
///
/// Where the commit and push side of git is deliberately narrow, this side is not — it
/// only reads. The design decision worth knowing is that a commit is shown *in place of*
/// the document rather than in a new tab: the list stays beside it, so stepping back
/// through a file's history is one click per step rather than a tab each.
///
/// It is also almost no new code. A commit's change is a unified diff and the content it
/// was made against, which is the pair Folio's split view already takes, so the rows,
/// folds, word diffing, highlighting, search and scroll memory all come along unchanged.
extension AppState {

    // MARK: - The sidebar

    func setSidebarMode(_ mode: SidebarMode, for requested: DocumentTab? = nil) {
        guard let tab = requested ?? active, tab.sidebarMode != mode else { return }
        tab.sidebarMode = mode
        if mode == .history { loadHistory(for: tab) }
    }

    /// Reads the log in the background. Does nothing for a file outside a repository, or
    /// when the list is already there — `force` is for after a commit adds to it.
    func loadHistory(for requested: DocumentTab? = nil, force: Bool = false) {
        guard let tab = requested ?? active, tab.git != nil else { return }
        if !force, tab.historyState == .loaded || tab.historyState == .loading { return }

        tab.historyTask?.cancel()
        tab.historyState = .loading
        let url = tab.url
        let git = historyRunner(for: tab)
        tab.historyTask = Task { [weak tab] in
            do {
                let commits = try await GitHistory.commits(for: url, using: git)
                guard !Task.isCancelled, let tab else { return }
                tab.history = commits
                tab.historyState = .loaded
            } catch {
                guard !Task.isCancelled, let tab else { return }
                tab.history = []
                tab.historyState = .failed(error.localizedDescription)
            }
        }
    }

    /// True when the log was read and had nothing in it — a file that is in a repository
    /// folder but has never been committed.
    func historyIsEmpty(_ tab: DocumentTab) -> Bool {
        tab.historyState == .loaded && tab.history.isEmpty
    }

    private func historyRunner(for tab: DocumentTab) -> Git {
        Git(workingDirectory: tab.url.deletingLastPathComponent(), environment: gitEnvironment)
    }

    // MARK: - Showing one commit

    func showCommit(_ commit: GitCommitSummary, for requested: DocumentTab? = nil) {
        guard let tab = requested ?? active else { return }
        tab.commitTask?.cancel()
        tab.pane = .commit(commit)
        tab.loadState = .loading
        // The diff pipeline finds its file through `files`/`selectedFileID`, the same way
        // an opened patch does; while a commit is showing, that is what the tab holds.
        tab.files = []
        tab.selectedFileID = nil
        tab.expandedFolds = []
        tab.matches = []
        tab.currentMatchIndex = 0

        let git = historyRunner(for: tab)
        let query = searchQuery
        tab.commitTask = Task { [weak self, weak tab] in
            do {
                let change = try await GitHistory.change(at: commit, using: git)
                let prepared = await DiffPreparation.prepare(change: change)
                guard !Task.isCancelled, let tab, tab.viewingCommit?.hash == commit.hash else {
                    return
                }
                let entry = FileEntry(diff: change.diff, resolvedOriginal: nil)
                tab.files = [entry]
                tab.selectedFileID = entry.id
                tab.loadState = prepared
                if !query.isEmpty { self?.recomputeMatches() }
            } catch {
                guard !Task.isCancelled, let tab, tab.viewingCommit?.hash == commit.hash else {
                    return
                }
                tab.loadState = .failed(error.localizedDescription)
            }
        }
    }

    /// Back to the document itself.
    func closeCommit(for requested: DocumentTab? = nil) {
        guard let tab = requested ?? active, tab.isShowingComparison else { return }
        tab.commitTask?.cancel()
        tab.pane = .document
        tab.loadState = .empty
        tab.files = []
        tab.selectedFileID = nil
        tab.expandedFolds = []
        tab.matches = []
        tab.currentMatchIndex = 0
        if !searchQuery.isEmpty { recomputeMatches() }
    }

    /// Steps through the list: +1 is further back in time, since the log is newest first.
    func stepThroughHistory(by offset: Int) {
        guard let tab = active, let current = tab.viewingCommit,
              let index = tab.history.firstIndex(where: { $0.hash == current.hash }) else { return }
        let next = index + offset
        guard tab.history.indices.contains(next) else { return }
        showCommit(tab.history[next], for: tab)
    }

    /// Whether the pane is showing the past rather than the document.
    var isViewingCommit: Bool { active?.viewingCommit != nil }
}

extension AppState {

    func setHistoryFilter(_ filter: HistoryFilter, for requested: DocumentTab? = nil) {
        guard let tab = requested ?? active else { return }
        tab.historyFilter = filter
    }
}

/// Seeing what is not yet committed.
///
/// The history browser answers "how did this file get here"; this answers the question
/// immediately before a commit — "what am I about to record". The pill counts the lines,
/// and until now there was nowhere to go and look at them.
extension AppState {

    /// Whether there is anything uncommitted worth showing.
    ///
    /// Unsaved edits count, because the comparison includes them: committing saves first,
    /// so what this shows is exactly what a commit would record.
    func hasWorkingChanges(_ tab: DocumentTab) -> Bool {
        guard supportsVersionControl(tab), let snapshot = tab.git else { return false }
        if tab.isDirty { return true }
        return snapshot.fileState == .modified || snapshot.fileState == .untracked
    }

    /// Puts the last commit and the current text side by side.
    func showWorkingChanges(for requested: DocumentTab? = nil) {
        guard let tab = requested ?? active, tab.git != nil else { return }
        guard hasWorkingChanges(tab) else {
            statusMessage = "\(tab.name) has no uncommitted changes."
            return
        }

        tab.commitTask?.cancel()
        tab.pane = .workingChanges
        tab.loadState = .loading
        tab.files = []
        tab.selectedFileID = nil
        tab.expandedFolds = []
        tab.matches = []
        tab.currentMatchIndex = 0

        // The draft, not the file: a commit saves first, so this is what would be
        // recorded. An untracked file has no committed side at all.
        let mine = TextNormalizer.splitLines(tab.currentText)
        let url = tab.url
        let name = tab.name
        let git = Git(workingDirectory: url.deletingLastPathComponent(),
                      environment: gitEnvironment)
        let query = searchQuery

        tab.commitTask = Task { [weak self, weak tab] in
            let committed = await GitHistory.contentsAtHead(of: url, using: git)
            let head = committed.map(TextNormalizer.splitLines) ?? []
            let prepared = await DiffPreparation.prepare(comparing: head, with: mine, named: name)
            guard !Task.isCancelled, let tab, tab.pane == .workingChanges else { return }
            let entry = FileEntry(diff: prepared.diff, resolvedOriginal: nil)
            tab.files = [entry]
            tab.selectedFileID = entry.id
            tab.loadState = prepared.state
            if !query.isEmpty { self?.recomputeMatches() }
        }
    }
}
