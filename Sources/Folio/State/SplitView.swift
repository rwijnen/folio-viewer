import Foundation

/// Two documents side by side in one window.
///
/// The model is two slots rather than a list: `activeTabID` is the document being worked
/// in — the one the sidebar, ⌘F, git and every menu already follow — and `splitTabID` is
/// its companion. Focusing the companion makes it the active document and demotes the
/// other, which is what keeps the rest of the app working unchanged rather than teaching
/// every one of those places about panes.
///
/// `splitIsLeading` exists because of that swap. Without it, clicking into the right-hand
/// document would promote it to `activeTabID` and it would jump to the left; the flag
/// records which side the companion is on, so focus changes the outline and the toolbar
/// but never moves a document out from under the pointer.
extension AppState {

    /// Whether the window is showing two documents.
    var isSplit: Bool { splitTab != nil }

    /// The companion document, or nil when the window shows one.
    var splitTab: DocumentTab? {
        guard let splitTabID else { return nil }
        return tabs.first { $0.id == splitTabID }
    }

    /// The two documents in the order they are drawn, left first.
    var panes: [DocumentTab] {
        guard let active else { return [] }
        // The companion never being the active document is maintained by `setActive`;
        // checked again here because the cost of being wrong is the window drawing one
        // file twice, with two views fighting over a single tab's scroll offset and its
        // one live web view. Showing a single document is the safe way to be wrong.
        guard let companion = splitTab, companion.id != active.id else { return [active] }
        return splitIsLeading ? [companion, active] : [active, companion]
    }

    /// Puts a document beside the one in front.
    ///
    /// A document cannot be both panes: the pair would share a tab, and everything on it
    /// — scroll offset, reading mode, the live web view — is single. Asking for that is
    /// taken as asking to focus it instead.
    func openInSplit(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        guard let activeTabID else {
            activate(id)
            return
        }
        guard id != activeTabID else { return }
        setSplit(id, leading: false)
        revealGroup(of: tabs.first { $0.id == id }!)
        noteShown(id)
        saveSession()
    }

    /// Opens the next document along beside this one, so the split can be had without
    /// first deciding what goes in it.
    func splitWithNeighbour() {
        guard splitTabID == nil, let activeTabID else { return }
        let visible = visibleTabs
        guard visible.count > 1,
              let index = visible.firstIndex(where: { $0.id == activeTabID }) else {
            statusMessage = "Open another document to put beside this one."
            return
        }
        openInSplit(visible[(index + 1) % visible.count].id)
    }

    /// Back to one document. The focused one stays; the companion is only closed as a
    /// pane, never as a tab.
    func closeSplit() {
        guard splitTabID != nil else { return }
        setSplit(nil, leading: false)
        saveSession()
    }

    /// Leaves the split showing the same two documents, the other way round.
    func swapPanes() {
        guard splitTabID != nil else { return }
        setSplit(splitTabID, leading: !splitIsLeading)
        saveSession()
    }

    /// Moves the focus to a document already on screen.
    ///
    /// Ordinary activation: `setActive` trades the two roles when the tab coming forward
    /// is the companion, so every route into it — this, the tab bar, ⌃⇥, re-opening a
    /// file that is already open — behaves the same and none of them can leave the same
    /// document in both panes.
    func focusPane(_ id: UUID) {
        guard id != activeTabID else { return }
        activate(id)
    }

    /// Whichever of the two is not the one given, or nil when there is no split.
    func companion(of tab: DocumentTab) -> DocumentTab? {
        panes.first { $0.id != tab.id }
    }

    /// Drops a document from the split when it is closed or filtered out of reach.
    func forgetSplitIfGone() {
        guard let splitTabID else { return }
        if !tabs.contains(where: { $0.id == splitTabID }) || splitTabID == activeTabID {
            setSplit(nil, leading: false)
        }
    }
}
