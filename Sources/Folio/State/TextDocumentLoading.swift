import AppKit
import Foundation

/// The vendored web assets. Loaded once and kept — mermaid is 3.5 MB of JavaScript.
enum WebResources {

    /// nil when the bundle was assembled without `Resources/Web/mermaid.min.js`;
    /// the page then shows the diagram source with an explanation instead of failing.
    static let mermaid: String? = {
        for candidate in mermaidCandidates() {
            if let text = try? String(contentsOf: candidate, encoding: .utf8) { return text }
        }
        return nil
    }()

    private static func mermaidCandidates() -> [URL] {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "mermaid.min", withExtension: "js") {
            candidates.append(bundled)
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("mermaid.min.js"))
        }
        // Lets the offscreen test harness (and `swift run`) find the repository copy.
        if let override = ProcessInfo.processInfo.environment["FOLIO_MERMAID_PATH"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        return candidates
    }
}

extension AppState {

    /// Extensions we treat as Markdown rather than plain source.
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx", "mdc"]
    /// Extensions that are always parsed as a unified diff.
    static let diffExtensions: Set<String> = ["diff", "patch", "rej"]

    // MARK: - Opening

    func openTextDocument(at url: URL, asMarkdown: Bool) {
        do {
            let tab = try Self.makeTextTab(at: url, asMarkdown: asMarkdown)
            adopt(tab)
            if !searchQuery.isEmpty { recomputeMatches() }
        } catch {
            errorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Reads and prepares a Markdown or plain-text document into a fresh tab.
    static func makeTextTab(at url: URL, asMarkdown: Bool) throws -> DocumentTab {
        let raw = try TextNormalizer.readText(at: url)
        let sourceLines = TextNormalizer.splitLines(raw)
        let displayLines = TextNormalizer.expandTabs(sourceLines)
        let spec = asMarkdown ? LanguageSpec.plain : LanguageCatalog.spec(forPath: url.lastPathComponent)

        var document = TextDocument(
            url: url,
            lines: displayLines,
            spans: asMarkdown
                ? MarkdownSyntax.spans(for: displayLines)
                : SyntaxHighlighter.highlight(lines: displayLines, spec: spec),
            languageName: asMarkdown ? "Markdown" : spec.name,
            isMarkdown: asMarkdown
        )
        document.maxColumns = displayLines.reduce(0) { max($0, $1.count) }

        if asMarkdown {
            let output = MarkdownConverter.convert(lines: sourceLines,
                                                   baseURL: url.deletingLastPathComponent())
            document.bodyHTML = output.bodyHTML
            document.outline = output.outline
            document.diagramCount = output.diagramCount
        }

        let tab = DocumentTab(url: url, content: asMarkdown ? .markdown : .source)
        tab.textDocument = document
        tab.readingMode = asMarkdown ? .rendered : .source
        tab.visibleAnchor = document.outline.first?.id ?? ""
        return tab
    }

    /// Re-reads the active document from disk, keeping its place in the tab bar.
    func reloadTextDocument() {
        guard let tab = active, let document = tab.textDocument else { return }
        do {
            let fresh = try Self.makeTextTab(at: document.url, asMarkdown: document.isMarkdown)
            tab.textDocument = fresh.textDocument
            tab.pageCache = nil
            tab.pageVersion += 1
            tab.diagramReport = nil
            tab.renderer.reset()
            tab.matches = []
            tab.currentMatchIndex = 0
            tab.renderedMatchCount = 0
            tab.renderedMatchIndex = -1
            if !searchQuery.isEmpty { recomputeMatches() }
            statusMessage = "Reloaded \(document.name)."
        } catch {
            errorMessage = "Could not reload \(document.name): \(error.localizedDescription)"
        }
    }

    // MARK: - Rendered-page callbacks

    /// Messages posted by a page's JavaScript. Routed by tab, because a background
    /// page can still report in while another tab is showing.
    func handleWebMessage(_ payload: [String: Any], for tabID: UUID? = nil) {
        guard let tab = tabID.flatMap({ id in tabs.first { $0.id == id } }) ?? active else { return }
        switch payload["type"] as? String {
        case "matches":
            tab.renderedMatchCount = payload["count"] as? Int ?? 0
            tab.renderedMatchIndex = tab.renderedMatchCount > 0 ? 0 : -1
        case "diagrams":
            let total = payload["total"] as? Int ?? 0
            let failed = payload["failed"] as? Int ?? 0
            if let error = payload["error"] as? String {
                tab.diagramReport = error
                statusMessage = "Diagrams could not be drawn: \(error)"
            } else if failed > 0 {
                tab.diagramReport = "\(failed) of \(total) diagrams failed"
                statusMessage = "\(failed) of \(total) mermaid diagram\(total == 1 ? "" : "s") "
                    + "could not be drawn."
            } else {
                tab.diagramReport = total == 0 ? nil : "\(total) diagram\(total == 1 ? "" : "s")"
            }
        case "anchor":
            tab.visibleAnchor = payload["anchor"] as? String ?? ""
        default:
            break
        }
    }

    func setRenderedMatchIndex(_ index: Int, for tabID: UUID? = nil) {
        let tab = tabID.flatMap { id in tabs.first { $0.id == id } } ?? active
        tab?.renderedMatchIndex = index
    }

    func focusRenderedMatch(offset: Int) {
        guard let tab = active, tab.renderedMatchCount > 0 else { return }
        let count = tab.renderedMatchCount
        let next = ((tab.renderedMatchIndex + offset) % count + count) % count
        tab.renderedFocusTarget = next
        tab.renderedMatchIndex = next
        tab.renderedFocusRequest += 1
    }

    func scrollToAnchor(_ anchor: String) {
        guard let tab = active else { return }
        tab.pendingAnchor = anchor
        tab.anchorRequest += 1
    }

    func scrollSource(to line: Int) {
        guard let tab = active else { return }
        tab.sourceScrollLine = line
        tab.sourceScrollRequest += 1
    }

    // MARK: - Modes

    func setReadingMode(_ mode: ReadingMode) {
        guard let tab = active, tab.readingMode != mode else { return }
        tab.readingMode = mode
        // The two modes have separate search machinery; re-run for the new one.
        if mode == .source {
            recomputeMatches()
        } else {
            setMatches([])
        }
    }

    func toggleReadingMode() {
        setReadingMode(readingMode == .rendered ? .source : .rendered)
    }

    // MARK: - Source-mode search

    func recomputeTextMatches() {
        guard let tab = active, let document = tab.textDocument, !searchQuery.isEmpty else {
            setMatches([])
            return
        }
        let needle = Array(searchCaseSensitive ? searchQuery : searchQuery.lowercased())
        var found: [SearchMatch] = []
        for (index, line) in document.lines.enumerated() {
            for range in AppState.occurrences(of: needle, in: line,
                                              caseSensitive: searchCaseSensitive) {
                found.append(SearchMatch(rowIndex: index, isLeft: true, range: range))
            }
        }
        setMatches(found)
    }
}
