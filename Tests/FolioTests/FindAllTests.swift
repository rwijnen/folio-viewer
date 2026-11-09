import Foundation
import Testing

@testable import Folio

private func match(_ row: Int, _ range: Range<Int>, isLeft: Bool = true) -> SearchMatch {
    SearchMatch(rowIndex: row, isLeft: isLeft, range: range)
}

@Suite("Find All results")
struct FindResultsTests {

    @Test func aHitIsCutOutOfItsLine() throws {
        let result = try #require(FindResults.text(matches: [match(0, 8..<14)],
                                                   lines: ["    the needle here   "],
                                                   outline: []).first)
        #expect(result.before == "the ")
        #expect(result.match == "needle")
        #expect(result.after == " here")
        #expect(result.location == "1")
        #expect(result.section == nil)
    }

    @Test func longContextIsClippedOnBothSides() throws {
        let before = String(repeating: "a", count: 100)
        let after = String(repeating: "b", count: 300)
        let result = try #require(FindResults.text(matches: [match(0, 100..<103)],
                                                   lines: [before + "hit" + after],
                                                   outline: []).first)
        #expect(result.before == "…" + String(repeating: "a", count: FindResults.charactersBefore))
        #expect(result.after == String(repeating: "b", count: FindResults.charactersAfter) + "…")
    }

    /// `lowercased()` can change a string's length, and the ranges come from that.
    @Test func aRangeBeyondTheLineDoesNotTrap() throws {
        let result = try #require(FindResults.text(matches: [match(0, 3..<9)], lines: ["abcd"],
                                                   outline: []).first)
        #expect(result.match == "d")
        #expect(result.after.isEmpty)
    }

    @Test func aHitBelongsToTheHeadingAboveIt() {
        let outline = [OutlineItem(id: "a", level: 1, title: "Alpha", lineIndex: 1),
                       OutlineItem(id: "b", level: 2, title: "Beta", lineIndex: 4)]
        let lines = Array(repeating: "x", count: 8)
        let results = FindResults.text(matches: [match(0, 0..<1), match(1, 0..<1),
                                                 match(3, 0..<1), match(4, 0..<1), match(7, 0..<1)],
                                       lines: lines, outline: outline)
        #expect(results.map(\.section) == [nil, "Alpha", "Alpha", "Beta", "Beta"])
    }

    @Test func diffResultsSayWhichSideAndKeepTheirMatchIndex() {
        let rows = [DiffRow(id: 0, kind: .modified,
                            left: DiffCell(number: 7, text: "old text", characterCount: 8),
                            right: DiffCell(number: 9, text: "new text", characterCount: 8))]
        let results = FindResults.diff(matches: [match(0, 4..<8), match(0, 4..<8, isLeft: false)],
                                       rows: rows)
        #expect(results.map(\.location) == ["old 7", "new 9"])
        #expect(results.map(\.id) == [0, 1])
        #expect(results.map(\.before) == ["old ", "new "])
    }

    @Test func theListStopsAtTheLimit() {
        let matches = (0..<(FindResults.limit + 50)).map { match(0, $0..<($0 + 1)) }
        let line = String(repeating: "x", count: FindResults.limit + 50)
        #expect(FindResults.text(matches: matches, lines: [line], outline: []).count == FindResults.limit)
    }

    @Test func thePagesReportIsNumberedInItsOwnOrder() {
        let results = FindResults.page([
            ["section": "Intro", "before": "a ", "match": "hit", "after": " b"],
            ["section": "", "before": "", "match": "hit", "after": ""],
        ])
        #expect(results.map(\.id) == [0, 1])
        #expect(results[0].section == "Intro")
        #expect(results[1].section == nil)
        #expect(results[0].before == "a ")
    }

    /// A heading that comes round again is a new group, and its id must still be unique.
    @Test func groupsAreRunsOfOneHeading() {
        let results = ["A", "A", nil, "A"].enumerated().map { index, section in
            FindResult(id: index, section: section, before: "", match: "x", after: "")
        }
        let groups = FindResults.groups(results)
        #expect(groups.map(\.title) == ["A", nil, "A"])
        #expect(groups.map(\.id) == [0, 2, 3])
        #expect(groups[0].results.count == 2)
    }

    @Test func thePageCarriesTheScriptThePaneAsks() {
        let html = HTMLPage.wrap(body: "<p>x</p>", title: "t", isDark: false,
                                 mermaidScript: nil, diagramCount: 0)
        #expect(html.contains("window.folioFindResults"))
        // Escaped once for Swift, so the page itself must end up with a regex and a newline.
        #expect(html.contains("replace(/\\s+/g, ' ')"))
        #expect(html.contains("split('\\n')"))
    }
}

