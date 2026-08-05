import SwiftUI

/// The strip of open documents across the top of the window.
///
/// Tabs share the available width and shrink like Safari's rather than scrolling, so
/// every open document stays reachable with one click.
struct TabBar: View {

    @Environment(AppState.self) private var state
    @State private var hoveredID: UUID?

    private let minimumWidth: CGFloat = 84
    private let maximumWidth: CGFloat = 260

    var body: some View {
        HStack(spacing: 0) {
            ForEach(state.tabs) { tab in
                TabChip(tab: tab,
                        isActive: tab.id == state.activeTabID,
                        isHovered: hoveredID == tab.id,
                        minimumWidth: minimumWidth,
                        maximumWidth: maximumWidth)
                    .onHover { inside in
                        hoveredID = inside ? tab.id : (hoveredID == tab.id ? nil : hoveredID)
                    }
                    .onTapGesture { state.activate(tab.id) }
                    .contextMenu {
                        Button("Close Tab") { state.closeTab(tab.id) }
                        Button("Close Other Tabs") {
                            state.activate(tab.id)
                            state.closeOtherTabs()
                        }
                        .disabled(state.tabs.count < 2)
                        Divider()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([tab.url])
                        }
                    }
                    .help(tab.url.path)
            }

            Button {
                state.presentOpenPanel()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open another document (⌘O)")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .background(Theme.gutterBackground)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct TabChip: View {

    @Environment(AppState.self) private var state
    let tab: DocumentTab
    let isActive: Bool
    let isHovered: Bool
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.symbol)
                .font(.system(size: 10))
                .foregroundStyle(isActive ? tintColor : .secondary)

            Text(tab.name)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)

            // The close button only appears on hover or on the active tab, so a row of
            // tabs stays quiet to look at.
            if isHovered || isActive {
                Button {
                    state.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close (⌘W)")
            } else {
                Spacer().frame(width: 14)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .frame(minWidth: minimumWidth, maxWidth: maximumWidth, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Theme.rowBackground : (isHovered ? Theme.foldBackground : .clear))
        }
        .overlay(alignment: .bottom) {
            // A tint bar under the active tab, so the diff/markdown distinction reads
            // even when the label is truncated.
            Rectangle()
                .fill(isActive ? tintColor : .clear)
                .frame(height: 2)
                .padding(.horizontal, 6)
        }
        .contentShape(Rectangle())
    }

    private var tintColor: Color {
        switch tab.content {
        case .diff: return .orange
        case .markdown: return .blue
        case .source: return .secondary
        case .none: return .secondary
        }
    }
}
