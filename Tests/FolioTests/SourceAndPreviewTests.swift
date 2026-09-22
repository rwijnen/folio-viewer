import Foundation
import Testing

@testable import Folio

@MainActor
private final class Scratch {
    let root: URL
    let state = AppState()

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-both-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func open(_ name: String, _ body: String = "# Heading\n\noriginal\n") throws -> DocumentTab {
        let url = root.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        state.open(at: url)
        return state.active!
    }

    func waitFor(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if !condition() { Issue.record("timed out waiting for \(what)") }
    }
}

@Suite("Source and preview")
@MainActor
struct SourceAndPreviewTests {

    @Test func theModeDrawsBothHalvesOfOneDocument() throws {
        let scratch = try Scratch()
        let tab = try scratch.open("note.md")
        scratch.state.setReadingMode(.sideBySide, for: tab)

        let rendering = tab.paneRendering(isDark: false)
        #expect(rendering.kind == .sourceAndPreview)
        // The page is there, because the right half has to draw something.
        #expect(rendering.html?.isEmpty == false)
    }

    /// One tab drawn twice, not two tabs: the window is not split by this.
    @Test func itIsOneDocumentRatherThanTwo() throws {
        let scratch = try Scratch()
        let tab = try scratch.open("note.md")
        scratch.state.setReadingMode(.sideBySide, for: tab)

        #expect(!scratch.state.isSplit)
        #expect(scratch.state.panes.map(\.id) == [tab.id])
    }

    /// The preview must show what has been typed, not what is on disk — switching into
    /// the mode with unsaved edits pending would otherwise render the saved file.
    @Test func switchingInWithUnsavedEditsPreviewsThem() throws {
        let scratch = try Scratch()
        let tab = try scratch.open("note.md")
        scratch.state.updateDraft("# Heading\n\ntyped but not saved\n", for: tab)
        scratch.state.setReadingMode(.sideBySide, for: tab)

        let html = try #require(tab.paneRendering(isDark: false).html)
        #expect(html.contains("typed but not saved"))
        #expect(!html.contains("original"))
    }

    @Test func thePreviewCatchesUpAfterTypingStops() async throws {
        let scratch = try Scratch()
        let tab = try scratch.open("note.md")
        scratch.state.setReadingMode(.sideBySide, for: tab)

        scratch.state.updateDraft("# Heading\n\nlive text\n", for: tab)
        await scratch.waitFor("the preview to catch up") {
            tab.paneRendering(isDark: false).html?.contains("live text") == true
        }
        // Nothing was written to disk to achieve it.
        #expect(try String(contentsOf: tab.url, encoding: .utf8).contains("original"))
        #expect(tab.isDirty)
    }

    /// Every keystroke cancels the rebuild queued by the one before it, so a burst of
    /// typing re-parses once rather than once per character.
    @Test func typingCoalescesIntoOneRebuild() async throws {
        let scratch = try Scratch()
        let tab = try scratch.open("note.md")
        scratch.state.setReadingMode(.sideBySide, for: tab)
        let before = tab.textDocument?.contentVersion ?? 0

        for index in 1...12 {
            scratch.state.updateDraft("# Heading\n\nburst \(index)\n", for: tab)
        }
        await scratch.waitFor("the rebuild") {
            tab.paneRendering(isDark: false).html?.contains("burst 12") == true
        }
        let after = try #require(tab.textDocument?.contentVersion)
        #expect(after - before == 1)
    }

    /// Nothing is re-parsed behind a preview nobody is looking at.
    @Test func theOtherModesDoNotRebuildAsYouType() async throws {
        let scratch = try Scratch()
        let tab = try scratch.open("note.md")
        scratch.state.setReadingMode(.source, for: tab)
        let before = tab.textDocument?.contentVersion ?? 0

        scratch.state.updateDraft("# Heading\n\nsource only\n", for: tab)
        try? await Task.sleep(for: AppState.previewRefreshDelay * 3)
        #expect(tab.textDocument?.contentVersion == before)
    }

    /// Leaving the mode must not leave a rebuild in flight behind it.
    @Test func leavingTheModeCancelsThePendingRebuild() async throws {
        let scratch = try Scratch()
        let tab = try scratch.open("note.md")
        scratch.state.setReadingMode(.sideBySide, for: tab)

        scratch.state.updateDraft("# Heading\n\nabandoned\n", for: tab)
        scratch.state.setReadingMode(.source, for: tab)
        #expect(tab.previewRefresh == nil)
    }

    /// ⌘1 and ⌘2 are the two single-pane modes; ⌘3 is its own command. Toggling out of
    /// side by side has to land somewhere, and it lands on the one being edited.
    @Test func togglingMovesBetweenTheTwoSinglePaneModes() throws {
        let scratch = try Scratch()
        let tab = try scratch.open("note.md")
        #expect(tab.readingMode == .rendered)

        scratch.state.toggleReadingMode()
        #expect(tab.readingMode == .source)
        scratch.state.toggleReadingMode()
        #expect(tab.readingMode == .rendered)
    }

    /// A document Folio will not let you edit has no left half to show.
    @Test func aReadOnlyDocumentIsNotOfferedBothHalves() throws {
        let scratch = try Scratch()
        let tab = try scratch.open("notes.txt", "plain text\n")
        scratch.state.setReadingMode(.sideBySide, for: tab)
        #expect(tab.paneRendering(isDark: false).kind != .sourceAndPreview)
    }

    @Test func theModeIsRememberedBetweenLaunches() throws {
        let scratch = try Scratch()
        let tab = try scratch.open("note.md")
        scratch.state.setReadingMode(.sideBySide, for: tab)

        let stored = scratch.state.session
        Preferences.saveSession(stored)
        defer { Preferences.clearSession() }

        let restored = AppState()
        restored.sessionRestoreEnabled = true
        _ = restored.restoreSession()
        #expect(restored.active?.readingMode == .sideBySide)
        _ = tab
    }
}
