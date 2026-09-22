import Foundation
import Testing

@testable import Folio

@MainActor
private final class Scratch {
    let root: URL
    let state = AppState()

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func open(_ name: String) throws -> DocumentTab {
        let url = root.appendingPathComponent(name)
        try "# \(name)\n\nbody\n".write(to: url, atomically: true, encoding: .utf8)
        state.open(at: url)
        return state.active!
    }
}

@Suite("Split view")
@MainActor
struct SplitViewTests {

    @Test func aWindowStartsShowingOneDocument() throws {
        let scratch = try Scratch()
        let one = try scratch.open("one.md")
        #expect(!scratch.state.isSplit)
        #expect(scratch.state.panes.map(\.id) == [one.id])
    }

    @Test func openingBesideShowsBothInOrder() throws {
        let scratch = try Scratch()
        let one = try scratch.open("one.md")
        let two = try scratch.open("two.md")
        // `two` is in front, so it is the active document and `one` goes beside it.
        scratch.state.openInSplit(one.id)

        #expect(scratch.state.isSplit)
        #expect(scratch.state.activeTabID == two.id)
        #expect(scratch.state.panes.map(\.id) == [two.id, one.id])
    }

    /// The point of `splitIsLeading`: focusing the right-hand document promotes it to
    /// the active one, and without the flag it would jump to the left under the pointer.
    @Test func focusingTheOtherPaneDoesNotMoveEitherDocument() throws {
        let scratch = try Scratch()
        let one = try scratch.open("one.md")
        let two = try scratch.open("two.md")
        scratch.state.openInSplit(one.id)
        #expect(scratch.state.panes.map(\.id) == [two.id, one.id])

        scratch.state.focusPane(one.id)
        #expect(scratch.state.activeTabID == one.id)
        #expect(scratch.state.panes.map(\.id) == [two.id, one.id])

        // And back again.
        scratch.state.focusPane(two.id)
        #expect(scratch.state.activeTabID == two.id)
        #expect(scratch.state.panes.map(\.id) == [two.id, one.id])
    }

    /// Clicking the companion's tab in the tab bar. `activate` knew nothing about panes,
    /// so it made the companion active while leaving it the companion — and both panes
    /// then named the same document.
    @Test func bringingTheCompanionForwardFromTheTabBarDoesNotDuplicateIt() throws {
        let scratch = try Scratch()
        let one = try scratch.open("one.md")
        let two = try scratch.open("two.md")
        scratch.state.openInSplit(one.id)

        scratch.state.activate(one.id)
        #expect(scratch.state.panes.map(\.id) == [two.id, one.id])
        #expect(scratch.state.activeTabID == one.id)
        #expect(scratch.state.splitTabID == two.id)
    }

    /// ⌃⇥ onto the companion is the same thing by another route.
    @Test func steppingOntoTheCompanionDoesNotDuplicateIt() throws {
        let scratch = try Scratch()
        let one = try scratch.open("one.md")
        let two = try scratch.open("two.md")
        scratch.state.openInSplit(one.id)

        for _ in 0..<4 {
            scratch.state.selectAdjacentTab(offset: 1)
            #expect(Set(scratch.state.panes.map(\.id)).count == scratch.state.panes.count)
        }
    }

    /// And re-opening a file that is already the companion.
    @Test func reopeningTheCompanionDoesNotDuplicateIt() throws {
        let scratch = try Scratch()
        let one = try scratch.open("one.md")
        try scratch.open("two.md")
        scratch.state.openInSplit(one.id)

        scratch.state.open(at: one.url)
        #expect(Set(scratch.state.panes.map(\.id)).count == 2)
    }

    @Test func swappingMovesThemAndLeavesTheFocusAlone() throws {
        let scratch = try Scratch()
        let one = try scratch.open("one.md")
        let two = try scratch.open("two.md")
        scratch.state.openInSplit(one.id)

        scratch.state.swapPanes()
        #expect(scratch.state.panes.map(\.id) == [one.id, two.id])
        #expect(scratch.state.activeTabID == two.id)
    }

