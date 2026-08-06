import AppKit

/// Prints the main menu, with each item's key equivalent and whether it is enabled.
///
/// Menus are the one part of the interface that cannot be inspected from a test: a
/// disabled item silently swallows its keyboard shortcut, which is how ⌘F once went
/// missing for Markdown documents. Run it with:
///
///     /Applications/Folio.app/Contents/MacOS/Folio --dump-menu path/to/file.md
///
/// Note the app has to be activated and given a moment first — menu validation only
/// happens for an app that is actually running in the foreground, and dumping too early
/// reports every item as disabled.
enum MenuDiagnostics {

    static let flag = "--dump-menu"

    @MainActor
    static func runIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: flag) else { return false }
        let path = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : nil

        Task { @MainActor in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .seconds(2))
            if let path, !path.hasPrefix("-") {
                AppState.shared.open(at: URL(fileURLWithPath: path))
            }
            try? await Task.sleep(for: .seconds(3))
            if let menu = NSApp.mainMenu { dump(menu, depth: 0) }
            exit(0)
        }
        return true
    }

    @MainActor
    private static func dump(_ menu: NSMenu, depth: Int) {
        menu.update()   // what AppKit does before showing a menu
        for item in menu.items {
            var line = String(repeating: "  ", count: depth)
            line += item.isSeparatorItem ? "—" : item.title
            if !item.keyEquivalent.isEmpty {
                var modifiers = ""
                if item.keyEquivalentModifierMask.contains(.control) { modifiers += "^" }
                if item.keyEquivalentModifierMask.contains(.option) { modifiers += "⌥" }
                if item.keyEquivalentModifierMask.contains(.shift) { modifiers += "⇧" }
                if item.keyEquivalentModifierMask.contains(.command) { modifiers += "⌘" }
                line += "  [\(modifiers)\(item.keyEquivalent)]"
            }
            if !item.isSeparatorItem {
                line += item.isEnabled ? "  ENABLED" : "  DISABLED"
            }
            print(line)
            if let submenu = item.submenu { dump(submenu, depth: depth + 1) }
        }
    }
}
