import Foundation
import Testing

@testable import Folio

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let samples = repositoryRoot.appendingPathComponent("Samples")

/// Writes throwaway Markdown files so tab behaviour can be exercised without
/// touching the checked-in samples.
private func makeScratchDocuments(_ count: Int) throws -> (folder: URL, urls: [URL]) {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("folio-tabs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let urls = try (0..<count).map { index -> URL in
        let url = folder.appendingPathComponent("doc\(index).md")
        try "# Document \(index)\n\nBody \(index).\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    return (folder, urls)
}

@Suite("Tabs", .serialized)
@MainActor
struct TabTests {

    /// A fresh state per test — `AppState.shared` is the app's singleton, not ours.
    private func makeState() -> AppState {
        AppState()
    }

    @Test func opensEachDocumentInItsOwnTab() throws {
        let state = makeState()
        let (folder, urls) = try makeScratchDocuments(3)
        defer { try? FileManager.default.removeItem(at: folder) }

        for url in urls { state.open(at: url) }
        #expect(state.tabs.count == 3)
        #expect(state.tabs.map(\.name) == ["doc0.md", "doc1.md", "doc2.md"])
        // The most recently opened one is showing.
        #expect(state.active?.name == "doc2.md")
        #expect(state.documentTitle == "doc2.md")
    }

    @Test func reopeningAFileActivatesTheExistingTab() throws {
        let state = makeState()
        let (folder, urls) = try makeScratchDocuments(2)
        defer { try? FileManager.default.removeItem(at: folder) }

        state.open(at: urls[0])
        state.open(at: urls[1])
        state.open(at: urls[0])
        #expect(state.tabs.count == 2)
        #expect(state.active?.name == "doc0.md")
        #expect(state.statusMessage?.contains("already open") == true)
    }

    @Test func treatsPathsThatDifferOnlyInFormAsTheSameFile() throws {
        let state = makeState()
        let (folder, urls) = try makeScratchDocuments(1)
        defer { try? FileManager.default.removeItem(at: folder) }

        state.open(at: urls[0])
        let awkward = folder.appendingPathComponent("./doc0.md")
        state.open(at: awkward)
        #expect(state.tabs.count == 1)
    }

    @Test func closingTheActiveTabActivatesItsNeighbour() throws {
        let state = makeState()
        let (folder, urls) = try makeScratchDocuments(3)
        defer { try? FileManager.default.removeItem(at: folder) }

        for url in urls { state.open(at: url) }
        state.activate(state.tabs[1].id)
        state.closeActiveTab()
        #expect(state.tabs.count == 2)
        #expect(state.active?.name == "doc2.md")

        state.closeActiveTab()
        #expect(state.active?.name == "doc0.md")
        state.closeActiveTab()
        #expect(state.tabs.isEmpty)
        #expect(state.active == nil)
        #expect(state.documentTitle == "Folio")
    }

    @Test func closingAnInactiveTabLeavesTheSelectionAlone() throws {
        let state = makeState()
        let (folder, urls) = try makeScratchDocuments(3)
        defer { try? FileManager.default.removeItem(at: folder) }

        for url in urls { state.open(at: url) }
        let active = state.active?.id
        state.closeTab(state.tabs[0].id)
        #expect(state.tabs.count == 2)
        #expect(state.active?.id == active)
    }

    @Test func cyclesThroughTabsInBothDirections() throws {
        let state = makeState()
        let (folder, urls) = try makeScratchDocuments(3)
        defer { try? FileManager.default.removeItem(at: folder) }

        for url in urls { state.open(at: url) }
        state.activate(state.tabs[0].id)
        state.selectAdjacentTab(offset: 1)
        #expect(state.active?.name == "doc1.md")
        state.selectAdjacentTab(offset: -1)
        #expect(state.active?.name == "doc0.md")
        // Wraps around rather than stopping at the ends.
        state.selectAdjacentTab(offset: -1)
        #expect(state.active?.name == "doc2.md")
        state.selectAdjacentTab(offset: 1)
        #expect(state.active?.name == "doc0.md")
    }

    @Test func closeOtherTabsKeepsOnlyTheActiveOne() throws {
        let state = makeState()
        let (folder, urls) = try makeScratchDocuments(4)
        defer { try? FileManager.default.removeItem(at: folder) }

        for url in urls { state.open(at: url) }
        state.activate(state.tabs[2].id)
        state.closeOtherTabs()
        #expect(state.tabs.count == 1)
        #expect(state.active?.name == "doc2.md")
    }

    @Test func keepsPerDocumentStateSeparate() throws {
        let state = makeState()
        let (folder, urls) = try makeScratchDocuments(2)
        defer { try? FileManager.default.removeItem(at: folder) }

        state.open(at: urls[0])
        state.setReadingMode(.source)
        let first = try #require(state.active)

        state.open(at: urls[1])
        let second = try #require(state.active)
        // The second document opens rendered even though the first was switched to source.
        #expect(second.readingMode == .rendered)
        #expect(first.readingMode == .source)
        #expect(first.id != second.id)
        #expect(first.renderer !== second.renderer)

        state.activate(first.id)
        #expect(state.readingMode == .source)
    }

    @Test func searchResultsFollowTheActiveDocument() throws {
        let state = makeState()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = folder.appendingPathComponent("one.md")
        let busy = folder.appendingPathComponent("two.md")
        try "needle once\n".write(to: plain, atomically: true, encoding: .utf8)
        try "needle needle needle\n".write(to: busy, atomically: true, encoding: .utf8)

        state.open(at: plain)
        state.setReadingMode(.source)      // rendered mode searches in JavaScript
        state.searchQuery = "needle"
        state.recomputeMatches()
        #expect(state.matches.count == 1)

        state.open(at: busy)
        state.setReadingMode(.source)
        state.recomputeMatches()
        #expect(state.matches.count == 3)

        // Switching back restores the first document's own results.
        state.activate(state.tabs[0].id)
        #expect(state.matches.count == 1)
    }

    @Test func mixesDiffAndMarkdownTabs() throws {
        let state = makeState()
        state.open(at: samples.appendingPathComponent("example.diff"))
        state.open(at: samples.appendingPathComponent("example.md"))

        #expect(state.tabs.count == 2)
        #expect(state.tabs.map(\.content) == [.diff, .markdown])
        #expect(state.content == .markdown)
        #expect(state.textDocument?.diagramCount == 3)

        // The diff tab keeps its own files and counts while Markdown is showing.
        let diffTab = try #require(state.tabs.first)
        #expect(diffTab.files.count == 4)
        #expect(state.files.isEmpty)

        state.activate(diffTab.id)
        #expect(state.files.count == 4)
        #expect(state.textDocument == nil)
    }

    @Test func reportsUnreadableFilesWithoutOpeningATab() {
        let state = makeState()
        state.open(at: URL(fileURLWithPath: "/definitely/not/here.md"))
        #expect(state.tabs.isEmpty)
        #expect(state.errorMessage?.isEmpty == false)
    }

    @Test func plainTextFilesOpenAsSource() throws {
        let state = makeState()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.log")
        try "just some text\n".write(to: url, atomically: true, encoding: .utf8)

        state.open(at: url)
        #expect(state.content == .source)
        #expect(state.readingMode == .source)
        #expect(state.textDocument?.isMarkdown == false)
    }
}
