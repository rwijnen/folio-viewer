import AppKit
import Foundation

/// Committing and pushing the document you are editing.
///
/// The same rule as the editor, applied to the repository: one file, only when asked.
/// Folio commits the document in front of you and pushes the branch it is on, and it
/// does nothing else — no staging the tree, no pulling, no merging, no force. Anything
/// that could lose work belongs in a terminal, where the reader can see what they are
/// doing and undo it.
extension AppState {

    /// Git is offered for Markdown only, because Markdown is the only thing Folio can
    /// edit. A Commit button on a file the app will never change would be offering to
    /// commit someone else's work.
    func supportsVersionControl(_ tab: DocumentTab) -> Bool { tab.isEditable }

    var gitSnapshot: GitSnapshot? { active?.git }
    var gitActivity: String? { active?.gitActivity }
    var isGitBusy: Bool { active?.gitActivity != nil }

    // MARK: - Refreshing

    /// Asks git where things stand, in the background. Cheap to call often: for a file
    /// that is not in a repository it is one failed `rev-parse` and nothing else.
    func refreshGitStatus(for requested: DocumentTab? = nil) {
        guard let tab = requested ?? active, supportsVersionControl(tab) else { return }
        // A refresh started before a commit must not land after it and undo the answer.
        tab.gitRefreshToken += 1
        let token = tab.gitRefreshToken
        let url = tab.url
        let git = runner(for: tab)
        Task { [weak tab] in
            let snapshot = await GitRepository.snapshot(for: url, using: git)
            guard let tab, tab.gitRefreshToken == token else { return }
            tab.git = snapshot
        }
    }

    /// The runner for a document, bound to the folder its file is in.
    private func runner(for tab: DocumentTab) -> Git {
        Git(workingDirectory: tab.url.deletingLastPathComponent(), environment: gitEnvironment)
    }

    // MARK: - What the interface may offer

    /// Whether Commit… should be offered for a document. Asked per tab rather than only
    /// of the active one, so every menu and button in the interface answers it the same
    /// way — three of them used to decide for themselves, and disagreed.
    func canCommit(_ tab: DocumentTab) -> Bool {
        guard supportsVersionControl(tab), tab.gitActivity == nil,
              let snapshot = tab.git else { return false }
        // An unsaved edit is a change to commit even when the file on disk matches HEAD;
        // saving happens first and turns it into one.
        return snapshot.canCommit || (tab.isDirty && snapshot.commitIsPossible)
    }

    func canPush(_ tab: DocumentTab) -> Bool {
        guard supportsVersionControl(tab), tab.gitActivity == nil else { return false }
        return tab.git?.canPush == true
    }

    var canCommitActiveDocument: Bool { active.map(canCommit) ?? false }
    var canPushActiveDocument: Bool { active.map(canPush) ?? false }

    // MARK: - The commit sheet

    /// A first line for the message field. Not clever on purpose — a suggestion the
    /// reader replaces, not a message pretending to describe a change nobody read.
    func suggestedCommitMessage(for tab: DocumentTab) -> String {
        tab.git?.fileState == .untracked ? "Add \(tab.name)" : "Update \(tab.name)"
    }

    func presentCommitSheet() {
        guard let tab = active, supportsVersionControl(tab), let snapshot = tab.git else { return }
        // The menu items are disabled in this state, but ⌥⌘C still fires — menu-bar
        // shortcuts are deliberately never disabled here, because a disabled item
        // swallows its key equivalent. So the action says why instead of opening a sheet
        // whose only button would fail.
        guard canCommit(tab) else {
            statusMessage = snapshot.blockedReason ?? "Nothing to commit in \(tab.name)."
            return
        }
        refreshGitStatus(for: tab)
        if commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commitMessage = suggestedCommitMessage(for: tab)
        }
        // Pre-ticked only when there is somewhere for it to go; pushing is still a
        // separate, visible decision every time.
        commitShouldPush = tab.git?.upstream != nil
        isCommitSheetPresented = true
    }

    func dismissCommitSheet() {
        isCommitSheetPresented = false
    }

    // MARK: - Committing

    /// Commits the active document, optionally pushing afterwards.
    func commitActiveDocument(message: String, thenPush: Bool) {
        guard let tab = active else { return }
        Task { await commit(tab, message: message, thenPush: thenPush) }
    }

    @discardableResult
    func commit(_ tab: DocumentTab,
                message: String,
                thenPush: Bool,
                confirmingOverwrite: @MainActor (String) -> Bool = AppState.askToOverwrite) async
        -> Bool {
        guard canCommit(tab) else { return false }

        // Git commits what is on disk. Committing while the editor holds newer text
        // would quietly record the wrong version, so the save comes first — and if the
        // reader cancels it at the overwrite prompt, the commit is off too.
        if tab.isDirty, !save(tab, confirmingOverwrite: confirmingOverwrite) { return false }

        tab.gitActivity = "Committing…"
        defer { tab.gitActivity = nil }
        errorMessage = nil

        let git = runner(for: tab)
        let commit: GitRepository.Commit
        do {
            commit = try await GitRepository.commit(file: tab.url, message: message, using: git)
        } catch {
            errorMessage = "Could not commit \(tab.name): \(error.localizedDescription)"
            refreshGitStatus(for: tab)
            return false
        }
        statusMessage = "Committed \(commit.hash) — \(commit.subject)"
        // Cleared so the next sheet opens with a fresh suggestion rather than the last
        // message, which would be wrong for a different change and easy not to notice.
        commitMessage = ""

        // The log gained an entry, so a list already on screen is now out of date.
        if tab.historyState == .loaded { loadHistory(for: tab, force: true) }

        // Re-read before pushing: the commit just changed how far ahead we are, and the
        // upstream may have been configured since the sheet opened.
        let snapshot = await GitRepository.snapshot(for: tab.url, using: git)
        tab.git = snapshot
        tab.gitRefreshToken += 1

        guard thenPush else { return true }
        guard let upstream = snapshot?.upstream else {
            // Committed, but there is nowhere to send it. Not an error — say so and stop.
            statusMessage = "Committed \(commit.hash). This branch tracks no remote, so "
                + "nothing was pushed."
            return true
        }
        return await push(tab, upstream: upstream, after: commit)
    }

    // MARK: - Pushing

    func pushActiveDocument() {
        guard let tab = active, let snapshot = tab.git else { return }
        guard let upstream = snapshot.upstream else {
            statusMessage = "This branch tracks no remote, so there is nothing to push to."
            return
        }
        guard canPush(tab) else {
            statusMessage = "\(upstream) already has everything on this branch."
            return
        }
        Task { _ = await push(tab, upstream: upstream, after: nil) }
    }

    @discardableResult
    private func push(_ tab: DocumentTab,
                      upstream: String,
                      after commit: GitRepository.Commit?) async -> Bool {
        tab.gitActivity = "Pushing to \(upstream)…"
        defer { tab.gitActivity = nil }

        do {
            let summary = try await GitRepository.push(upstream: upstream, using: runner(for: tab))
            statusMessage = commit.map { "Committed \($0.hash). \(summary)" } ?? summary
            refreshGitStatus(for: tab)
            return true
        } catch {
            // The commit is safely made either way, which is worth saying: the reader
            // has not lost anything, they just have something still to send.
            let made = commit.map { "Committed \($0.hash), but the push failed. " } ?? ""
            errorMessage = made + error.localizedDescription
            refreshGitStatus(for: tab)
            return false
        }
    }
}
