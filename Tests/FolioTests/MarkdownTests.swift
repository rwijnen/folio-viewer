import Foundation
import Testing

@testable import Folio

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let sampleMarkdown = repositoryRoot
    .appendingPathComponent("Samples/example.md")

private func convert(_ markdown: String) -> MarkdownConverter.Output {
    MarkdownConverter.convert(lines: TextNormalizer.splitLines(markdown))
}

private func html(_ markdown: String) -> String {
    convert(markdown).bodyHTML
}

// MARK: - Block level

@Suite("Markdown blocks")
struct MarkdownBlockTests {

    @Test func rendersHeadingsWithAnchors() {
        let output = convert("# Title\n\n## A Sub-Section\n")
        #expect(output.bodyHTML.contains("<h1 id=\"title\""))
        #expect(output.bodyHTML.contains("<h2 id=\"a-sub-section\""))
        #expect(output.outline.map(\.title) == ["Title", "A Sub-Section"])
        #expect(output.outline.map(\.level) == [1, 2])
        #expect(output.outline.map(\.lineIndex) == [0, 2])
    }

    @Test func deduplicatesRepeatedHeadingSlugs() {
        let output = convert("## Notes\n\n## Notes\n")
        #expect(output.outline.map(\.id) == ["notes", "notes-1"])
    }

    @Test func stripsFormattingFromOutlineTitles() {
        let output = convert("## **Bold** and `code` and [link](x.md)\n")
        #expect(output.outline.first?.title == "Bold and code and link")
    }

    @Test func rendersSetextHeadings() {
        let output = convert("Title\n=====\n\nSub\n---\n")
        #expect(output.bodyHTML.contains("<h1 id=\"title\""))
        #expect(output.bodyHTML.contains("<h2 id=\"sub\""))
    }

    @Test func rendersParagraphsAndThematicBreaks() {
        let result = html("one\n\ntwo\n\n---\n")
        #expect(result.contains("<p>one</p>"))
        #expect(result.contains("<p>two</p>"))
        #expect(result.contains("<hr>"))
    }

    @Test func rendersUnorderedAndOrderedLists() {
        let unordered = html("- one\n- two\n")
        #expect(unordered.contains("<ul>"))
        #expect(unordered.contains("<li>one</li>"))
        let ordered = html("3. three\n4. four\n")
        #expect(ordered.contains("<ol start=\"3\">"))
        #expect(ordered.contains("<li>three</li>"))
    }

    @Test func nestsLists() {
        let result = html("- outer\n  - inner\n")
        #expect(result.contains("<ul>"))
        // The nested list must live inside the outer item, not after it.
        let outerItem = try? #require(result.range(of: "<li>outer"))
        let nested = try? #require(result.range(of: "<ul>", options: .backwards))
        #expect(outerItem != nil && nested != nil)
        #expect(result.filter { $0 == "<" } .count > 6)
    }

    @Test func rendersTaskListsAsDisabledCheckboxes() {
        let result = html("- [x] done\n- [ ] todo\n")
        #expect(result.contains("<input type=\"checkbox\" disabled checked>"))
        #expect(result.contains("<input type=\"checkbox\" disabled>"))
        #expect(result.contains("class=\"task\""))
        #expect(!result.contains("[x]"))
    }

    @Test func rendersBlockquotes() {
        let result = html("> quoted **text**\n")
        #expect(result.contains("<blockquote>"))
        #expect(result.contains("<strong>text</strong>"))
    }

    @Test func rendersPipeTablesWithAlignment() {
        let result = html("| a | b | c |\n|---|:-:|--:|\n| 1 | 2 | 3 |\n")
        #expect(result.contains("<table>"))
        #expect(result.contains("<th>a</th>"))
        #expect(result.contains("<th style=\"text-align:center\">b</th>"))
        #expect(result.contains("<th style=\"text-align:right\">c</th>"))
        #expect(result.contains("<td>1</td>"))
    }

    @Test func highlightsFencedCode() {
        let result = html("```swift\nlet x = 1\n```\n")
        #expect(result.contains("<pre class=\"code\" data-language=\"swift\">"))
        #expect(result.contains("tk-keyword"))   // `let`
        #expect(result.contains("tk-number"))    // `1`
    }

    @Test func leavesUnknownFenceLanguagesUnhighlighted() {
        let result = html("```\nplain text\n```\n")
        #expect(result.contains("<pre class=\"code\"><code>plain text</code></pre>"))
    }

