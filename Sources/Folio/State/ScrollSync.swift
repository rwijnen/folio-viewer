import Foundation

/// Keeping the two halves of the source-and-preview mode in step.
///
/// Both halves already knew where they were: the editor works out the line at its top
/// edge for the outline, and the page reports the block at its top. Neither told the
/// other. This is the part in between, and the whole of it is the loop: A scrolls, B is
/// moved to match, B reports its new position, A is moved to match — forever, and in
/// practice drifting as each rounds to the nearest block.
///
/// So a report is ignored for a moment after this pushes a scroll of its own. A window
/// rather than a flag because the move a push causes does not arrive at once: the page
/// reports on a 120 ms throttle, and an editor scrolled by a rounded line may settle a
/// pixel off and report again.
extension AppState {

    /// How long a side stays deaf after being moved by the other one.
    static let scrollSyncQuiet: TimeInterval = 0.35

    /// The editor moved; bring the preview to the same line.
    func previewFollowed(editorLine line: Int, for tab: DocumentTab) {
        guard tab.readingMode == .sideBySide, !isSyncingScroll(tab) else { return }
        beginSyncingScroll(tab)
        tab.previewLine = line
        tab.previewLineRequest += 1
    }

    /// The preview moved; bring the editor to the same line.
    func editorFollowed(previewLine line: Int, for tab: DocumentTab) {
        guard tab.readingMode == .sideBySide, !isSyncingScroll(tab) else { return }
        beginSyncingScroll(tab)
        tab.sourceScrollLine = line
        tab.sourceScrollRequest += 1
    }

    private func isSyncingScroll(_ tab: DocumentTab) -> Bool {
        guard let until = tab.scrollSyncQuietUntil else { return false }
        return Date() < until
    }

    private func beginSyncingScroll(_ tab: DocumentTab) {
        tab.scrollSyncQuietUntil = Date().addingTimeInterval(Self.scrollSyncQuiet)
    }
}
