import Foundation
import Testing

@testable import Folio

@MainActor
private final class Scratch {
    let folder: URL
    let url: URL
    let state = AppState()

    init(_ contents: String) throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("WP02 Sharing Concept.md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        state.reloadsChangedFilesAutomatically = false
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func open() throws -> DocumentTab {
        state.open(at: url)
        return try #require(state.active)
    }
}

private let document = """
# Sharing concept

Contacts carry **no channel**, editing is open
to anyone who can see them.

## Actors

- Direct reps see assigned accounts
- Indirect reps never see the dealer's end customer
"""

@Suite("Notes and change requests")
@MainActor
struct AnnotationsInAppTests {

    @Test func thereIsNothingToAnnotateUntilSomethingIsSelected() throws {
        let scratch = try Scratch(document)
        let tab = try scratch.open()
        #expect(!scratch.state.hasSelection(tab))

        scratch.state.beginAnnotation(.note, for: tab)
        #expect(scratch.state.annotationDraft == nil)
        #expect(scratch.state.statusMessage?.contains("Select the passage") == true)
    }

    /// The page reports the selection as it changes; the app holds the latest.
    @Test func thePageSelectionBecomesTheDraftsQuote() throws {
        let scratch = try Scratch(document)
        let tab = try scratch.open()
        scratch.state.selectionChanged(text: "no channel", lineHint: 2, for: tab.id)
        #expect(scratch.state.hasSelection(tab))

        scratch.state.beginAnnotation(.changeRequest, for: tab)
        let draft = try #require(scratch.state.annotationDraft)
        #expect(draft.kind == .changeRequest)
        #expect(draft.quote == "no channel")
    }

    @Test func clearingTheSelectionClearsIt() throws {
        let scratch = try Scratch(document)
        let tab = try scratch.open()
        scratch.state.selectionChanged(text: "no channel", lineHint: 2, for: tab.id)
        scratch.state.selectionChanged(text: "   ", lineHint: nil, for: tab.id)
        #expect(!scratch.state.hasSelection(tab))
    }

    /// The rendered selection has lost its Markdown; the annotation still lands on the
    /// right source line.
    @Test func anAnnotationIsAnchoredToTheSourceLines() throws {
        let scratch = try Scratch(document)
        let tab = try scratch.open()
        scratch.state.selectionChanged(text: "no channel", lineHint: 2, for: tab.id)
        scratch.state.beginAnnotation(.changeRequest, for: tab)
        scratch.state.annotationDraft?.comment = "Name the role explicitly."
        #expect(scratch.state.commitAnnotationDraft(for: tab))

        let annotation = try #require(tab.annotations.first)
        #expect(annotation.kind == .changeRequest)
        #expect(annotation.startLine == 2)          // the **no channel** line
        #expect(annotation.comment == "Name the role explicitly.")
        // The sheet closes and the list comes forward.
        #expect(scratch.state.annotationDraft == nil)
        #expect(tab.sidebarMode == .notes)
        // And the document itself is untouched.
        #expect(try String(contentsOf: scratch.url, encoding: .utf8) == document)
    }

    @Test func anEmptyCommentIsNotAnAnnotation() throws {
        let scratch = try Scratch(document)
        let tab = try scratch.open()
        scratch.state.selectionChanged(text: "no channel", lineHint: 2, for: tab.id)
        scratch.state.beginAnnotation(.note, for: tab)
        scratch.state.annotationDraft?.comment = "   \n "
        #expect(!scratch.state.commitAnnotationDraft(for: tab))
        #expect(tab.annotations.isEmpty)
    }

    @Test func severalAnnotationsLiveInOneDocument() throws {
        let scratch = try Scratch(document)
        let tab = try scratch.open()
        for (text, hint, kind) in [("no channel", 2, Annotation.Kind.changeRequest),
                                   ("Direct reps see assigned accounts", 7, .note),
                                   ("Actors", 5, .note)] {
            scratch.state.selectionChanged(text: text, lineHint: hint, for: tab.id)
            scratch.state.beginAnnotation(kind, for: tab)
            scratch.state.annotationDraft?.comment = "About \(text)."
            #expect(scratch.state.commitAnnotationDraft(for: tab))
        }
        #expect(tab.annotations.count == 3)

        scratch.state.removeAnnotation(tab.annotations[1], for: tab)
        #expect(tab.annotations.count == 2)
        scratch.state.removeAllAnnotations(for: tab)
        #expect(tab.annotations.isEmpty)
    }

    // MARK: - Handing them over

    @Test func theReportNamesTheFileTheLinesAndTheAsk() throws {
        let scratch = try Scratch(document)
        let tab = try scratch.open()
        scratch.state.selectionChanged(text: "no channel", lineHint: 2, for: tab.id)
        scratch.state.beginAnnotation(.changeRequest, for: tab)
        scratch.state.annotationDraft?.comment = "Split this into two sentences."
        scratch.state.commitAnnotationDraft(for: tab)

        let report = scratch.state.annotationReport(for: tab)
        #expect(report.contains("WP02 Sharing Concept.md"))
        #expect(report.contains("Change request — line 3"))
        #expect(report.contains("Contacts carry **no channel**"))   // the source, verbatim
        #expect(report.contains("Split this into two sentences."))
    }

