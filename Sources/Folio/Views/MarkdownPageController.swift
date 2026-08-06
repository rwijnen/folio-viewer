import AppKit
import SwiftUI
import WebKit

/// Owns the web view for one Markdown document.
///
/// The controller lives on the `DocumentTab`, not on the SwiftUI view, so switching
/// tabs neither reloads the page nor re-draws its mermaid diagrams — the same live web
/// view is simply moved back into the window with its scroll position intact. If the
/// page is ever torn down (see `AppState.trimLivePages`), the scroll offset reported by
/// the page is replayed after the reload.
@MainActor
final class MarkdownPageController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    let webView: FolioWebView
    private weak var tab: DocumentTab?
    private weak var state: AppState?

    private var loadedToken: String?
    private var isReady = false
    private var appliedQueryKey: String?
    private var appliedFocusRequest = 0
    private var appliedAnchorRequest = 0
    private var pendingQuery: (query: String, caseSensitive: Bool)?
    /// Offset to reapply once the reloaded page has laid out.
    private var offsetToRestore: CGFloat = 0

    init(tab: DocumentTab, state: AppState) {
        self.tab = tab
        self.state = state

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = FolioWebView(frame: .zero, configuration: configuration)
        super.init()

        configuration.userContentController.add(self, name: "folio")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false
        // Right-clicking the page offers Folio's reload, which re-reads the file, rather
        // than WebKit's, which would re-render the same HTML string.
        webView.onReloadFromDisk = { [weak self] in
            guard let self, let tab = self.tab else { return }
            self.state?.reloadTextDocument(for: tab.id)
        }
    }

    /// Breaks the web view ↔ handler retain cycle before the controller is dropped.
    func teardown() {
        webView.onReloadFromDisk = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "folio")
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        webView.loadHTMLString("", baseURL: nil)
    }

    // MARK: - Loading

    func load(html: String, baseURL: URL?, token: String) {
        guard loadedToken != token else { return }
        loadedToken = token
        isReady = false
        appliedQueryKey = nil
        offsetToRestore = tab?.webScrollOffset ?? 0
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func apply(query: String, caseSensitive: Bool,
               focusRequest: Int, focusTarget: Int,
               anchorRequest: Int, anchor: String?) {
        let queryKey = "\(caseSensitive ? "s" : "i")\u{1}\(query)"
        if appliedQueryKey != queryKey {
            appliedQueryKey = queryKey
            runFind(query: query, caseSensitive: caseSensitive)
        }
        if appliedFocusRequest != focusRequest {
            appliedFocusRequest = focusRequest
            focus(index: focusTarget)
        }
        if appliedAnchorRequest != anchorRequest, let anchor {
            appliedAnchorRequest = anchorRequest
            scroll(to: anchor)
        }
    }

    // MARK: - Find

    private func runFind(query: String, caseSensitive: Bool) {
        guard isReady else {
            pendingQuery = (query, caseSensitive)
            return
        }
        webView.evaluateJavaScript("window.folioFind(\(Self.jsString(query)), \(caseSensitive))") {
            [weak self] result, _ in
            let count = (result as? Int) ?? (result as? NSNumber)?.intValue ?? 0
            Task { @MainActor in
                guard let self, let tab = self.tab else { return }
                self.state?.handleWebMessage(["type": "matches", "count": count], for: tab.id)
                if count > 0 { self.focus(index: 0) }
            }
        }
    }

    private func focus(index: Int) {
        webView.evaluateJavaScript("window.folioFocus(\(index))") { [weak self] result, _ in
            guard let value = (result as? Int) ?? (result as? NSNumber)?.intValue, value >= 0 else { return }
            Task { @MainActor in
                guard let self, let tab = self.tab else { return }
                self.state?.setRenderedMatchIndex(value, for: tab.id)
            }
        }
    }

    private func scroll(to anchor: String) {
        webView.evaluateJavaScript("window.folioScrollTo(\(Self.jsString(anchor)))")
    }

    /// Puts the page back where the reader left it. Diagrams change the layout height,
    /// so this runs again once mermaid reports in.
    private func restoreOffsetIfNeeded() {
        guard offsetToRestore > 1 else { return }
        webView.evaluateJavaScript("window.folioScrollToOffset(\(offsetToRestore))")
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        restoreOffsetIfNeeded()
        if let pending = pendingQuery {
            pendingQuery = nil
            runFind(query: pending.query, caseSensitive: pending.caseSensitive)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // In-page anchor: let WebKit scroll.
        if url.fragment != nil,
           url.absoluteString.hasPrefix(webView.url?.absoluteString.components(separatedBy: "#")[0] ?? "\u{0}") {
            decisionHandler(.allow)
            return
        }
        switch url.scheme {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        case "file":
            // A link to a neighbouring document opens in Folio; anything else in Finder.
            let ext = url.pathExtension.lowercased()
            if AppState.markdownExtensions.contains(ext) || AppState.diffExtensions.contains(ext) {
                Task { @MainActor in self.state?.open(at: url) }
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        default:
            break
        }
        decisionHandler(.cancel)
    }

    // MARK: - WKScriptMessageHandler

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }
        Task { @MainActor in
            guard let tab = self.tab else { return }
            if let offset = payload["scrollY"] as? Double {
                tab.webScrollOffset = CGFloat(offset)
            }
            self.state?.handleWebMessage(payload, for: tab.id)
            // Diagrams change the page height, so the saved offset only becomes
            // reachable once they have been drawn.
            if payload["type"] as? String == "diagrams" {
                self.restoreOffsetIfNeeded()
                self.offsetToRestore = 0
            }
        }
    }

    /// JSON-quotes a string for safe interpolation into evaluated JavaScript.
    static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }
}