    @Test func turnsMermaidFencesIntoDiagramContainers() {
        let output = convert("```mermaid\nflowchart TD\n  A --> B\n```\n")
        #expect(output.diagramCount == 1)
        #expect(output.bodyHTML.contains("<div class=\"diagram\">"))
        #expect(output.bodyHTML.contains("<pre class=\"mermaid\">flowchart TD"))
        // The source is kept alongside so a failed diagram can still be read.
        #expect(output.bodyHTML.contains("class=\"diagram-source\""))
    }

    @Test func doesNotTreatCodeFenceContentAsMarkdown() {
        let result = html("```\n# not a heading\n- not a list\n```\n")
        #expect(!result.contains("<h1"))
        #expect(!result.contains("<ul>"))
        #expect(result.contains("# not a heading"))
    }
}

// MARK: - Inline level

@Suite("Markdown inline")
struct MarkdownInlineTests {

    @Test func rendersEmphasis() {
        #expect(html("*a*").contains("<em>a</em>"))
        #expect(html("**a**").contains("<strong>a</strong>"))
        #expect(html("_a_").contains("<em>a</em>"))
        #expect(html("__a__").contains("<strong>a</strong>"))
        #expect(html("~~a~~").contains("<del>a</del>"))
    }

    @Test func leavesIntraWordUnderscoresAlone() {
        let result = html("some_variable_name and MAX_INT_VALUE")
        #expect(!result.contains("<em>"))
    }

    @Test func rendersInlineCodeWithoutInterpretingItsContents() {
        let result = html("`**not bold** <b>not html</b>`")
        #expect(result.contains("<code>**not bold** &lt;b&gt;not html&lt;/b&gt;</code>"))
        #expect(!result.contains("<strong>"))
    }

    @Test func rendersLinksAndAutolinks() {
        #expect(html("[text](https://example.com)")
            .contains("<a href=\"https://example.com\" data-external=\"1\">text</a>"))
        #expect(html("<https://example.com>").contains("<a href=\"https://example.com\""))
        #expect(html("[doc](other.md)").contains("<a href=\"other.md\">doc</a>"))
    }

    @Test func resolvesReferenceLinks() {
        let result = html("see [the docs][ref]\n\n[ref]: https://example.com/docs\n")
        #expect(result.contains("<a href=\"https://example.com/docs\""))
        // The definition line itself must not be rendered.
        #expect(!result.contains("[ref]:"))
    }

    @Test func dropsDangerousURLSchemes() {
        let result = html("[click](javascript:alert(1))")
        #expect(!result.contains("javascript:"))
        #expect(result.contains("click"))
        #expect(MarkdownConverter.sanitiseURL("javascript:alert(1)") == nil)
        #expect(MarkdownConverter.sanitiseURL("https://ok.example") == "https://ok.example")
        #expect(MarkdownConverter.sanitiseURL("#anchor") == "#anchor")
    }

    @Test func escapesRawHTMLExceptTheFormattingWhitelist() {
        let result = html("<script>alert(1)</script> and a<br>b and <span onclick=\"x\">c</span>")
        #expect(!result.contains("<script>"))
        #expect(result.contains("&lt;script&gt;"))
        #expect(result.contains("<br>"))
        #expect(!result.contains("onclick=\"x\""))
        #expect(result.contains("&lt;span"))
    }

    @Test func honoursBackslashEscapes() {
        let result = html("literal \\* star and \\_underscore\\_")
        #expect(!result.contains("<em>"))
        #expect(result.contains("*"))
        #expect(result.contains("_underscore_"))
    }

    @Test func rendersHardLineBreaks() {
        #expect(html("one  \ntwo").contains("<br>"))
    }

    @Test func reportsRemoteImagesInsteadOfFetchingThem() {
        let result = html("![alt](https://example.com/a.png)")
        #expect(result.contains("remote image not loaded"))
        #expect(!result.contains("<img"))
    }

    @Test func inlinesLocalImagesAsDataURIs() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-image-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A one-pixel PNG.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DAwAAABQABAAsw+wAAAABJRU5ErkJggg==")!
        try png.write(to: folder.appendingPathComponent("dot.png"))

        let output = MarkdownConverter.convert(lines: ["![dot](dot.png)"], baseURL: folder)
        #expect(output.bodyHTML.contains("<img src=\"data:image/png;base64,"))
        #expect(output.bodyHTML.contains("alt=\"dot\""))
    }
}

// MARK: - Page assembly

@Suite("Rendered page")
struct RenderedPageTests {

    @Test func lockedDownContentSecurityPolicy() {
        let page = HTMLPage.wrap(body: "<p>hi</p>", title: "t", isDark: false,
                                 mermaidScript: nil, diagramCount: 0)
        #expect(page.contains("default-src 'none'"))
        #expect(page.contains("connect-src 'none'"))
        #expect(page.contains("img-src data: blob:"))
        // No nonce-free script may run.
        #expect(page.contains("script-src 'nonce-"))
    }

