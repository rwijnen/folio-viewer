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
