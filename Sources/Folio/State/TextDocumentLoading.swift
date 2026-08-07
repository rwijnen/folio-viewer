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
        let document = try makeTextDocument(at: url, asMarkdown: asMarkdown)
        let tab = DocumentTab(url: url, content: asMarkdown ? .markdown : .source)
        tab.textDocument = document
        tab.readingMode = asMarkdown ? .rendered : .source
        tab.visibleAnchor = document.outline.first?.id ?? ""
        return tab
    }

    /// The reading and converting on its own.
    static func makeTextDocument(at url: URL, asMarkdown: Bool) throws -> TextDocument {
        let (raw, encoding) = try TextNormalizer.read(at: url)
        return makeTextDocument(from: raw, at: url, asMarkdown: asMarkdown, encoding: encoding,
                                modificationDate: modificationDate(of: url))
    }

    /// Deliberately FileManager rather than `URL.resourceValues`: a URL caches the
    /// values it has already been asked for, so it keeps reporting the date the file had
    /// when it was opened, and nothing would ever look changed.
    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Builds a document from text in hand, which is also how an edited buffer is
    /// re-parsed for the preview and the outline without touching the disk.
    static func makeTextDocument(from raw: String, at url: URL, asMarkdown: Bool,
                                 encoding: String.Encoding = .utf8,
                                 modificationDate: Date? = nil) -> TextDocument {
        let sourceLines = TextNormalizer.splitLines(raw)
        let displayLines = TextNormalizer.expandTabs(sourceLines)
        let spec = asMarkdown ? LanguageSpec.plain : LanguageCatalog.spec(forPath: url.lastPathComponent)

        var document = TextDocument(
            url: url,
            rawText: raw,
            encoding: encoding,
            modificationDate: modificationDate,
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

        return document
    }

    /// Re-reads a document from disk, keeping its place in the tab bar and its scroll
    /// position. Defaults to the visible document.
    func reloadTextDocument(for tabID: UUID? = nil,
                            confirmingDiscard: @MainActor (String) -> Bool = AppState.askToDiscard) {
        let target = tabID.flatMap { id in tabs.first { $0.id == id } } ?? active
        guard let tab = target, let document = tab.textDocument else { return }
        // Re-reading throws away unsaved edits, so say so first.
        if tab.isDirty, !confirmingDiscard(tab.name) { return }
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
            tab.draftText = nil
            tab.editorVersion += 1
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

    // MARK: - Outline

    /// Folds a heading's contents away, or brings them back. With `includingDescendants`
    /// — ⌥-click, as in Finder — the whole subtree goes with it.
    func toggleOutlineSection(_ id: String, includingDescendants: Bool = false) {
        guard let tab = active else { return }
        let layout = tab.outlineLayout
        let isCollapsing = !tab.collapsedOutline.contains(id)
        var affected: Set<String> = [id]
        if includingDescendants {
            affected.formUnion(layout.descendants(of: id).filter { layout.row($0)?.hasChildren == true })
        }
        if isCollapsing {
            tab.collapsedOutline.formUnion(affected)
        } else {
            tab.collapsedOutline.subtract(affected)
        }
        saveSession()
    }

    /// Folds the outline down to `levels` levels, which is how a long document is made
    /// to fit on one screen.
    func showOutlineLevels(_ levels: Int) {
        guard let tab = active else { return }
        tab.collapsedOutline = tab.outlineLayout.collapsed(showing: levels)
        saveSession()
    }

    func collapseWholeOutline() {
        guard let tab = active else { return }
        tab.collapsedOutline = tab.outlineLayout.collapsibleIDs
        saveSession()
    }

    func expandWholeOutline() {
        guard let tab = active else { return }
        tab.collapsedOutline = []
        saveSession()
    }

    /// Brings a heading into view in the sidebar, unfolding whatever hides it.
    func revealInOutline(_ id: String) {
        guard let tab = active else { return }
        tab.collapsedOutline.subtract(tab.outlineLayout.ancestors(of: id))
        saveSession()
    }

    // MARK: - Modes

    func setReadingMode(_ mode: ReadingMode) {
        // Only Markdown has two modes; the menu no longer stops this being asked.
        guard let tab = active, tab.isMarkdown, tab.readingMode != mode else { return }
        // The preview should show what you just typed, not what is on disk.
        if mode == .rendered, tab.isDirty { refreshDocument(for: tab) }
        tab.readingMode = mode
        // The two modes have separate search machinery; re-run for the new one.
        if mode == .source {
            recomputeMatches()
        } else {
            setMatches([])
        }
        saveSession()
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
