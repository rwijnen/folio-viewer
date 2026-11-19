import Foundation
import Testing

@testable import Folio

/// A table with more columns than the reading column holds spreads across the pane.
///
/// The spreading itself is layout, done in the page, where a test on this machine cannot
/// reach it — `WKWebView` does not run without an `NSApplication`. What is checked here is
/// that every table is wrapped so it can be let out, and that the page carries the script
/// that decides which ones are. The behaviour was checked by running a generated page in a
/// browser engine: in a 1600px pane a 16-column table spread to 1536px with a 32px gutter
/// each side and no page scroll; at 2400px it took its own 2285px, centred; a two-column
/// table and a table of prose stayed in the column; and inside a rendered comparison's
/// change block it spread the same way.
@Suite("Wide tables")
struct WideTableTests {

    private func body(_ markdown: String) -> String {
        MarkdownConverter.convert(lines: markdown.components(separatedBy: "\n")).bodyHTML
    }

    private func page(_ markdown: String) -> String {
        HTMLPage.wrap(body: body(markdown), title: "t", isDark: false,
                      mermaidScript: nil, diagramCount: 0)
    }

    private let table = "| a | b |\n|---|---|\n| 1 | 2 |\n"

    @Test func everyTableIsWrapped() {
        let html = body(table)
        #expect(html.contains("<div class=\"table-wrap\">\n<table>"))
        #expect(html.contains("</table>\n</div>\n"))
        // The rows still say which source line they came from.
        #expect(html.contains("<tr data-line=\"0\">"))
        #expect(html.contains("<tr data-line=\"2\">"))
    }

    /// The wrapper belongs to the table's block, so a rendered comparison that marks the
    /// block marks the wrapper with it.
    @Test func theWrapperIsPartOfTheTablesBlock() {
        let output = MarkdownConverter.convert(lines: ("Intro.\n\n" + table).components(separatedBy: "\n"))
        let block = output.blocks.first { $0.html.contains("<table>") }
        #expect(block?.html.hasPrefix("<div class=\"table-wrap\">") == true)
        #expect(output.blocks.map(\.html).joined() == output.bodyHTML)
    }

    @Test func aPageWithATableCarriesTheScript() {
        let html = page(table)
        #expect(html.contains("is-wide"))
        #expect(html.contains("window.addEventListener('resize'"))
    }

    /// The script, not the stylesheet: the sheet is one block in every page.
    @Test func aPageWithoutATableCarriesNoScript() {
        let html = page("Just prose.\n")
        #expect(!html.contains(HTMLPage.wideTableScript))
    }

    /// The column a table must outgrow, and the gutter it keeps, are the page's own —
    /// so changing the reading width moves both together.
    @Test func theBreakoutFollowsTheReadingColumn() {
        let html = page(table)
        #expect(HTMLPage.columnWidth == HTMLPage.readingWidth - 2 * HTMLPage.sideGutter)
        #expect(html.contains("minmax(min(\(HTMLPage.columnWidth)px, 100%), max-content)"))
        #expect(html.contains("width: calc(100vw - \(2 * HTMLPage.sideGutter)px)"))
        #expect(html.contains("padding: 28px \(HTMLPage.sideGutter)px 80px"))
    }

    /// A table inside a list or a callout is indented, so letting it out would leave it
    /// lopsided; only tables at the top of the page, or of a comparison's change block,
    /// are measured.
    @Test func onlyTopLevelTablesAreLetOut() {
        let script = HTMLPage.wideTableScript
        #expect(script.contains("'#content > .table-wrap, #content > .folio-change > .table-wrap'"))
    }
}
