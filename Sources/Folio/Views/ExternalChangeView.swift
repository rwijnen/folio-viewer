import SwiftUI

/// Says that something else wrote the file, and offers the ways out.
///
/// Only ever shown when there is a decision for the reader to make. A document with no
/// unsaved edits is reloaded quietly and reports it in the status line instead, because
/// a bar asking permission to do the obvious thing is a bar you learn to dismiss without
/// reading.
struct ExternalChangeBanner: View {

    @Environment(AppState.self) private var state
    let tab: DocumentTab
    let change: ExternalChange

    var body: some View {
        switch change {
        case .removed:
            Banner(text: "\(tab.name) is no longer on disk. Your copy is still here; "
                   + "saving will write it back.",
                   systemImage: "trash", tint: .orange) {
                Button("Dismiss") { state.dismissExternalChange(for: tab) }
                    .buttonStyle(.link)
            }

        case .changed:
            Banner(text: tab.isDirty
                   ? "\(tab.name) changed on disk while you were editing."
                   : "\(tab.name) changed on disk.",
                   systemImage: "arrow.triangle.2.circlepath", tint: .blue) {
                HStack(spacing: 10) {
                    Button("See What Changed") { state.showExternalDifference(for: tab) }
                        .buttonStyle(.link)
                    // Named for what it costs, not for what it does. "Reload" alone does
                    // not say that the reader's unsaved work goes with it.
                    Button(tab.isDirty ? "Discard Mine and Reload" : "Reload") {
                        state.acceptExternalChange(for: tab)
                    }
                    .buttonStyle(.link)
                    Button(tab.isDirty ? "Keep Mine" : "Dismiss") {
                        state.dismissExternalChange(for: tab)
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }
}

/// The incoming change, side by side against what this tab holds.
struct ExternalChangeView: View {

    @Environment(AppState.self) private var state
    let tab: DocumentTab

    var body: some View {
        VStack(spacing: 0) {
            banner
            Divider()
            switch tab.loadState {
            case .empty, .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Comparing…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.rowBackground)
            case let .failed(message):
                MessageView(title: "Could not compare", message: message,
                            systemImage: "doc.questionmark")
            case let .loaded(file):
                if let entry = tab.selectedEntry {
                    SplitDiffView(tab: tab, entry: entry, file: file,
                                  leftTitle: tab.isDirty ? "In the editor" : "In Folio",
                                  rightTitle: "On disk")
                }
            }
        }
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("What changed on disk")
                    .font(.system(size: 12, weight: .semibold))
                Text(tab.isDirty
                     ? "Left is what you have been editing; right is what is in the file now."
                     : "Left is what Folio is showing; right is what is in the file now.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()

            Button(tab.isDirty ? "Discard Mine and Reload" : "Reload") {
                state.acceptExternalChange(for: tab)
            }
            .controlSize(.small)
            Button(tab.isDirty ? "Keep Mine" : "Dismiss") {
                state.dismissExternalChange(for: tab)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.08))
    }
}
