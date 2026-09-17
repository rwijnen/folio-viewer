import Foundation
import Testing

@testable import Folio

@Suite("Annotation report")
struct AnnotationReportTests {

    private let file = URL(fileURLWithPath: "/Users/you/vault/01 - Clients/Miele/WP02.md")
    private let root = URL(fileURLWithPath: "/Users/you/vault", isDirectory: true)

    private let source = [
        "# Sharing concept",                       // 0
        "",                                        // 1
        "Contacts carry no channel, editing open", // 2
        "to anyone who can see them.",             // 3
        "",                                        // 4
        "## Actors",                               // 5
        "",                                        // 6
        "Every sales actor is on Sales Cloud.",    // 7
    ]

    private func annotation(_ kind: Annotation.Kind, _ quote: String,
                            _ lines: ClosedRange<Int>, _ comment: String) -> Annotation {
        Annotation(kind: kind, quote: quote, startLine: lines.lowerBound,
                   endLine: lines.upperBound, comment: comment)
    }

    @Test func theReportNamesTheFileFirst() {
        let report = AnnotationReport.text(
            for: [annotation(.changeRequest, "Contacts carry no channel", 2...3, "Split this.")],
            file: file, sourceLines: source, relativeTo: root)

        // Repository-relative, because that is what an assistant can act on.
        #expect(report.hasPrefix("# Requested changes to `01 - Clients/Miele/WP02.md`"))
        #expect(!report.contains("/Users/you/vault/01"))
    }

    @Test func withNoRepositoryItFallsBackToTheFullPath() {
        let report = AnnotationReport.text(
            for: [annotation(.note, "x", 0...0, "y")],
            file: file, sourceLines: source, relativeTo: nil)
        #expect(report.contains("/Users/you/vault/01 - Clients/Miele/WP02.md"))
    }

    /// The whole point: the assistant is told which lines, what is there now, and what to do.
    @Test func eachItemCarriesItsLinesTheSourceAndTheAsk() {
        let report = AnnotationReport.text(
            for: [annotation(.changeRequest, "Contacts carry no channel", 2...3,
                             "Split this into two sentences.")],
            file: file, sourceLines: source, relativeTo: root)

        #expect(report.contains("## 1. Change request — lines 3–4"))
        #expect(report.contains("Contacts carry no channel, editing open"))
        #expect(report.contains("to anyone who can see them."))
        #expect(report.contains("**Change requested:**"))
        #expect(report.contains("Split this into two sentences."))
    }

    @Test func aSingleLineReadsAsOne() {
        let report = AnnotationReport.text(
            for: [annotation(.note, "Actors", 5...5, "Is this the right word?")],
            file: file, sourceLines: source, relativeTo: root)
        #expect(report.contains("## 1. Note — line 6"))
        #expect(report.contains("**Note:**"))
    }

    @Test func itemsAreOrderedByWhereTheyAppear() {
        let report = AnnotationReport.text(for: [
            annotation(.note, "Sales Cloud", 7...7, "Second in the file."),
            annotation(.changeRequest, "Sharing concept", 0...0, "First in the file."),
        ], file: file, sourceLines: source, relativeTo: root)

        let first = try! #require(report.range(of: "First in the file."))
        let second = try! #require(report.range(of: "Second in the file."))
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test func theSummaryCountsBothKinds() {
        #expect(AnnotationReport.summary(of: [
            annotation(.changeRequest, "a", 0...0, "x"),
            annotation(.changeRequest, "b", 1...1, "y"),
            annotation(.note, "c", 2...2, "z"),
        ]) == "2 change requests and 1 note.")
        #expect(AnnotationReport.summary(of: [annotation(.note, "a", 0...0, "x")]) == "1 note.")
    }

    /// A rendered selection loses the Markdown that produced it, so quoting it back only
    /// helps when the source above does not already say it plainly.
    @Test func theSelectionIsRepeatedOnlyWhenTheSourceDoesNotShowIt() {
        let plain = AnnotationReport.text(
            for: [annotation(.note, "Contacts carry no channel", 2...3, "x")],
            file: file, sourceLines: source, relativeTo: root)
        #expect(!plain.contains("Selected text:"))

        // Markdown the reader never saw: the rendered selection reads differently.
        let styled = ["Contacts carry **no channel**, editing open"]
        let report = AnnotationReport.text(
            for: [annotation(.note, "no channel editing", 0...0, "x")],
            file: file, sourceLines: styled, relativeTo: root)
        #expect(report.contains("Selected text:"))
    }

    @Test func aLongPassageIsTrimmedRatherThanPastedWhole() {
        let long = (1...40).map { "line \($0)" }
        let trimmed = AnnotationReport.source(
            for: annotation(.note, "", 0...39, "x"), in: long)
        #expect(trimmed.count == AnnotationReport.contextLimit + 1)
        #expect(trimmed.last?.contains("more lines") == true)
    }

    /// The file may have been edited since the note was written.
    @Test func linesBeyondTheEndOfTheFileDoNotCrashOrLie() {
        let report = AnnotationReport.text(
            for: [annotation(.note, "gone", 900...950, "Still here?")],
            file: file, sourceLines: source, relativeTo: root)
        #expect(!report.isEmpty)
        #expect(report.contains("Still here?"))

        #expect(AnnotationReport.source(for: annotation(.note, "", 0...0, "x"), in: []).isEmpty)
    }

    @Test func nothingToReportIsEmpty() {
        #expect(AnnotationReport.text(for: [], file: file, sourceLines: source).isEmpty)
    }
}


/// The rendered page is what reports a selection and what shows the marks, so both have
/// to actually reach the HTML.
@Suite("Annotations in the page")
struct AnnotationPageTests {

    private func page(annotated: [ClosedRange<Int>]) -> String {
        HTMLPage.wrap(body: "<p data-line=\"2\">hello</p>", title: "t", isDark: false,
                      mermaidScript: nil, diagramCount: 0, annotated: annotated)
    }

    @Test func thePageReportsTheSelectionAsItChanges() {
        let html = page(annotated: [])
        #expect(html.contains("selectionchange"))
        #expect(html.contains("'type': 'selection'") || html.contains("type: 'selection'"))
        // The line comes from the nearest block that records one.
        #expect(html.contains("data-line"))
    }

    @Test func annotatedLinesAreMarkedAndUnannotatedOnesAreNot() {
        #expect(page(annotated: [2...4]).contains("[2,4]"))
        #expect(page(annotated: [2...4]).contains("folio-annotated"))
        #expect(page(annotated: [1...1, 7...9]).contains("[1,1],[7,9]"))

        // No annotations, no marking script at all — nothing to paint. The style rule
        // stays in the sheet either way, which is why the test looks for the script.
        #expect(!page(annotated: []).contains("var ranges = ["))
        #expect(page(annotated: [1...1]).contains("var ranges = ["))
    }

    @Test func theMarkHasAColourInBothThemes() {
        #expect(page(annotated: [1...1]).contains("--annotated:"))
        #expect(page(annotated: [1...1]).contains(".folio-annotated"))
    }
}
