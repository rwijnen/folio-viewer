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
        ComparisonPane(tab: tab,
                       leftTitle: tab.isDirty ? "In the editor" : "In Folio",
                       rightTitle: "On disk",
                       loadingMessage: "Comparing…",
                       failureTitle: "Could not compare",
                       tint: .blue) {
            HStack(spacing: 8) {
                ComparisonTitle(
                    title: "What changed on disk",
                    detail: tab.isDirty
                        ? "Left is what you have been editing; right is what is in the file now."
                        : "Left is what Folio is showing; right is what is in the file now.",
                    symbol: "arrow.triangle.2.circlepath")
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
        }
    }
}
