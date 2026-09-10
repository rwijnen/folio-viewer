import AppKit
import Foundation

/// Grouping the open documents into projects.
///
/// A group is a name a document carries, taken from its folder unless the reader has
/// said otherwise, and selecting one filters the tab bar to it. Nothing is closed or
/// reloaded by switching: a hidden tab keeps its scroll position, its git status, its
/// unsaved draft and its live page, and comes back exactly as it was.
extension AppState {

    /// Every group with at least one document open, alphabetically.
    var groups: [String] { DocumentGroup.listed(from: tabs.map(\.group)) }

    /// The tabs the tab bar shows.
    var visibleTabs: [DocumentTab] {
        guard let selectedGroup else { return tabs }
        return tabs.filter { $0.group == selectedGroup }
    }

    /// How many documents are in a group, for the dropdown.
    func documentCount(inGroup group: String) -> Int {
        tabs.count { $0.group == group }
    }

    // MARK: - Choosing one

    /// Filters the tab bar. `nil` shows everything.
    ///
    /// Selecting a group brings one of its documents to the front, because the alternative
    /// is a window showing a document that the tab bar says is not open.
    func selectGroup(_ group: String?) {
        guard selectedGroup != group else { return }
        setSelectedGroup(group)
        guard let active, !visibleTabs.contains(where: { $0.id == active.id }) else {
            saveSession()
            return
        }
        if let first = visibleTabs.first { activate(first.id) }
        saveSession()
    }

    /// Makes sure a tab about to come forward is one the tab bar is showing.
    func revealGroup(of tab: DocumentTab) {
        guard let selectedGroup, tab.group != selectedGroup else { return }
        setSelectedGroup(tab.group)
    }

    /// Drops the filter when the group it names has no documents left in it.
    func forgetEmptyGroup() {
        guard let selectedGroup, documentCount(inGroup: selectedGroup) == 0 else { return }
        setSelectedGroup(nil)
    }

    // MARK: - Putting a document in one

    /// Moves a document to a group, or back to being named after its folder.
    func assign(_ tab: DocumentTab, to group: String?) {
        let previous = tab.group
        tab.groupOverride = group.flatMap(DocumentGroup.sanitised)
        // Follow the document rather than leaving it hidden behind the old filter.
        if selectedGroup == previous, tab.group != previous, tab.id == activeTabID {
            setSelectedGroup(tab.group)
        }
        forgetEmptyGroup()
        saveSession()
    }

    /// Asks for a name and moves the document into it.
    func assignToNewGroup(_ tab: DocumentTab,
                          askingForName: @MainActor (String) -> String? = AppState.askForGroupName) {
        guard let name = askingForName(tab.name).flatMap(DocumentGroup.sanitised) else { return }
        assign(tab, to: name)
    }

    static func askForGroupName(_ documentName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "New group"
        alert.informativeText = "\(documentName) will be moved into it."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Project name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
