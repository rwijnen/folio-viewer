import SwiftUI

/// The project dropdown, beside the document's name in the title bar.
///
/// Shown only once there is more than one group to choose between; with everything in one
/// folder it would be a control with a single option.
struct GroupPicker: View {

    @Environment(AppState.self) private var state

    var body: some View {
        if !state.groups.isEmpty {
            Menu {
                Button { state.selectGroup(nil) } label: {
                    Text(tick(nil) + "All documents (\(state.tabs.count))")
                }
                Divider()
                if state.ungroupedCount > 0 {
                    // Said out loud, because with manual filing most documents start here
                    // and "why is my file not in any project" should not need working out.
                    Text("\(state.ungroupedCount) not in a group")
                }
                ForEach(state.groups, id: \.self) { group in
                    Button { state.selectGroup(group) } label: {
                        Text(tick(group) + "\(group) (\(state.documentCount(inGroup: group)))")
                    }
                }
            } label: {
                GroupPickerLabel(group: state.selectedGroup)
            }
            .help("Show one project's documents, or all of them")
            .fixedSize()
        }
    }

    /// A tick in the title rather than a disabled row, so the current choice reads at a
    /// glance and every row stays clickable.
    private func tick(_ group: String?) -> String {
        state.selectedGroup == group ? "✓ " : "   "
    }
}


/// The dropdown's own label. Separate from the `Menu` so it can be rendered on its own
/// for checking — a `Menu` comes out blank offscreen.
struct GroupPickerLabel: View {

    let group: String?

    var body: some View {
        Label(group ?? "All documents",
              systemImage: group == nil ? "square.stack" : "folder")
            // Both, always. A toolbar will happily reduce a Label to its icon, and an
            // unlabelled icon does not tell anyone which project they are looking at.
            .labelStyle(.titleAndIcon)
            // A folder someone named at length must not push the rest of the toolbar
            // off the end of the window.
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 200, alignment: .leading)
    }
}

/// Filing one document, from its own context menu.
///
/// A separate view rather than inline in the tab's menu: built in place it grew past what
/// the type-checker would accept, and this is the only place a document's group changes.
struct TabGroupMenu: View {

    @Environment(AppState.self) private var state
    let tab: DocumentTab

    var body: some View {
        Menu(tab.group.map { "Group: \($0)" } ?? "Add to Group") {
            Button("New Group…") { state.assignToNewGroup(tab) }
            if !state.groups.isEmpty {
                Divider()
                ForEach(state.groups, id: \.self) { group in
                    Button(label(for: group)) { state.assign(tab, to: group) }
                }
            }
            if tab.group != nil {
                Divider()
                Button("Remove from Group") { state.assign(tab, to: nil) }
            }
        }
    }

    /// A tick in the title rather than a disabled row, so the current group reads at a
    /// glance and every row stays clickable.
    private func label(for group: String) -> String {
        tab.group == group ? "✓ \(group)" : "   \(group)"
    }
}
