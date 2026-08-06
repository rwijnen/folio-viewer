import Foundation
import Testing

@testable import Folio

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let samples = repositoryRoot.appendingPathComponent("Samples")

private func makeDocuments(_ count: Int) throws -> (folder: URL, urls: [URL]) {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("folio-session-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let body = (1...60).map { "Line \($0).\n\n" }.joined()
    let urls = try (0..<count).map { index -> URL in
        let url = folder.appendingPathComponent("doc\(index).md")
        try "# Document \(index)\n\n\(body)".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    return (folder, urls)
}

/// Reopening the app should put back what was open. These drive the snapshot and the
/// restore directly, so no test ever touches the real saved session.
@Suite("Session", .serialized)
@MainActor
struct SessionTests {

    @Test func snapshotRecordsEveryOpenDocumentInOrder() throws {
        let state = AppState()
        let (folder, urls) = try makeDocuments(3)
        defer { try? FileManager.default.removeItem(at: folder) }
        for url in urls { state.open(at: url) }
        state.activate(state.tabs[1].id)

        let session = state.session
        #expect(session.entries.map { ($0.path as NSString).lastPathComponent }
            == ["doc0.md", "doc1.md", "doc2.md"])
        #expect(session.activeIndex == 1)
    }

    @Test func restoringReopensTheSameDocumentsAndSelection() throws {
        let first = AppState()
        let (folder, urls) = try makeDocuments(3)
        defer { try? FileManager.default.removeItem(at: folder) }
        for url in urls { first.open(at: url) }
        first.activate(first.tabs[2].id)
        first.setReadingMode(.source)
        let saved = first.session

        // A fresh launch.
        let second = AppState()
        second.sessionRestoreEnabled = true
        Preferences.saveSession(saved)
        defer { Preferences.clearSession() }
        let restored = second.restoreSession()

        #expect(restored == 3)
        #expect(second.tabs.map(\.name) == ["doc0.md", "doc1.md", "doc2.md"])
        #expect(second.active?.name == "doc2.md")
        // Per-document state comes back too.
        #expect(second.active?.readingMode == .source)
        #expect(second.tabs[0].readingMode == .rendered)
    }

    @Test func restoringBringsBackScrollPositions() throws {
        let first = AppState()
        let (folder, urls) = try makeDocuments(1)
        defer { try? FileManager.default.removeItem(at: folder) }
        first.open(at: urls[0])
        let tab = try #require(first.active)
        tab.webScrollOffset = 900
        tab.scrollOffsets.record(640, for: tab.scrollKey)

        let second = AppState()
        second.sessionRestoreEnabled = true
        Preferences.saveSession(first.session)
        defer { Preferences.clearSession() }
        second.restoreSession()

        let restored = try #require(second.active)
        #expect(restored.webScrollOffset == 900)
        #expect(restored.scrollOffsets.offset(for: restored.scrollKey) == 640)
    }

    @Test func adiffRemembersWhichFileWasSelected() throws {
        let first = AppState()
        first.open(at: samples.appendingPathComponent("example.diff"))
        let tab = try #require(first.active)
        let third = try #require(tab.files.dropFirst(2).first)
        first.selectFile(third.id)
        #expect(first.session.entries.first?.selectedFileIndex == 2)

        let second = AppState()
        second.sessionRestoreEnabled = true
        Preferences.saveSession(first.session)
        defer { Preferences.clearSession() }
        second.restoreSession()

        let restoredTab = try #require(second.active)
        #expect(restoredTab.files.count == 4)
        // The same file by position, though its identity is minted afresh.
        #expect(restoredTab.selectedFileID == restoredTab.files[2].id)
    }

    @Test func filesThatHaveGoneAreDropped() throws {
        let (folder, urls) = try makeDocuments(3)
        let state = AppState()
        for url in urls { state.open(at: url) }
        state.activate(state.tabs[1].id)
        var saved = state.session
        try FileManager.default.removeItem(at: urls[1])
        defer { try? FileManager.default.removeItem(at: folder) }

        saved = saved.existingOnly()
        #expect(saved.entries.count == 2)
        // The document that was in front is gone, so the selection falls back.
        #expect(saved.activeIndex == 1)

        let second = AppState()
        second.sessionRestoreEnabled = true
        Preferences.saveSession(saved)
        defer { Preferences.clearSession() }
        second.restoreSession()
        #expect(second.tabs.map(\.name) == ["doc0.md", "doc2.md"])
        #expect(second.errorMessage == nil)
    }

    @Test func restoringNeverDisturbsADocumentOpenedAtLaunch() throws {
        let (folder, urls) = try makeDocuments(2)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = { () -> Session in
            let state = AppState()
            for url in urls { state.open(at: url) }
            return state.session
        }()
        Preferences.saveSession(saved)
        defer { Preferences.clearSession() }

        // Finder got there first.
        let second = AppState()
        second.sessionRestoreEnabled = true
        second.open(at: samples.appendingPathComponent("example.md"))
        let restored = second.restoreSession()

        #expect(restored == 0)
        #expect(second.tabs.map(\.name) == ["example.md"])
    }

    @Test func aRunawaySessionIsCapped() {
        var session = Session()
        session.entries = (0..<80).map {
            Session.Entry(path: "/tmp/doc\($0).md", readingMode: "rendered",
                          selectedFileIndex: nil, scrollOffset: 0, webScrollOffset: 0)
        }
        session.activeIndex = 70
        let trimmed = session.trimmed
        #expect(trimmed.entries.count == Session.maximumEntries)
        // The active index pointed past the end, so it falls back to something valid.
        #expect(trimmed.activeIndex == 0)
    }

    @Test func nothingIsWrittenUnlessRestoreIsEnabled() throws {
        let state = AppState()      // tests leave this off
        let (folder, urls) = try makeDocuments(1)
        defer { try? FileManager.default.removeItem(at: folder) }
        Preferences.clearSession()
        state.open(at: urls[0])
        #expect(Preferences.loadSession().entries.isEmpty)
    }

    @Test func aSessionSurvivesEncodingAndDecoding() {
        var session = Session()
        session.entries = [
            Session.Entry(path: "/tmp/a.md", readingMode: "source",
                          selectedFileIndex: 2, scrollOffset: 12.5, webScrollOffset: 44),
        ]
        session.activeIndex = 0
        Preferences.saveSession(session)
        defer { Preferences.clearSession() }
        #expect(Preferences.loadSession() == session)
    }
}

/// Dragging a tab to a new position.
@Suite("Tab order", .serialized)
@MainActor
struct TabOrderTests {

    private func makeState(_ count: Int) throws -> (AppState, URL) {
        let (folder, urls) = try makeDocuments(count)
        let state = AppState()
        for url in urls { state.open(at: url) }
        return (state, folder)
    }

    @Test func aTabCanBeMovedLater() throws {
        let (state, folder) = try makeState(4)
        defer { try? FileManager.default.removeItem(at: folder) }
        state.moveTab(state.tabs[0].id, to: 2)
        #expect(state.tabs.map(\.name) == ["doc1.md", "doc2.md", "doc0.md", "doc3.md"])
    }

    @Test func aTabCanBeMovedEarlier() throws {
        let (state, folder) = try makeState(4)
        defer { try? FileManager.default.removeItem(at: folder) }
        state.moveTab(state.tabs[3].id, to: 0)
        #expect(state.tabs.map(\.name) == ["doc3.md", "doc0.md", "doc1.md", "doc2.md"])
    }

    @Test func movingKeepsTheSameDocumentInFront() throws {
        let (state, folder) = try makeState(3)
        defer { try? FileManager.default.removeItem(at: folder) }
        state.activate(state.tabs[0].id)
        let active = state.active?.id
        state.moveTab(state.tabs[2].id, to: 0)
        #expect(state.active?.id == active)
        #expect(state.active?.name == "doc0.md")
    }

    @Test func anOutOfRangeDestinationIsClamped() throws {
        let (state, folder) = try makeState(3)
        defer { try? FileManager.default.removeItem(at: folder) }
        state.moveTab(state.tabs[0].id, to: 99)
        #expect(state.tabs.map(\.name) == ["doc1.md", "doc2.md", "doc0.md"])
        state.moveTab(state.tabs[2].id, to: -5)
        #expect(state.tabs.map(\.name) == ["doc0.md", "doc1.md", "doc2.md"])
    }

    @Test func movingAnUnknownTabDoesNothing() throws {
        let (state, folder) = try makeState(2)
        defer { try? FileManager.default.removeItem(at: folder) }
        state.moveTab(UUID(), to: 0)
        #expect(state.tabs.map(\.name) == ["doc0.md", "doc1.md"])
    }

    @Test func theNewOrderIsWhatGetsRemembered() throws {
        let (state, folder) = try makeState(3)
        defer { try? FileManager.default.removeItem(at: folder) }
        state.moveTab(state.tabs[2].id, to: 0)
        #expect(state.session.entries.map { ($0.path as NSString).lastPathComponent }
            == ["doc2.md", "doc0.md", "doc1.md"])
    }
}

