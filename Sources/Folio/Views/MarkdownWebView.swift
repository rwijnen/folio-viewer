import AppKit
import SwiftUI
import WebKit

/// Hosts the rendered Markdown page.
///
/// This is only a container: the web view itself belongs to the document's
/// `MarkdownPageController`, so it survives tab switches with its scroll position and
/// its drawn diagrams. Switching back re-parents the same view rather than reloading.
struct MarkdownWebView: NSViewRepresentable {

    let tab: DocumentTab
    /// Full page HTML.
    let html: String
    /// Changes exactly when a reload is needed.
    let token: String
    let baseURL: URL?
    /// Search and navigation state, passed explicitly so SwiftUI re-invokes `updateNSView`.
    let query: String
    let caseSensitive: Bool
    let focusRequest: Int
    let focusTarget: Int
    let anchorRequest: Int
    let anchor: String?

    @Environment(AppState.self) private var state

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizesSubviews = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let controller = tab.pageController(state: state)
        let webView = controller.webView

        if webView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }

        controller.load(html: html, baseURL: baseURL, token: token)
        controller.apply(query: query, caseSensitive: caseSensitive,
                         focusRequest: focusRequest, focusTarget: focusTarget,
                         anchorRequest: anchorRequest, anchor: anchor)
    }
}