@Suite("Find All pane", .serialized)
@MainActor
struct FindAllStateTests {

    private func openDocument(_ text: String = "# One\n\nneedle\n\n# Two\n\nneedle needle\n")
        throws -> (state: AppState, folder: URL) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-find-all-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("note.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let state = AppState()
        state.open(at: url)
        return (state, folder)
    }

    @Test func findAllIsSafeWithNothingOpen() {
        let state = AppState()
        state.presentFindAll()
        state.focusFindResult(3)
        #expect(!state.isFindAllPresented)
        #expect(!state.isFindPresented)
        #expect(state.findResults.isEmpty)
    }

    @Test func findAllOpensTheBarAndAsksItForFocus() throws {
        let (state, folder) = try openDocument()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = state.findFocusRequest
        state.presentFindAll()
        #expect(state.isFindAllPresented)
        #expect(state.isFindPresented)
        #expect(state.findFocusRequest > before)
    }

    @Test func hidingTheBarClosesTheList() throws {
        let (state, folder) = try openDocument()
        defer { try? FileManager.default.removeItem(at: folder) }
        state.presentFindAll()
        state.dismissFind()
        #expect(!state.isFindAllPresented)
        #expect(!state.isFindPresented)
    }

    @Test func closingTheListLeavesTheBar() throws {
        let (state, folder) = try openDocument()
        defer { try? FileManager.default.removeItem(at: folder) }
        state.presentFindAll()
        state.closeFindAll()
        #expect(!state.isFindAllPresented)
        #expect(state.isFindPresented)
    }

    @Test func sourceHitsAreListedUnderTheirHeadings() throws {
        let (state, folder) = try openDocument()
        defer { try? FileManager.default.removeItem(at: folder) }
        state.setReadingMode(.source)
        state.searchQuery = "needle"
        state.recomputeMatches()
        #expect(state.findResults.map(\.section) == ["One", "Two", "Two"])
        #expect(state.findResultTotal == 3)
    }

    @Test func clickingASourceRowGoesThere() throws {
        let (state, folder) = try openDocument()
        defer { try? FileManager.default.removeItem(at: folder) }
        state.setReadingMode(.source)
        state.searchQuery = "needle"
        state.recomputeMatches()
        let before = state.scrollRequest

        state.focusFindResult(2)
        #expect(state.currentMatchIndex == 2)
        #expect(state.currentFindResultID == 2)
        #expect(state.scrollRequest > before)

        // Same row again, after the reader has scrolled away.
        let again = state.scrollRequest
        state.focusFindResult(2)
        #expect(state.scrollRequest > again)
    }

    @Test func clickingARenderedRowAsksThePage() throws {
        let (state, folder) = try openDocument()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tab = try #require(state.active)
        state.searchQuery = "needle"
        state.handleWebMessage(["type": "matches", "count": 3], for: tab.id)
        state.setRenderedFindResults(FindResults.page([["match": "needle"]]), for: tab.id)
        #expect(state.findResults.count == 1)
        let before = state.renderedFocusRequest

        state.focusFindResult(2)
        #expect(state.renderedFocusTarget == 2)
        #expect(state.renderedMatchIndex == 2)
        #expect(state.renderedFocusRequest > before)

        state.focusFindResult(99)
        #expect(state.renderedFocusTarget == 2)
    }

    @Test func outOfRangeRowsAreIgnored() throws {
        let (state, folder) = try openDocument()
        defer { try? FileManager.default.removeItem(at: folder) }
        state.setReadingMode(.source)
        state.searchQuery = "needle"
        state.recomputeMatches()
        state.focusFindResult(99)
        #expect(state.currentMatchIndex == 0)
    }

    /// Used to clear the matches, leaving the bar saying "no results" beside highlights.
    @Test func sideBySideKeepsItsMatches() throws {
        let (state, folder) = try openDocument()
        defer { try? FileManager.default.removeItem(at: folder) }
        state.setReadingMode(.source)
        state.searchQuery = "needle"
        state.recomputeMatches()
        state.setReadingMode(.sideBySide)
        #expect(state.findResultTotal == 3)
    }

    @Test func typingKeepsTheRowsRightWithoutMovingTheView() throws {
        let (state, folder) = try openDocument()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tab = try #require(state.active)
        state.setReadingMode(.source)
        state.presentFindAll()
        state.searchQuery = "needle"
        state.recomputeMatches()
        state.focusFindResult(2)
        let before = state.scrollRequest

        state.updateDraft("# One\n\nneedle\n", for: tab)
        #expect(state.findResultTotal == 1)
        #expect(state.currentMatchIndex == 0)
        #expect(state.scrollRequest == before)
    }
}