/// Restoring must not stall the launch, so documents are read only when first shown.
@Suite("Lazy restore", .serialized)
@MainActor
struct LazyRestoreTests {

    private func restoredState(_ count: Int) throws -> (AppState, URL) {
        let (folder, urls) = try makeDocuments(count)
        let first = AppState()
        for url in urls { first.open(at: url) }
        first.activate(first.tabs[0].id)
        Preferences.saveSession(first.session)

        let second = AppState()
        second.sessionRestoreEnabled = true
        second.restoreSession()
        return (second, folder)
    }

    @Test func onlyTheDocumentInFrontIsRead() throws {
        let (state, folder) = try restoredState(4)
        defer { try? FileManager.default.removeItem(at: folder); Preferences.clearSession() }

        #expect(state.tabs.count == 4)
        #expect(state.active?.isPending == false)
        #expect(state.active?.textDocument != nil)
        // The rest are names on tabs and nothing more, until you click one.
        let pending = state.tabs.dropFirst().map { $0.isPending }
        let unread = state.tabs.dropFirst().map { $0.textDocument == nil }
        #expect(pending == [true, true, true])
        #expect(unread == [true, true, true])
        // They still carry the right label and kind.
        #expect(state.tabs.map(\.name) == ["doc0.md", "doc1.md", "doc2.md", "doc3.md"])
        #expect(state.tabs.map(\.content) == [.markdown, .markdown, .markdown, .markdown])
    }

