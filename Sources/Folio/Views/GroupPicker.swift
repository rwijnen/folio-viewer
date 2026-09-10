import SwiftUI

/// The project dropdown, beside the document's name in the title bar.
///
/// Shown only once there is more than one group to choose between; with everything in one
/// folder it would be a control with a single option.
struct GroupPicker: View {

    @Environment(AppState.self) private var state

    var body: some View {
        if state.groups.count > 1 {
            Menu {
                Button { state.selectGroup(nil) } label: {
                    Text(tick(nil) + "All documents (\(state.tabs.count))")
                }
                Divider()
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
