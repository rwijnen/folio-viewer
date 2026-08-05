import Foundation
import Testing

@testable import Folio

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let samples = repositoryRoot.appendingPathComponent("Samples")

private func makeDocuments(_ count: Int, diagrams: Bool = false) throws -> (folder: URL, urls: [URL]) {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("folio-scroll-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let body = (1...80).map { "Line \($0) of the document.\n" }.joined()
    let fence = diagrams ? "\n```mermaid\nflowchart TD\n  A --> B\n```\n" : ""
    let urls = try (0..<count).map { index -> URL in
        let url = folder.appendingPathComponent("doc\(index).md")
        try "# Document \(index)\n\n\(body)\(fence)".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    return (folder, urls)
}

@Suite("Scroll memory", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["FOLIO_SKIP_UI_TESTS"] == nil,
                "needs a GUI session (AppKit and WebKit views)"))
@MainActor
struct ScrollMemoryTests {

    @Test func remembersAnOffsetPerView() {
        let store = ScrollOffsetStore()
        #expect(store.offset(for: "source") == 0)
        store.record(420, for: "source")
        store.record(1080, for: "markdown-rendered")
        #expect(store.offset(for: "source") == 420)
        #expect(store.offset(for: "markdown-rendered") == 1080)
        // An unrelated view is unaffected.
        #expect(store.offset(for: "diff:abc") == 0)
        store.forgetAll()
        #expect(store.offset(for: "source") == 0)
    }

    @Test func eachDocumentHasItsOwnScrollMemory() throws {
        let state = AppState()
        let (folder, urls) = try makeDocuments(2)
        defer { try? FileManager.default.removeItem(at: folder) }

        for url in urls { state.open(at: url) }
        let first = try #require(state.tabs.first)
        let second = try #require(state.tabs.last)
        #expect(first.scrollOffsets !== second.scrollOffsets)

        first.scrollOffsets.record(300, for: first.scrollKey)
        #expect(second.scrollOffsets.offset(for: second.scrollKey) == 0)
        #expect(first.scrollOffsets.offset(for: first.scrollKey) == 300)
    }

    @Test func scrollKeyFollowsWhatTheTabIsShowing() throws {
        let state = AppState()
        let (folder, urls) = try makeDocuments(1)
        defer { try? FileManager.default.removeItem(at: folder) }

        state.open(at: urls[0])
        let tab = try #require(state.active)
        #expect(tab.scrollKey == "markdown-rendered")
        state.setReadingMode(.source)
        #expect(tab.scrollKey == "markdown-source")

        // A diff keys its position per file, so each file in it keeps its own place.
        state.open(at: samples.appendingPathComponent("example.diff"))
        let diffTab = try #require(state.active)
        let firstFile = try #require(diffTab.files.first)
        #expect(diffTab.scrollKey == "diff:\(firstFile.id.uuidString)")
        let secondFile = try #require(diffTab.files.dropFirst().first)
        state.selectFile(secondFile.id)
        #expect(diffTab.scrollKey == "diff:\(secondFile.id.uuidString)")
        #expect(diffTab.scrollKey != "diff:\(firstFile.id.uuidString)")
    }

    @Test func switchingTabsKeepsTheSameLiveWebView() throws {
        let state = AppState()
        let (folder, urls) = try makeDocuments(2)
        defer { try? FileManager.default.removeItem(at: folder) }

        for url in urls { state.open(at: url) }
        let first = try #require(state.tabs.first)
        let second = try #require(state.tabs.last)

        // Displaying a document creates its page controller.
        let firstPage = first.pageController(state: state)
        let secondPage = second.pageController(state: state)
        #expect(firstPage !== secondPage)

        state.activate(first.id)
        // Coming back must reuse the very same web view — that is what preserves the
        // scroll position and the already-drawn diagrams.
        #expect(first.pageController(state: state) === firstPage)
        #expect(first.page === firstPage)
    }

    @Test func keepsOnlyTheMostRecentlyShownPagesLoaded() throws {
        let state = AppState()
        let count = AppState.maximumLivePages + 3
        let (folder, urls) = try makeDocuments(count)
        defer { try? FileManager.default.removeItem(at: folder) }

        for url in urls {
            state.open(at: url)
            // Opening shows the document, which is when its page comes to life.
            _ = state.active?.pageController(state: state)
        }
        // The oldest tabs were unloaded to stay under the cap.
        #expect(state.tabs.filter { $0.page != nil }.count <= AppState.maximumLivePages)
        #expect(state.tabs.first?.page == nil)

        // Going back to one of them reloads it when the view displays it again, and the
        // cap still holds afterwards.
        state.activate(state.tabs[0].id)
        _ = state.active?.pageController(state: state)
        #expect(state.active?.page != nil)
        #expect(state.tabs.filter { $0.page != nil }.count <= AppState.maximumLivePages)
        // Nothing was closed, only unloaded.
        #expect(state.tabs.count == count)
    }

    @Test func aReleasedPageStillRemembersWhereItWas() throws {
        let state = AppState()
        let (folder, urls) = try makeDocuments(1)
        defer { try? FileManager.default.removeItem(at: folder) }

        state.open(at: urls[0])
        let tab = try #require(state.active)
        _ = tab.pageController(state: state)
        // The page reports its offset as the reader scrolls.
        state.handleWebMessage(["type": "anchor", "anchor": "", "scrollY": 640.0], for: tab.id)
        tab.webScrollOffset = 640

        tab.releasePage()
        #expect(tab.page == nil)
        #expect(tab.webScrollOffset == 640)

        // A fresh controller starts from that offset rather than from the top.
        _ = tab.pageController(state: state)
        #expect(tab.page != nil)
        #expect(tab.webScrollOffset == 640)
    }

    @Test func pageMessagesLandOnTheirOwnTabNotTheActiveOne() throws {
        let state = AppState()
        let (folder, urls) = try makeDocuments(2, diagrams: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for url in urls { state.open(at: url) }
        let background = try #require(state.tabs.first)
        let foreground = try #require(state.tabs.last)
        #expect(state.activeTabID == foreground.id)

        // A background page finishing its diagrams must not report into the tab the
        // reader is looking at.
        state.handleWebMessage(["type": "diagrams", "total": 1, "failed": 0], for: background.id)
        #expect(background.diagramReport == "1 diagram")
        #expect(foreground.diagramReport == nil)

        state.handleWebMessage(["type": "anchor", "anchor": "document-0", "scrollY": 12.0],
                               for: background.id)
        #expect(background.visibleAnchor == "document-0")
        #expect(foreground.visibleAnchor != "document-0")
    }

    @Test func exposesAScrollOffsetHookToThePage() {
        let page = HTMLPage.wrap(body: "<p>hi</p>", title: "t", isDark: false,
                                 mermaidScript: nil, diagramCount: 0)
        #expect(page.contains("window.folioScrollToOffset"))
        // The scroll reporter has to send the offset, or nothing can be restored.
        #expect(page.contains("scrollY: window.scrollY"))
    }
}