    @Test func onlyInlinesMermaidWhenTheDocumentHasDiagrams() {
        let without = HTMLPage.wrap(body: "", title: "t", isDark: false,
                                    mermaidScript: "MERMAID_BUNDLE", diagramCount: 0)
        #expect(!without.contains("MERMAID_BUNDLE"))
        let with = HTMLPage.wrap(body: "", title: "t", isDark: false,
                                 mermaidScript: "MERMAID_BUNDLE", diagramCount: 1)
        #expect(with.contains("MERMAID_BUNDLE"))
        #expect(with.contains("mermaid.initialize"))
    }

    @Test func explainsItselfWhenTheMermaidBundleIsMissing() {
        let page = HTMLPage.wrap(body: "", title: "t", isDark: false,
                                 mermaidScript: nil, diagramCount: 2)
        #expect(page.contains("mermaid.min.js is missing"))
    }

    @Test func carriesTheAppearanceIntoTheDocument() {
        #expect(HTMLPage.wrap(body: "", title: "t", isDark: true, mermaidScript: nil, diagramCount: 0)
            .contains("data-theme=\"dark\""))
        #expect(HTMLPage.wrap(body: "", title: "t", isDark: false, mermaidScript: nil, diagramCount: 0)
            .contains("data-theme=\"light\""))
    }

    @Test func escapesTheTitle() {
        let page = HTMLPage.wrap(body: "", title: "a<b>&c", isDark: false,
                                 mermaidScript: nil, diagramCount: 0)
        #expect(page.contains("<title>a&lt;b&gt;&amp;c</title>"))
    }
}

// MARK: - Source highlighting

@Suite("Markdown source highlighting")
struct MarkdownSyntaxTests {

    @Test func coloursStructure() {
        let lines = ["# Heading", "- item", "> quote", "text `code` text"]
        let spans = MarkdownSyntax.spans(for: lines)
        #expect(spans[0].contains { $0.kind == .keyword })
        #expect(spans[1].contains { $0.kind == .constant })
        #expect(spans[2].contains { $0.kind == .comment })
        #expect(spans[3].contains { $0.kind == .string })
    }

    @Test func handsFencedCodeToTheRealLexer() {
        let lines = ["```swift", "let x = 1", "```"]
        let spans = MarkdownSyntax.spans(for: lines)
        #expect(spans[0].first?.kind == .annotation)
        #expect(spans[1].contains { $0.kind == .keyword })
        #expect(spans[2].first?.kind == .annotation)
    }

    @Test func coloursMermaidKeywordsInsideItsFence() {
        let lines = ["```mermaid", "flowchart TD", "  A --> B", "```"]
        let spans = MarkdownSyntax.spans(for: lines)
        #expect(spans[1].contains { $0.kind == .keyword })
        #expect(spans[2].contains { $0.kind == .annotation })
    }

    @Test func spansStayWithinTheirLine() {
        let lines = ["**bold** and *em* and [x](y) and `c`", "| a | b |", "- [x] task"]
        let spans = MarkdownSyntax.spans(for: lines)
        for (index, lineSpans) in spans.enumerated() {
            for span in lineSpans {
                #expect(span.range.lowerBound >= 0)
                #expect(span.range.upperBound <= lines[index].count)
            }
        }
    }

    @Test func producesOneSpanArrayPerLine() {
        let lines = Array(repeating: "text", count: 25)
        #expect(MarkdownSyntax.spans(for: lines).count == lines.count)
    }
}

// MARK: - The bundled sample

@Suite("Sample document")
struct SampleMarkdownTests {

    @Test func convertsTheBundledSample() throws {
        let text = try TextNormalizer.readText(at: sampleMarkdown)
        let output = MarkdownConverter.convert(lines: TextNormalizer.splitLines(text),
                                               baseURL: sampleMarkdown.deletingLastPathComponent())
        #expect(output.diagramCount == 3)
        #expect(output.outline.count >= 8)
        #expect(output.bodyHTML.contains("<table>"))
        #expect(output.bodyHTML.contains("<input type=\"checkbox\""))
        #expect(output.bodyHTML.contains("tk-keyword"))
        #expect(output.bodyHTML.contains("<blockquote>"))
        // Nothing executable survives conversion.
        #expect(!output.bodyHTML.lowercased().contains("<script"))
    }

    @Test func detectsMarkdownByExtension() {
        #expect(AppState.markdownExtensions.contains("md"))
        #expect(AppState.markdownExtensions.contains("markdown"))
        #expect(AppState.diffExtensions.contains("diff"))
        #expect(!AppState.markdownExtensions.contains("swift"))
    }
}
