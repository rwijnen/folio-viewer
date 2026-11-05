import Foundation
import Testing

@testable import Folio

@Suite("Rendered diff")
struct RenderedDiffTests {

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    private func changes(_ result: RenderedDiff.Result) -> [RenderedDiff.Change] {
        result.blocks.map(\.change)
    }

    // MARK: Blocks from the converter

    @Test func blocksConcatenateToTheBody() {
        let source = lines("""
        ---
        title: Notes
        ---
        # Heading

        A paragraph
        over two lines.

        - one
        - two

        ```swift
        let x = 1
        ```

        > quoted
        """)
        let output = MarkdownConverter.convert(lines: source)
        #expect(output.blocks.map(\.html).joined() == output.bodyHTML)
        #expect(output.blocks.count == 6)
    }

    @Test func blocksKnowTheirSourceLines() {
        let source = lines("# Title\n\nFirst line\nsecond line\n\n- a\n- b")
        let blocks = MarkdownConverter.convert(lines: source).blocks
        #expect(blocks.map(\.lines) == [0..<1, 2..<4, 5..<7])
    }

    @Test func nestedBlocksAreNotRecordedSeparately() {
        let source = lines("> # Inside\n>\n> a paragraph inside")
        let blocks = MarkdownConverter.convert(lines: source).blocks
        #expect(blocks.count == 1)
        #expect(blocks[0].html.hasPrefix("<blockquote"))
    }

    // MARK: Comparing

    @Test func identicalDocumentsHaveNoChanges() {
        let source = lines("# A\n\nText.\n\n- x")
        let result = RenderedDiff.compare(original: source, updated: source)
        #expect(!result.hasChanges)
        #expect(changes(result) == [.unchanged, .unchanged, .unchanged])
    }

    @Test func rewrappingAParagraphIsNotAChange() {
        let before = lines("Some words that\nwrap here.")
        let after = lines("Some words\nthat wrap here.")
        // The source differs on both lines; the page reads the same apart from where
        // the soft break falls, which renders as a space either way.
        let result = RenderedDiff.compare(original: before, updated: after)
        #expect(changes(result) == [.unchanged])
    }

    @Test func movingABlockDownDoesNotChangeTheBlocksAroundIt() {
        let before = lines("# Title\n\nFirst.\n\nSecond.")
        let after = lines("# Title\n\nAdded paragraph about something else entirely.\n\nFirst.\n\nSecond.")
        let result = RenderedDiff.compare(original: before, updated: after)
        // The heading's data-line and the paragraphs' lines all moved; only one block
        // is new.
        #expect(changes(result) == [.unchanged, .added, .unchanged, .unchanged])
    }

    @Test func aRemovedBlock() {
        let before = lines("# Title\n\nGoing away now.\n\nStaying.")
        let after = lines("# Title\n\nStaying.")
        let result = RenderedDiff.compare(original: before, updated: after)
        #expect(changes(result) == [.unchanged, .removed, .unchanged])
        #expect(result.removedCount == 1)
    }

    @Test func aRewordedParagraphIsShownOnceWithTheWordsMarked() throws {
        let before = lines("The quick brown fox jumps over the lazy dog.")
        let after = lines("The quick red fox jumps over the lazy dog.")
        let result = RenderedDiff.compare(original: before, updated: after)
        #expect(changes(result) == [.modified])
        let html = try #require(result.blocks.first?.html)
        #expect(html.contains("<del class=\"folio-word\">brown</del>"))
        #expect(html.contains("<ins class=\"folio-word\">red</ins>"))
        #expect(html.contains("fox jumps"))
    }

    @Test func aChangeAcrossMarkupKeepsTheNewerTags() throws {
        let before = lines("Make this word stand out in the sentence please.")
        let after = lines("Make this **word** stand out in the sentence please.")
        let result = RenderedDiff.compare(original: before, updated: after)
        let html = try #require(result.blocks.first?.html)
        #expect(result.blocks.first?.change == .modified)
        #expect(html.contains("<strong>"))
        #expect(html.contains("</strong>"))
        // The word itself did not change, only its emphasis.
        #expect(!html.contains("<del"))
    }

    @Test func aRewrittenParagraphIsShownAsRemovedThenAdded() {
        let before = lines("# T\n\nCompletely different words here.")
        let after = lines("# T\n\nNothing whatsoever in common now.")
        let result = RenderedDiff.compare(original: before, updated: after)
        #expect(changes(result) == [.unchanged, .removed, .added])
    }

