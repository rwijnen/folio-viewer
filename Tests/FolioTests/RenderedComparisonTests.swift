import Foundation
import Testing

@testable import Folio

/// The switch between a comparison's source and its rendered page, driven through the app
/// state as the menu and the picker drive it.
@Suite("Rendered comparison")
@MainActor
struct RenderedComparisonTests {

    @MainActor
    private final class Scratch {
        let folder: URL
        let url: URL
        let state = AppState()

        init(_ name: String = "note.md", contents: String) throws {
            folder = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("folio-rendered-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appendingPathComponent(name)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        /// Opens the document, edits it, and shows what arrived on disk against the edit.
        func comparison(mine: String, theirs: String) async throws -> DocumentTab {
            state.open(at: url)
            let tab = try #require(state.active)
            state.updateDraft(mine, for: tab)
            try Data(theirs.utf8).write(to: url, options: .atomic)
            state.fileChangedOnDisk(tabID: tab.id)
            state.showExternalDifference(for: tab)
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, tab.loadedFile == nil {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            _ = try #require(tab.loadedFile)
            return tab
        }
    }

    @Test func aMarkdownComparisonStartsAsSourceAndCanBeRendered() async throws {
        let scratch = try Scratch(contents: "# Notes\n\nFirst.\n")
        let tab = try await scratch.comparison(mine: "# Notes\n\nFirst, edited.\n",
                                               theirs: "# Notes\n\nFirst.\n\nSecond.\n")
        #expect(tab.canRenderComparison)
        #expect(!tab.showsRenderedComparison)
        #expect(!scratch.state.searchesRenderedPage)

        scratch.state.setComparisonStyle(.rendered, for: tab)
        #expect(tab.showsRenderedComparison)
        #expect(scratch.state.searchesRenderedPage)

        let page = try #require(tab.renderedComparison(isDark: false))
        #expect(page.html.contains("folio-change-added"))
        #expect(page.html.contains("Second."))
    }

    @Test func commandOneAndTwoChooseTheComparisonNotTheDocument() async throws {
        let scratch = try Scratch(contents: "# Notes\n\nFirst.\n")
        let tab = try await scratch.comparison(mine: "# Notes\n\nMine.\n",
                                               theirs: "# Notes\n\nTheirs.\n")
        let modeBefore = tab.readingMode

        scratch.state.setReadingMode(.rendered)
        #expect(tab.comparisonStyle == .rendered)
        scratch.state.setReadingMode(.source)
        #expect(tab.comparisonStyle == .source)
        // The document underneath was not touched.
        #expect(tab.readingMode == modeBefore)
    }

    @Test func thePageIsBuiltOnceAndRebuiltForTheOtherAppearance() async throws {
        let scratch = try Scratch(contents: "Alpha.\n")
        let tab = try await scratch.comparison(mine: "Alpha, edited.\n", theirs: "Beta.\n")
        scratch.state.setComparisonStyle(.rendered, for: tab)

        let light = try #require(tab.renderedComparison(isDark: false))
        let again = try #require(tab.renderedComparison(isDark: false))
        let dark = try #require(tab.renderedComparison(isDark: true))
        #expect(light.token == again.token)
        #expect(light.token != dark.token)
    }

    @Test func outsideAComparisonThereIsNothingToSwitch() throws {
        let scratch = try Scratch(contents: "# Notes\n")
        scratch.state.open(at: scratch.url)
        let tab = try #require(scratch.state.active)
        #expect(!tab.canRenderComparison)
        scratch.state.setComparisonStyle(.rendered, for: tab)
        #expect(tab.comparisonStyle == .source)
        #expect(tab.renderedComparison(isDark: false) == nil)
        // And ⌘2 still means the document's own source mode.
        scratch.state.setReadingMode(.source)
        #expect(tab.readingMode == .source)
    }
}
