import Foundation

/// What one pane draws, decided from the document it is drawing.
///
/// This exists because of a bug that reached a release. Every per-pane view read the
/// app's forwarding accessors — `state.renderedPage`, `state.readingMode` and the rest —
/// which resolve to *whichever document is in front*. With one pane that is always the
/// right answer, so the mistake was invisible until there were two, and then both panes
/// drew the front document while their headers named different files.
///
/// Reading the wrong thing inside a view body is not something a test on this machine can
/// catch: SwiftUI bodies are not reachable, and a `WKWebView` does not run without an
/// `NSApplication`. So the decision is made here instead, on the tab, where it has no way
/// to ask what is in front because it has no reference to the app at all. A test can then
/// check it, and reintroducing the bug means deleting this and putting the accessors back
/// rather than doing it by accident.
struct PaneRendering: Equatable {

    enum Kind: Equatable {
        /// A commit from this document's history.
        case commit
        /// The version on disk against the one being edited.
        case externalChange
        /// The last commit against what is here now.
        case workingChanges
        /// The Markdown source, editable.
        case editor
        /// The rendered page.
        case rendered
        /// Anything Folio does not render: plain text, an unknown extension.
        case listing
    }

    var kind: Kind
    /// The page to load, for `.rendered` only.
    var html: String?
    /// Changes exactly when the web view has to reload.
    var token: String
}

extension DocumentTab {

    /// The pane for this document. Depends on nothing outside the tab but the theme.
    func paneRendering(isDark: Bool) -> PaneRendering {
        if viewingCommit != nil { return PaneRendering(kind: .commit, html: nil, token: id.uuidString) }
        if pane == .externalChange {
            return PaneRendering(kind: .externalChange, html: nil, token: id.uuidString)
        }
        if pane == .workingChanges {
            return PaneRendering(kind: .workingChanges, html: nil, token: id.uuidString)
        }
        guard let document = textDocument, document.isMarkdown else {
            return PaneRendering(kind: .listing, html: nil, token: renderedPageToken)
        }
        if readingMode == .source, isEditable {
            return PaneRendering(kind: .editor, html: nil, token: renderedPageToken)
        }
        guard readingMode == .rendered, let html = renderedPage(isDark: isDark) else {
            return PaneRendering(kind: .listing, html: nil, token: renderedPageToken)
        }
        return PaneRendering(kind: .rendered, html: html, token: renderedPageToken)
    }
}