    @Test func clickingAPendingTabReadsIt() throws {
        let (state, folder) = try restoredState(3)
        defer { try? FileManager.default.removeItem(at: folder); Preferences.clearSession() }

        let later = state.tabs[2]
        #expect(later.isPending)
        state.activate(later.id)
        #expect(!later.isPending)
        #expect(later.textDocument != nil)
        #expect(state.canFind)
    }

    @Test func closingTheFrontTabReadsWhicheverComesForward() throws {
        let (state, folder) = try restoredState(3)
        defer { try? FileManager.default.removeItem(at: folder); Preferences.clearSession() }

        // Regression: the neighbour was promoted without being read, which showed the
        // welcome screen instead of the document.
        state.closeActiveTab()
        let nowInFront = state.active
        #expect(nowInFront?.isPending == false)
        #expect(nowInFront?.textDocument != nil)
    }

    @Test func anUnreadTabStillRemembersWhatItWasToldToRestore() throws {
        let (folder, urls) = try makeDocuments(2)
        defer { try? FileManager.default.removeItem(at: folder); Preferences.clearSession() }

        let first = AppState()
        for url in urls { first.open(at: url) }
        first.activate(first.tabs[1].id)
        first.setReadingMode(.source)
        first.tabs[1].webScrollOffset = 512
        first.activate(first.tabs[0].id)
        Preferences.saveSession(first.session)

        let second = AppState()
        second.sessionRestoreEnabled = true
        second.restoreSession()
        #expect(second.tabs[1].isPending)

        // Quitting again before ever opening that tab must not lose its state.
        let round = second.session
        #expect(round.entries[1].readingMode == "source")
        #expect(round.entries[1].webScrollOffset == 512)

        // And opening it applies exactly that.
        second.activate(second.tabs[1].id)
        #expect(second.tabs[1].readingMode == .source)
        #expect(second.tabs[1].webScrollOffset == 512)
    }

    @Test func aFileDeletedAfterRestoreIsHandledWhenOpened() throws {
        let (state, folder) = try restoredState(3)
        defer { Preferences.clearSession() }
        let doomed = state.tabs[2]
        try FileManager.default.removeItem(at: doomed.url)
        defer { try? FileManager.default.removeItem(at: folder) }

        state.activate(doomed.id)
        // The tab closes with an explanation instead of showing an empty document.
        #expect(!state.tabs.contains { $0.id == doomed.id })
        #expect(state.errorMessage?.isEmpty == false)
    }

    @Test func aDiffRestoresLazilyToo() throws {
        defer { Preferences.clearSession() }
        let first = AppState()
        first.open(at: samples.appendingPathComponent("example.md"))
        first.open(at: samples.appendingPathComponent("example.diff"))
        first.selectFile(first.tabs[1].files[1].id)
        first.activate(first.tabs[0].id)
        Preferences.saveSession(first.session)

        let second = AppState()
        second.sessionRestoreEnabled = true
        second.restoreSession()
        let diffTab = try #require(second.tabs.last)
        #expect(diffTab.isPending)
        #expect(diffTab.content == .diff)      // known from the extension alone
        #expect(diffTab.files.isEmpty)

        second.activate(diffTab.id)
        #expect(diffTab.files.count == 4)
        #expect(diffTab.selectedFileID == diffTab.files[1].id)
    }
}
