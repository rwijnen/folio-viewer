import Foundation

/// The Find All pane: every hit of the find bar's search, listed.
///
/// It has no search of its own. The bar's query and the matches each view already keeps
/// are the source of truth, so the list and the `n of m` count cannot disagree, and a
/// row's id is the same number ⌘G steps through.
extension AppState {

    /// ⇧⌘F. Opens the bar as well, because that is where the query is typed.
    func presentFindAll() {
        guard canFind else { return }
        isFindAllPresented = true
        presentFind()
        // The bar's matches are cleared or left behind by anything that happens while the
        // pane is shut, so catch up rather than waiting for the next keystroke.
        if !searchQuery.isEmpty { refreshTextMatchesKeepingPlace() }
    }

    func closeFindAll() {
        isFindAllPresented = false
    }

    var findResults: [FindResult] {
        guard let tab = active, !searchQuery.isEmpty else { return [] }
        if searchesRenderedPage { return tab.renderedFindResults }
        // The same split `recomputeMatches` makes: a comparison is searched as a diff.
        if !tab.isShowingComparison, let document = tab.textDocument {
            return FindResults.text(matches: tab.matches,
                                    lines: searchableLines(of: tab, document: document),
                                    outline: document.outline)
        }
        guard let rows = tab.loadedFile?.document.rows else { return [] }
        return FindResults.diff(matches: tab.matches, rows: rows)
    }

    /// All the hits, which is more than `findResults` holds past `FindResults.limit`.
    var findResultTotal: Int {
        searchesRenderedPage ? renderedMatchCount : matches.count
    }

    /// The row to mark as current: the hit ⌘G and the page are on.
    var currentFindResultID: Int {
        searchesRenderedPage ? renderedMatchIndex : currentMatchIndex
    }

    /// A row was clicked: go to that hit, the same way ⌘G would.
    func focusFindResult(_ id: Int) {
        guard let tab = active else { return }
        if searchesRenderedPage {
            guard (0..<tab.renderedMatchCount).contains(id) else { return }
            tab.renderedFocusTarget = id
            tab.renderedMatchIndex = id
            tab.renderedFocusRequest += 1
            return
        }
        guard tab.matches.indices.contains(id) else { return }
        tab.currentMatchIndex = id
        focusCurrentMatch()
    }

    func setRenderedFindResults(_ results: [FindResult], for tabID: UUID) {
        tabs.first { $0.id == tabID }?.renderedFindResults = results
    }

    /// Re-reads the matches from the editor's text without moving anyone. Typing must
    /// neither pull the view to a hit nor leave rows that point at the wrong one.
    func refreshTextMatchesKeepingPlace() {
        guard let tab = active, !tab.isShowingComparison, let document = tab.textDocument,
              !searchesRenderedPage else { return }
        tab.matches = textMatches(in: tab, document: document)
        tab.currentMatchIndex = min(tab.currentMatchIndex, max(tab.matches.count - 1, 0))
    }
}
