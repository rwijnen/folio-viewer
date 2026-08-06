import AppKit
import WebKit

/// Trims WebKit's context menu down to what makes sense in a viewer.
///
/// The rendered page is an HTML string Folio handed to WebKit, so WebKit's own **Reload**
/// re-renders those same bytes and looks like nothing happened — it has no idea a file on
/// disk is behind them. It is replaced with Folio's *Reload from Disk*. Navigation items
/// have nothing to navigate, and a viewer that never writes to disk should not be
/// offering to download anything either.
enum WebContextMenu {

    /// WebKit tags its items with these; the identifiers are stable across macOS releases.
    static let removedIdentifiers: Set<String> = [
        "WKMenuItemIdentifierReload",
        "WKMenuItemIdentifierGoBack",
        "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierOpenImageInNewWindow",
        "WKMenuItemIdentifierOpenFrameInNewWindow",
        "WKMenuItemIdentifierOpenMediaInNewWindow",
        "WKMenuItemIdentifierDownloadImage",
        "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierDownloadMedia",
    ]

    /// Belt and braces, in case an identifier is ever renamed.
    static let removedActions: Set<Selector> = [
        #selector(WKWebView.reload(_:)),
        #selector(WKWebView.goBack(_:)),
        #selector(WKWebView.goForward(_:)),
    ]

    static func shouldRemove(_ item: NSMenuItem) -> Bool {
        if let identifier = item.identifier?.rawValue, removedIdentifiers.contains(identifier) {
            return true
        }
        if let action = item.action, removedActions.contains(action) {
            return true
        }
        return false
    }

    /// Removes the items above and puts `reloadItem` at the top of the menu.
    static func customise(_ menu: NSMenu, reloadItem: NSMenuItem?) {
        for item in menu.items where shouldRemove(item) {
            menu.removeItem(item)
        }
        tidySeparators(menu)
        guard let reloadItem else { return }
        if !menu.items.isEmpty {
            menu.insertItem(NSMenuItem.separator(), at: 0)
        }
        menu.insertItem(reloadItem, at: 0)
    }

    /// Removing items tends to leave separators stranded at the edges or doubled up.
    static func tidySeparators(_ menu: NSMenu) {
        while let first = menu.items.first, first.isSeparatorItem {
            menu.removeItem(first)
        }
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
        var index = menu.items.count - 1
        while index > 0 {
            if menu.items[index].isSeparatorItem, menu.items[index - 1].isSeparatorItem {
                menu.removeItem(at: index)
            }
            index -= 1
        }
    }
}

/// A `WKWebView` whose context menu belongs to Folio rather than to the browser.
final class FolioWebView: WKWebView {

    /// Called by the *Reload from Disk* item this view adds to the context menu.
    var onReloadFromDisk: (() -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        var reloadItem: NSMenuItem?
        if onReloadFromDisk != nil {
            let item = NSMenuItem(title: "Reload from Disk",
                                  action: #selector(reloadFromDisk),
                                  keyEquivalent: "r")
            item.keyEquivalentModifierMask = [.command]
            item.target = self
            reloadItem = item
        }
        WebContextMenu.customise(menu, reloadItem: reloadItem)
    }

    @objc private func reloadFromDisk() {
        onReloadFromDisk?()
    }

    /// The safety net. WebKit builds its context menu inside the web process, so the
    /// exact items cannot be inspected up front and the filtering above could miss one
    /// on a future macOS. Whatever route asks this view to reload — a menu item that
    /// slipped through, or ⌘R while focus is in the page — re-reading the file is the
    /// only reload that means anything here, since the page is a string we handed over.
    override func reload(_ sender: Any?) {
        guard let onReloadFromDisk else {
            super.reload(sender)
            return
        }
        onReloadFromDisk()
    }
}
