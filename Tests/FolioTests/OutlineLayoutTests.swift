import Foundation
import Testing

@testable import Folio

private func outline(_ levels: [Int]) -> [OutlineItem] {
    levels.enumerated().map { index, level in
        OutlineItem(id: "h\(index)", level: level, title: "H\(level) #\(index)", lineIndex: index)
    }
}

private func layout(_ levels: [Int]) -> OutlineLayout {
    OutlineLayout(outline(levels))
}

@Suite("Outline tree")
struct OutlineLayoutTests {

    @Test func nestsHeadingsUnderTheirParents() {
        // H1, H2, H3, H2, H1
        let tree = layout([1, 2, 3, 2, 1])
        #expect(tree.rows.map(\.depth) == [0, 1, 2, 1, 0])
        #expect(tree.rows.map(\.hasChildren) == [true, true, false, false, false])
        #expect(tree.rows[2].parentID == "h1")
        #expect(tree.ancestors(of: "h2") == ["h0", "h1"])
    }

    @Test func handlesSkippedLevels() {
        // An H1 followed by an H3 is still parent and child.
        let tree = layout([1, 3, 3, 1])
        #expect(tree.rows.map(\.depth) == [0, 1, 1, 0])
        #expect(tree.descendants(of: "h0").sorted() == ["h1", "h2"])
    }

    @Test func handlesADocumentThatStartsDeep() {
        // Plenty of documents have no H1 at all.
        let tree = layout([2, 3, 2])
        #expect(tree.rows.map(\.depth) == [0, 1, 0])
        #expect(tree.rows[0].hasChildren)
    }

    @Test func collectsDescendantsAtEveryDepth() {
        let tree = layout([1, 2, 3, 4, 2, 1])
        #expect(tree.descendants(of: "h0").sorted() == ["h1", "h2", "h3", "h4"])
        #expect(tree.descendants(of: "h1").sorted() == ["h2", "h3"])
        #expect(tree.descendants(of: "h5").isEmpty)
    }

    @Test func hidesWhateverSitsUnderACollapsedHeading() {
        let tree = layout([1, 2, 3, 1, 2])
        let visible = tree.visibleRows(collapsed: ["h0"]).map(\.id)
        #expect(visible == ["h0", "h3", "h4"])
        // Collapsing an inner heading only hides its own.
        #expect(tree.visibleRows(collapsed: ["h1"]).map(\.id) == ["h0", "h1", "h3", "h4"])
    }

    @Test func foldsDownToAGivenNumberOfLevels() {
        let tree = layout([1, 2, 3, 1, 2, 3])
        // The whole point: a long document reduced to its top-level shape.
        let topOnly = tree.collapsed(showing: 1)
        #expect(tree.visibleRows(collapsed: topOnly).map(\.id) == ["h0", "h3"])

        let twoLevels = tree.collapsed(showing: 2)
        #expect(tree.visibleRows(collapsed: twoLevels).map(\.id) == ["h0", "h1", "h3", "h4"])

        let everything = tree.collapsed(showing: 3)
        #expect(tree.visibleRows(collapsed: everything).count == 6)
    }

    @Test func collapsingEverythingLeavesTheTopLevel() {
        let tree = layout([1, 2, 3, 1])
        let visible = tree.visibleRows(collapsed: tree.collapsibleIDs).map(\.id)
        #expect(visible == ["h0", "h3"])
    }

    @Test func highlightFallsBackToTheNearestVisibleAncestor() {
        let tree = layout([1, 2, 3])
        // Reading h2 while its parent is folded: highlight the parent that is showing.
        #expect(tree.nearestVisible(to: "h2", collapsed: ["h1"]) == "h1")
        #expect(tree.nearestVisible(to: "h2", collapsed: ["h0"]) == "h0")
        #expect(tree.nearestVisible(to: "h2", collapsed: []) == "h2")
        #expect(tree.nearestVisible(to: "nope", collapsed: []) == nil)
    }

    @Test func reportsHowDeepTheDocumentGoes() {
        #expect(layout([1, 2, 3, 4]).maximumDepth == 3)
        #expect(layout([1, 1, 1]).maximumDepth == 0)
        #expect(OutlineLayout([]).isEmpty)
        #expect(OutlineLayout([]).maximumDepth == 0)
    }

    @Test func handlesTheRealSampleDocument() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Samples/example.md")
        let text = try TextNormalizer.readText(at: url)
        let converted = MarkdownConverter.convert(lines: TextNormalizer.splitLines(text))
        let tree = OutlineLayout(converted.outline)

