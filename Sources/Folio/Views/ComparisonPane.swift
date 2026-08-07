import SwiftUI

/// The shared shell of every side-by-side comparison the document pane can show.
///
/// There are three — a past commit, what arrived on disk, and what is not yet committed —
/// and they differ only in the bar across the top. Everything below it is the same: the
/// split view, or a reason there is not one. Written once rather than three times, since
/// the third copy is where they start to drift apart.
struct ComparisonPane<Chrome: View>: View {

    let tab: DocumentTab
    /// Column headings, because the two sides are rarely "original" and "modified".
    var leftTitle: String
    var rightTitle: String
    var loadingMessage: String
    var failureTitle: String
    /// Tints the bar, so it is visibly not the document.
    var tint: Color = .accentColor
    @ViewBuilder var chrome: Chrome

    var body: some View {
        VStack(spacing: 0) {
            chrome
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(tint.opacity(0.08))
            Divider()

            switch tab.loadState {
            case .empty, .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    Text(loadingMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.rowBackground)

            case let .failed(message):
                MessageView(title: failureTitle, message: message,
                            systemImage: "doc.questionmark")

            case let .loaded(file):
                if let entry = tab.selectedEntry {
                    SplitDiffView(tab: tab, entry: entry, file: file,
                                  leftTitle: leftTitle, rightTitle: rightTitle)
                }
            }
        }
    }
}

/// A title and a line of explanation, which every one of the three bars starts with.
struct ComparisonTitle: View {

    let title: String
    let detail: String
    var symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// What is not yet committed: the last commit on the left, what you have now on the right.
struct WorkingChangesView: View {

    @Environment(AppState.self) private var state
    let tab: DocumentTab

    var body: some View {
        ComparisonPane(tab: tab,
                       leftTitle: isNew ? "Not in the repository" : "Last commit",
                       rightTitle: tab.isDirty ? "Yours, including unsaved" : "Yours",
                       loadingMessage: "Reading the last commit…",
                       failureTitle: "Could not compare with the last commit",
                       tint: .orange) {
            HStack(spacing: 8) {
                ComparisonTitle(title: "Not yet committed",
                                detail: detail,
                                symbol: "square.and.pencil")
                Spacer()
                Button("Commit…") { state.presentCommitSheet() }
                    .controlSize(.small)
                Button("Back to the Document") { state.closeCommit(for: tab) }
                    .controlSize(.small)
            }
        }
    }

    private var isNew: Bool { tab.git?.fileState == .untracked }

    /// Says plainly that unsaved edits are included, because they are — a commit saves
    /// first, so this is what would be recorded, not what is on disk.
    private var detail: String {
        if isNew { return "This file is not in the repository yet; all of it is new." }
        return tab.isDirty
            ? "Includes your unsaved edits, which a commit would save first."
            : "What a commit would record for \(tab.name)."
    }
}
