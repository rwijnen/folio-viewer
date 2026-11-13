import Foundation

/// How a comparison of a Markdown document is drawn: the two sources side by side, or
/// one rendered page with the changes marked on it.
enum ComparisonStyle: String, Equatable {
    case source
    case rendered
}

/// The rendered comparison, ready to load.
struct RenderedComparisonPage {
    var html: String
    /// Changes exactly when the web view has to reload.
    var token: String
    var added: Int
    var removed: Int
    var modified: Int
    var isCoarse: Bool

    /// "2 added, 1 removed, 3 reworded", or that nothing reads differently.
    var summary: String {
        var parts: [String] = []
        if added > 0 { parts.append("\(added) added") }
        if removed > 0 { parts.append("\(removed) removed") }
        if modified > 0 { parts.append("\(modified) reworded") }
        if parts.isEmpty { return "Reads the same — the changes are only in the source" }
        return parts.joined(separator: ", ")
    }
}

extension DocumentTab {

    /// Whether this comparison can be drawn rendered: a Markdown document, compared with
    /// a whole other version of it. A comparison showing only the diff's own hunks has no
    /// whole document on either side to render.
    var canRenderComparison: Bool {
        guard isShowingComparison, content == .markdown, let file = loadedFile else { return false }
        return !file.document.isDiffOnly
    }

    var showsRenderedComparison: Bool {
        canRenderComparison && comparisonStyle == .rendered
    }

    /// The redline page for the comparison on screen, built once per loaded comparison
    /// and appearance.
    func renderedComparison(isDark: Bool) -> RenderedComparisonPage? {
        guard canRenderComparison, let document = loadedFile?.document else { return nil }
        let key = "\(comparisonLoadVersion)|\(isDark)"
        if let cache = renderedComparisonCache, cache.key == key { return cache.page }

        let result = RenderedDiff.compare(original: document.leftLines,
                                          updated: document.rightLines,
                                          baseURL: url.deletingLastPathComponent())
        let html = HTMLPage.wrap(body: result.bodyHTML,
                                 title: name,
                                 isDark: isDark,
                                 mermaidScript: WebResources.mermaid,
                                 diagramCount: result.diagramCount)
        let page = RenderedComparisonPage(html: html,
                                          token: "\(id.uuidString)|comparison|\(key)",
                                          added: result.addedCount,
                                          removed: result.removedCount,
                                          modified: result.modifiedCount,
                                          isCoarse: result.isCoarse)
        renderedComparisonCache = (key, page)
        return page
    }
}

extension AppState {

    /// Switches a comparison between source and rendered. Search starts again in the
    /// new one, since the two are searched by different machinery.
    func setComparisonStyle(_ style: ComparisonStyle, for requested: DocumentTab? = nil) {
        guard let tab = requested ?? active, tab.canRenderComparison, tab.comparisonStyle != style else { return }
        tab.comparisonStyle = style
        tab.renderedMatchCount = 0
        tab.renderedMatchIndex = -1
        tab.renderedFindResults = []
        guard tab.id == activeTabID else { return }
        if style == .source {
            recomputeMatches()
        } else {
            setMatches([])
        }
    }
}