    @Test func pairingKeepsAnInsertedParagraphApartFromTheRewordedOne() {
        let before = lines("Intro.\n\nThe meeting is on Monday at ten in the big room.")
        let after = lines("Intro.\n\nA brand new note about parking.\n\nThe meeting is on Tuesday at ten in the big room.")
        let result = RenderedDiff.compare(original: before, updated: after)
        #expect(changes(result) == [.unchanged, .added, .modified])
    }

    @Test func aChangedCodeBlockIsNeverMergedWordByWord() {
        let before = lines("```swift\nlet value = 1\nprint(value)\n```")
        let after = lines("```swift\nlet value = 2\nprint(value)\n```")
        let result = RenderedDiff.compare(original: before, updated: after)
        #expect(changes(result) == [.removed, .added])
    }

    @Test func aChangedDiagramIsDrawnBeforeAndAfter() {
        let before = lines("```mermaid\nflowchart TD\n  A --> B\n```")
        let after = lines("```mermaid\nflowchart TD\n  A --> C\n```")
        let result = RenderedDiff.compare(original: before, updated: after)
        #expect(changes(result) == [.removed, .added])
        #expect(result.diagramCount == 2)
    }

    @Test func aChangedLinkDefinitionChangesTheParagraphsThatUseIt() {
        let before = lines("See [the docs][d].\n\n[d]: https://example.com/old")
        let after = lines("See [the docs][d].\n\n[d]: https://example.com/new")
        let result = RenderedDiff.compare(original: before, updated: after)
        #expect(result.hasChanges)
    }

    @Test func aHeadingWhoseIdShiftsIsUnchanged() {
        // Adding a second "Notes" above the first gives the first a new id, notes-1.
        let before = lines("## Notes\n\nBody.")
        let after = lines("## Notes\n\nNew text in a new section.\n\n## Notes\n\nBody.")
        let result = RenderedDiff.compare(original: before, updated: after)
        #expect(result.addedCount == 2)
        #expect(result.removedCount == 0)
        #expect(result.modifiedCount == 0)
    }

    @Test func removedBlocksLoseTheirIdsAndLines() throws {
        let before = lines("## Going\n\nStays.")
        let after = lines("Stays.")
        let result = RenderedDiff.compare(original: before, updated: after)
        let removed = try #require(result.blocks.first { $0.change == .removed })
        #expect(!removed.html.contains("id="))
        #expect(!removed.html.contains("data-line="))
    }

    @Test func theBodyWrapsAndNumbersOnlyTheChanges() {
        let before = lines("Same.\n\nOld paragraph about nothing.")
        let after = lines("Same.\n\nAll new words entirely here.\n\nAnother new one.")
        let body = RenderedDiff.compare(original: before, updated: after).bodyHTML
        #expect(body.hasPrefix("<p data-line=\"0\">Same.</p>"))
        #expect(body.contains("id=\"folio-change-1\""))
        #expect(body.contains("id=\"folio-change-3\""))
        #expect(!body.contains("id=\"folio-change-4\""))
    }

    // MARK: Marking words

    @Test func entitiesAreNeverCutInTwo() throws {
        let merged = try #require(RenderedDiff.mergedHTML(from: "<p>a &amp; b c d</p>",
                                                          to: "<p>a &lt; b c d</p>"))
        #expect(merged.contains("<del class=\"folio-word\">&amp;</del>"))
        #expect(merged.contains("<ins class=\"folio-word\">&lt;</ins>"))
    }

    @Test func insertedTextIsNotWrappedAcrossTags() throws {
        let merged = try #require(RenderedDiff.mergedHTML(
            from: "<p>one two three four</p>",
            to: "<p>one two three four <em>five six</em></p>"))
        #expect(merged.contains("<em><ins class=\"folio-word\">five six</ins></em>"))
    }

    @Test func theSpaceAfterAnInsertedWordIsNotHighlighted() throws {
        let merged = try #require(RenderedDiff.mergedHTML(
            from: "<p>after the team has signed off</p>",
            to: "<p>after the whole team has signed off</p>"))
        #expect(merged.contains("the <ins class=\"folio-word\">whole</ins> team"))
    }

    @Test func tooDifferentToMergeIsNil() {
        #expect(RenderedDiff.mergedHTML(from: "<p>alpha beta gamma</p>",
                                        to: "<p>one two three</p>") == nil)
    }
}