    /// The report is built against the file as it stands, not as it stood.
    @Test func theReportReflectsLaterEdits() throws {
        let scratch = try Scratch(document)
        let tab = try scratch.open()
        scratch.state.selectionChanged(text: "Sharing concept", lineHint: 0, for: tab.id)
        scratch.state.beginAnnotation(.note, for: tab)
        scratch.state.annotationDraft?.comment = "Check the title."
        scratch.state.commitAnnotationDraft(for: tab)

        scratch.state.updateDraft("# Sharing concept, revised\n", for: tab)
        #expect(scratch.state.annotationReport(for: tab).contains("revised"))
    }

    @Test func copyingWithNothingToSaySaysSo() throws {
        let scratch = try Scratch(document)
        let tab = try scratch.open()
        scratch.state.copyAnnotationReport(for: tab)
        #expect(scratch.state.statusMessage?.contains("Nothing to copy") == true)
    }

    // MARK: - Remembered

    @Test func annotationsSurviveASession() throws {
        let scratch = try Scratch(document)
        let tab = try scratch.open()
        scratch.state.selectionChanged(text: "no channel", lineHint: 2, for: tab.id)
        scratch.state.beginAnnotation(.note, for: tab)
        scratch.state.annotationDraft?.comment = "Remembered?"
        scratch.state.commitAnnotationDraft(for: tab)

        let session = scratch.state.session
        let stored = try #require(session.entries.first?.annotations)
        #expect(stored.count == 1)
        #expect(stored[0].comment == "Remembered?")

        // A session written before notes existed still reads.
        var older = session
        older.entries[0].annotations = nil
        let data = try JSONEncoder().encode(older)
        #expect(try JSONDecoder().decode(Session.self, from: data).entries[0].annotations == nil)
    }
}

/// Notes were sometimes not highlighted, and clicking one in the sidebar did nothing.
///
/// The highlight is found from the source lines of the rendered blocks, and only
/// paragraphs, headings and callouts said which line they were on — so a note in a
/// bullet or a table cell had nowhere to be looked for, and nor did one on the third line
/// of a wrapped paragraph, which records only its first. WebKit does not run in these
/// tests; with the generated page run in WebKit, the old code marked one of five such
/// notes and this marks all five.
@Suite("Finding and going to a note")
@MainActor
struct NoteNavigationTests {

    private let source = """
    # Design

    This paragraph is wrapped
    so the words to mark
    sit on its third line.

    | Separation | Field |
    |---|---|
    | Brand | the source company |

    - First bullet
    - Second bullet
      - Nested bullet
    """

    private func html(_ text: String) -> String {
        MarkdownConverter.convert(lines: TextNormalizer.splitLines(text)).bodyHTML
    }

    @Test func listItemsTableRowsCodeAndQuotesSayWhichLineTheyAreOn() {
        let body = html(source + "\n\n> quoted\n\n```\ncode\n```\n")
        #expect(body.contains("<tr data-line=\"6\">"))             // header row
        #expect(body.contains("<tr data-line=\"8\">"))             // body row
        #expect(body.contains("<li data-line=\"10\">First bullet"))
        #expect(body.contains("<li data-line=\"11\">Second bullet"))
        #expect(body.contains("<blockquote data-line=\"14\">"))
        #expect(body.contains("<pre class=\"code\" data-line=\"16\">"))
    }

    /// A sub-list used to be numbered from the start of its parent list.
    @Test func aNestedItemCountsFromItsOwnLine() {
        #expect(html(source).contains("<li data-line=\"12\">Nested bullet"))
    }

    @Test func thePageLooksInTheBlockThatCoversTheNote() {
        let page = HTMLPage.wrap(body: "<p data-line=\"2\">x</p>", title: "t", isDark: false,
                                 mermaidScript: nil, diagramCount: 0,
                                 annotated: [.init(id: "n1", lines: 4...4, quote: "x")])
        #expect(page.contains("if (line <= from) { covering = blocks[b]; }"))
        #expect(page.contains("\"n1\""))
        #expect(page.contains("element.setAttribute('data-note', id)"))
        #expect(page.contains("window.folioRevealNote = function (id, line)"))
    }

    @Test func clickingANoteAsksThePageAndTheEditorToGoThere() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-note-nav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("design.md")
        try source.write(to: url, atomically: true, encoding: .utf8)
        let state = AppState()
        state.open(at: url)
        let tab = try #require(state.active)
        let note = Annotation(kind: .note, quote: "Second bullet", startLine: 11, endLine: 11,
                              comment: "check")
        tab.annotations = [note]

        // Rendered: the page is asked for this note, and the editor is left alone.
        state.setReadingMode(.rendered, for: tab)
        let editorBefore = tab.sourceScrollRequest
        state.revealAnnotation(note, for: tab)
        #expect(tab.noteRevealRequest == 1)
        #expect(tab.noteRevealID == note.id.uuidString)
        #expect(tab.noteRevealLine == 11)
        #expect(tab.sourceScrollRequest == editorBefore)

        // Both halves: the editor goes to the note's line as well.
        state.setReadingMode(.sideBySide, for: tab)
        state.revealAnnotation(note, for: tab)
        #expect(tab.noteRevealRequest == 2)
        #expect(tab.sourceScrollLine == 11)
        #expect(tab.sourceScrollRequest == editorBefore + 1)

        // The page it is asked of carries the note's id on the passage.
        let page = try #require(tab.renderedPage(isDark: false))
        #expect(page.contains(note.id.uuidString))
    }
}