    /// Both panes are one tab, and everything on a tab — its scroll offset, its reading
    /// mode, its live web view — is single. The same document twice cannot work.
    @Test func aDocumentCannotBeInBothPanes() throws {
        let scratch = try Scratch()
        try scratch.open("one.md")
        let two = try scratch.open("two.md")

        scratch.state.openInSplit(two.id)
        #expect(!scratch.state.isSplit)
    }

    @Test func closingTheSplitKeepsBothDocumentsOpen() throws {
        let scratch = try Scratch()
        let one = try scratch.open("one.md")
        let two = try scratch.open("two.md")
        scratch.state.openInSplit(one.id)

        scratch.state.closeSplit()
        #expect(!scratch.state.isSplit)
        #expect(scratch.state.activeTabID == two.id)
        #expect(scratch.state.tabs.count == 2)
    }

    /// A pane pointing at a document that has been closed would draw nothing.
    @Test func closingTheCompanionEndsTheSplit() throws {
        let scratch = try Scratch()
        let one = try scratch.open("one.md")
        try scratch.open("two.md")
        scratch.state.openInSplit(one.id)

        scratch.state.closeTab(one.id)
        #expect(!scratch.state.isSplit)
        #expect(scratch.state.panes.count == 1)
    }

    @Test func closingTheFocusedDocumentLeavesTheCompanionShowing() throws {
        let scratch = try Scratch()
        let one = try scratch.open("one.md")
        let two = try scratch.open("two.md")
        scratch.state.openInSplit(one.id)

        scratch.state.closeTab(two.id)
        #expect(!scratch.state.isSplit)
        #expect(scratch.state.activeTabID == one.id)
    }

    @Test func closingTheOtherTabsEndsTheSplit() throws {
        let scratch = try Scratch()
        let one = try scratch.open("one.md")
        try scratch.open("two.md")
        scratch.state.openInSplit(one.id)

        scratch.state.closeOtherTabs()
        #expect(!scratch.state.isSplit)
        #expect(scratch.state.tabs.count == 1)
    }

    @Test func splittingWithOnlyOneDocumentSaysSoRatherThanDoingNothing() throws {
        let scratch = try Scratch()
        try scratch.open("one.md")
        scratch.state.splitWithNeighbour()
        #expect(!scratch.state.isSplit)
        #expect(scratch.state.statusMessage?.isEmpty == false)
    }

    @Test func splittingPicksTheNeighbour() throws {
        let scratch = try Scratch()
        let one = try scratch.open("one.md")
        let two = try scratch.open("two.md")
        scratch.state.splitWithNeighbour()
        #expect(scratch.state.isSplit)
        #expect(Set(scratch.state.panes.map(\.id)) == [one.id, two.id])
    }

    /// Both documents are on screen, so neither may have its page taken away.
    @Test func neitherPaneIsACandidateForBeingTornDown() throws {
        let scratch = try Scratch()
        let one = try scratch.open("one.md")
        let two = try scratch.open("two.md")
        scratch.state.openInSplit(one.id)

        for index in 0..<AppState.maximumLivePages {
            try scratch.open("filler\(index).md")
        }
        scratch.state.focusPane(two.id)
        #expect(scratch.state.panes.count == 2)
        #expect(scratch.state.tabs.contains { $0.id == one.id })
    }

    @Test func aSplitSurvivesASession() throws {
        let scratch = try Scratch()
        let one = try scratch.open("one.md")
        let two = try scratch.open("two.md")
        scratch.state.openInSplit(one.id)
        scratch.state.swapPanes()

        let stored = scratch.state.session
        #expect(stored.activeIndex == 1)
        #expect(stored.splitIndex == 0)
        #expect(stored.splitIsLeading == true)

        Preferences.saveSession(stored)
        defer { Preferences.clearSession() }
        let restored = AppState()
        restored.sessionRestoreEnabled = true
        _ = restored.restoreSession()
        #expect(restored.isSplit)
        #expect(restored.panes.map(\.url) == [one.url, two.url])
    }
}
