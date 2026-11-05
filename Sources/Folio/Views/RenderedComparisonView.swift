import AppKit
import SwiftUI
import WebKit

/// The rendered comparison: one page, the newer version, with the changes marked.
///
/// It has its own web view rather than borrowing the document's. The document's page
/// reports its scroll offset, the heading at the top and the selection, and all three
/// would be taken for the document's own; it also keeps its drawn diagrams, which a
/// comparison loaded into it would throw away. This page lives as long as the view does.
struct RenderedComparisonView: NSViewRepresentable {

    let tab: DocumentTab
    let page: RenderedComparisonPage
    let baseURL: URL?

    @Environment(AppState.self) private var state

    final class Coordinator {
        var controller: MarkdownPageController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizesSubviews = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let controller: MarkdownPageController
        if let existing = context.coordinator.controller {
            controller = existing
        } else {
            controller = MarkdownPageController(tab: tab, state: state, isComparison: true)
            context.coordinator.controller = controller
        }
        let webView = controller.webView
        if webView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }

        controller.load(html: page.html, baseURL: baseURL, token: page.token)
        controller.apply(query: state.searchQuery,
                         caseSensitive: state.searchCaseSensitive,
                         focusRequest: tab.renderedFocusRequest,
                         focusTarget: tab.renderedFocusTarget,
                         anchorRequest: 0, anchor: nil)
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        coordinator.controller?.teardown()
        coordinator.controller = nil
    }
}
