import AppKit
import Testing
import WebKit

@testable import Folio

/// The rendered page is an HTML string handed to WebKit, so WebKit's own Reload would
/// re-render the same bytes — the reason a right-click reload appeared to do nothing.
@Suite("Web context menu")
@MainActor
struct WebContextMenuTests {

    /// Builds a menu shaped like the one WebKit puts up over a link in a page.
    private func makeWebKitMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, identifier: String?, action: Selector? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            if let identifier { item.identifier = NSUserInterfaceItemIdentifier(identifier) }
            menu.addItem(item)
        }
        add("Open Link in New Window", identifier: "WKMenuItemIdentifierOpenLinkInNewWindow")
        add("Download Linked File", identifier: "WKMenuItemIdentifierDownloadLinkedFile")
        add("Copy Link", identifier: "WKMenuItemIdentifierCopyLink")
        menu.addItem(.separator())
        add("Back", identifier: "WKMenuItemIdentifierGoBack", action: #selector(WKWebView.goBack(_:)))
        add("Forward", identifier: "WKMenuItemIdentifierGoForward", action: #selector(WKWebView.goForward(_:)))
        add("Reload", identifier: "WKMenuItemIdentifierReload", action: #selector(WKWebView.reload(_:)))
        menu.addItem(.separator())
        add("Copy", identifier: "WKMenuItemIdentifierCopy")
        add("Look Up", identifier: "WKMenuItemIdentifierLookUp")
        return menu
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    @Test func dropsNavigationAndDownloadItems() {
        let menu = makeWebKitMenu()
        WebContextMenu.customise(menu, reloadItem: nil)
        let remaining = titles(menu)
        #expect(!remaining.contains("Reload"))
        #expect(!remaining.contains("Back"))
        #expect(!remaining.contains("Forward"))
        // A viewer that never writes to disk should not offer downloads.
        #expect(!remaining.contains("Download Linked File"))
        #expect(!remaining.contains("Open Link in New Window"))
    }

    @Test func keepsWhatIsUsefulInAViewer() {
        let menu = makeWebKitMenu()
        WebContextMenu.customise(menu, reloadItem: nil)
        let remaining = titles(menu)
        #expect(remaining.contains("Copy"))
        #expect(remaining.contains("Copy Link"))
        #expect(remaining.contains("Look Up"))
    }

    @Test func putsFoliosOwnReloadAtTheTop() {
        let menu = makeWebKitMenu()
        let reload = NSMenuItem(title: "Reload from Disk", action: nil, keyEquivalent: "r")
        WebContextMenu.customise(menu, reloadItem: reload)
        #expect(menu.items.first?.title == "Reload from Disk")
        #expect(menu.items.dropFirst().first?.isSeparatorItem == true)
        // Exactly one reload, and it is ours.
        #expect(titles(menu).filter { $0.contains("Reload") } == ["Reload from Disk"])
    }

    @Test func leavesNoStrandedSeparators() {
        let menu = makeWebKitMenu()
        WebContextMenu.customise(menu, reloadItem: nil)
        #expect(menu.items.first?.isSeparatorItem == false)
        #expect(menu.items.last?.isSeparatorItem == false)
        for (index, item) in menu.items.enumerated() where item.isSeparatorItem && index > 0 {
            #expect(menu.items[index - 1].isSeparatorItem == false)
        }
    }

    @Test func recognisesItemsByActionWhenTheIdentifierIsUnfamiliar() {
        // Guards against WebKit renaming an identifier in a future macOS release.
        let item = NSMenuItem(title: "Reload", action: #selector(WKWebView.reload(_:)),
                              keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierSomethingNew")
        #expect(WebContextMenu.shouldRemove(item))
    }

    @Test func leavesUnrelatedItemsAlone() {
        let item = NSMenuItem(title: "Speech", action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierSpeechMenu")
        #expect(!WebContextMenu.shouldRemove(item))
    }

    @Test func theWebViewOffersReloadOnlyWhenItCanHonourIt() {
        let webView = FolioWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = makeWebKitMenu()
        // No handler wired: strip WebKit's dead reload, but do not promise one of ours.
        webView.willOpenMenu(menu, with: NSEvent())
        #expect(!titles(menu).contains { $0.contains("Reload") })

        var reloaded = false
        webView.onReloadFromDisk = { reloaded = true }
        let second = makeWebKitMenu()
        webView.willOpenMenu(second, with: NSEvent())
        let ours = try? #require(second.items.first)
        #expect(ours?.title == "Reload from Disk")
        _ = ours?.target?.perform(ours?.action, with: nil)
        #expect(reloaded)
    }
}

/// Whatever asks the web view to reload must end up re-reading the file, because the
/// page WebKit holds is a string the app produced.
@Suite("Web view reload")
@MainActor
struct WebViewReloadTests {

    @Test func reloadIsRedirectedToTheFileOnDisk() {
        let webView = FolioWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var reloaded = 0
        webView.onReloadFromDisk = { reloaded += 1 }

        // This is the exact action WebKit's own menu item sends.
        webView.reload(nil)
        #expect(reloaded == 1)
    }

    @Test func fallsBackToWebKitWhenNoHandlerIsWired() {
        let webView = FolioWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // Nothing loaded and no handler: WebKit has nothing to reload, and this must
        // neither trap nor recurse.
        webView.reload(nil)
        #expect(webView.onReloadFromDisk == nil)
    }
}