        #expect(tree.rows.count == converted.outline.count)
        // One H1 with everything under it, and a nested H3 under "Lists".
        #expect(tree.rows.first?.depth == 0)
        #expect(tree.rows.contains { $0.depth == 2 })
        let topOnly = tree.visibleRows(collapsed: tree.collapsed(showing: 1))
        #expect(topOnly.count < tree.rows.count)
        #expect(topOnly.allSatisfy { $0.depth == 0 })
    }
}

@Suite("Outline folding", .serialized)
@MainActor
struct OutlineFoldingTests {

    private func stateWithDocument() throws -> (AppState, URL) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-outline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("long.md")
        var text = ""
        for chapter in 1...3 {
            text += "# Chapter \(chapter)\n\nBody.\n\n"
            for section in 1...3 {
                text += "## Section \(chapter).\(section)\n\nBody.\n\n"
                text += "### Detail \(chapter).\(section).1\n\nBody.\n\n"
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        let state = AppState()
        state.open(at: url)
        return (state, folder)
    }

    @Test func foldingAChapterHidesItsSections() throws {
        let (state, folder) = try stateWithDocument()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tab = try #require(state.active)
        #expect(tab.outlineLayout.rows.count == 21)   // 3 chapters × (1 + 3 + 3)

        let firstChapter = try #require(tab.outlineLayout.rows.first).id
        state.toggleOutlineSection(firstChapter)
        let visible = tab.outlineLayout.visibleRows(collapsed: tab.collapsedOutline)
        #expect(visible.count == 15)
        #expect(visible.first?.id == firstChapter)

        state.toggleOutlineSection(firstChapter)
        #expect(tab.collapsedOutline.isEmpty)
    }

    @Test func optionClickFoldsTheWholeSubtree() throws {
        let (state, folder) = try stateWithDocument()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tab = try #require(state.active)
        let chapter = try #require(tab.outlineLayout.rows.first).id

        state.toggleOutlineSection(chapter, includingDescendants: true)
        // The chapter and each of its sections are folded, so expanding the chapter
        // again does not spill three levels at once.
        #expect(tab.collapsedOutline.count == 4)
        state.toggleOutlineSection(chapter)
        // Chapter 1 is back, but its own sections stay folded, so its details do not
        // spill out. The other two chapters were never touched.
        let visible = tab.outlineLayout.visibleRows(collapsed: tab.collapsedOutline)
        #expect(visible.count == 18)   // 21 less chapter 1's three hidden details
        let chapterOneVisible = visible.prefix(4).map(\.depth)
        #expect(chapterOneVisible == [0, 1, 1, 1])
    }

    @Test func aLongDocumentCanBeReducedToItsChapters() throws {
        let (state, folder) = try stateWithDocument()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tab = try #require(state.active)

        state.showOutlineLevels(1)
        #expect(tab.outlineLayout.visibleRows(collapsed: tab.collapsedOutline).count == 3)
        state.showOutlineLevels(2)
        #expect(tab.outlineLayout.visibleRows(collapsed: tab.collapsedOutline).count == 12)
        state.expandWholeOutline()
        #expect(tab.outlineLayout.visibleRows(collapsed: tab.collapsedOutline).count == 21)
    }

    @Test func jumpingToAFoldedHeadingUnfoldsIt() throws {
        let (state, folder) = try stateWithDocument()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tab = try #require(state.active)
        state.collapseWholeOutline()

        let buried = try #require(tab.outlineLayout.rows.first { $0.depth == 2 }).id
        #expect(!tab.outlineLayout.isVisible(buried, collapsed: tab.collapsedOutline))
        state.revealInOutline(buried)
        #expect(tab.outlineLayout.isVisible(buried, collapsed: tab.collapsedOutline))
    }

    @Test func eachDocumentFoldsIndependently() throws {
        let (state, folder) = try stateWithDocument()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try #require(state.active)
        state.collapseWholeOutline()
        #expect(!first.collapsedOutline.isEmpty)

        let second = folder.appendingPathComponent("other.md")
        try "# Other\n\n## Bit\n".write(to: second, atomically: true, encoding: .utf8)
        state.open(at: second)
        #expect(state.active?.collapsedOutline.isEmpty == true)
        #expect(!first.collapsedOutline.isEmpty)
    }

    @Test func foldedSectionsSurviveARelaunch() throws {
        let (state, folder) = try stateWithDocument()
        defer { try? FileManager.default.removeItem(at: folder); Preferences.clearSession() }
        let tab = try #require(state.active)
        state.showOutlineLevels(1)
        let folded = tab.collapsedOutline

        Preferences.saveSession(state.session)
        let next = AppState()
        next.sessionRestoreEnabled = true
        next.restoreSession()
        #expect(next.active?.collapsedOutline == folded)
    }
}
