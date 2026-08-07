import SwiftUI

/// The document sidebar: the outline, or the file's history, behind one switch.
///
/// They share a sidebar rather than taking one each because they answer the same
/// question from different directions — where am I in this document, and how did it get
/// this way — and a reader wants one of them at a time.
struct DocumentSidebar: View {

    @Environment(AppState.self) private var state
    let tab: DocumentTab
    let document: TextDocument

    var body: some View {
        VStack(spacing: 0) {
            // Only offered when there is a history to show; a document outside a
            // repository keeps the sidebar it always had.
            if tab.git != nil {
                Picker("", selection: Binding(get: { tab.sidebarMode },
                                              set: { state.setSidebarMode($0, for: tab) })) {
                    ForEach(SidebarMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            if tab.sidebarMode == .history, tab.git != nil {
                HistorySidebar(tab: tab)
            } else {
                OutlineSidebar(tab: tab, document: document)
            }
        }
    }
}

/// The commits that touched this document, newest first.
struct HistorySidebar: View {

    @Environment(AppState.self) private var state
    let tab: DocumentTab

    var body: some View {
        VStack(spacing: 0) {
            switch tab.historyState {
            case .idle, .loading:
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the log…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case let .failed(message):
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 18, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { state.loadHistory(for: tab, force: true) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded where !tab.history.isEmpty && tab.visibleHistory.isEmpty:
                VStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 18, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text("No commits match this filter")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Show All") { state.setHistoryFilter(.all, for: tab) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded where tab.history.isEmpty:
                VStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 20, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text("Never committed")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded:
                List {
                    ForEach(tab.visibleHistory) { commit in
                        CommitRow(commit: commit,
                                  isCurrent: tab.viewingCommit?.hash == commit.hash,
                                  isFirst: commit.hash == tab.history.first?.hash)
                            .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                            .contentShape(Rectangle())
                            .onTapGesture { state.showCommit(commit, for: tab) }
                            .contextMenu {
                                Button("Copy Commit Hash") { copy(commit.hash) }
                                Button("Copy Short Hash") { copy(commit.shortHash) }
                                Button("Copy Subject") { copy(commit.subject) }
                            }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if tab.viewingCommit != nil {
                Button("Back to the Document") { state.closeCommit(for: tab) }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            } else if case .loaded = tab.historyState, !tab.history.isEmpty {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 9))
                Text(countLabel)
                    .font(.system(size: 10))
            }
            Spacer(minLength: 0)

            if case .loaded = tab.historyState, !tab.history.isEmpty {
                Menu {
                    ForEach(HistoryFilter.allCases) { filter in
                        Button {
                            state.setHistoryFilter(filter, for: tab)
                        } label: {
                            // A tick rather than a disabled row, so which one is on is
                            // readable without opening anything else.
                            Text(tab.historyFilter == filter ? "✓ \(filter.label)" : filter.label)
                        }
                    }
                } label: {
                    Image(systemName: tab.historyFilter == .all
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Which commits to list")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Never claims to be showing more than it is: a filter that hides half the log
    /// says so, and so does the cap on how much was read.
    private var countLabel: String {
        let shown = tab.visibleHistory.count
        let total = tab.history.count
        if shown != total { return "\(shown) of \(total)" }
        if total >= GitHistory.defaultLimit { return "Most recent \(total) commits" }
        return "\(total) commit\(total == 1 ? "" : "s")"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.statusMessage = "Copied \(text)."
    }
}

/// One line in the history list.
///
/// Not private so it can be rendered on its own for checking — the list it sits in is a
/// `List`, which comes out blank offscreen.
struct CommitRow: View {

    let commit: GitCommitSummary
    let isCurrent: Bool
    /// The newest commit, marked so the top of the list is not just a date to work out.
    let isFirst: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Room for the timeline, which is drawn as an overlay below so its height
            // follows the row instead of deciding it. Stretching it inside this stack
            // squeezed a two-line subject onto one truncated line.
            Color.clear.frame(width: 6, height: 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(commit.subject)
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Text(commit.shortHash)
                        .font(.system(size: 9, design: .monospaced))
                    Text("·")
                    Text(CommitDate.when(commit.date))
                    if isFirst {
                        Text("· latest")
                    }
                    if let helper = commit.coAuthorName {
                        Text(helper)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.gutterBackground, in: Capsule())
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .overlay(alignment: .topLeading) { timeline }
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isCurrent ? Theme.foldBackground : .clear)
        }
        .help(tooltip)
    }

    private var tooltip: String {
        var lines = [commit.subject,
                     "\(commit.author) · \(CommitDate.exact(commit.date))"]
        // The full trailer, address and all, since the badge only has room for a name.
        lines.append(contentsOf: commit.coAuthors.map { "Co-authored by \($0)" })
        return lines.joined(separator: "\n")
    }

    /// A dot for this commit and a thread down to the next, so the list reads as a
    /// sequence rather than as unrelated lines.
    private var timeline: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
                .padding(.top, 4)
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 1)
        }
        .frame(width: 6)
    }
}

/// How a commit's date is written in the list.
enum CommitDate {

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let absolute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// A month, past which "47w ago" stops being something anyone converts in their head.
    static let relativeWindow: TimeInterval = 60 * 60 * 24 * 30

    /// Recent commits read better as "3d ago"; older ones as a date.
    static func when(_ date: Date, now: Date = Date()) -> String {
        now.timeIntervalSince(date) < relativeWindow
            ? relative.localizedString(for: date, relativeTo: now)
            : absolute.string(from: date)
    }

    static func exact(_ date: Date) -> String { absolute.string(from: date) }
}

/// One commit's change to the document, in the split view the app already had.
struct HistoricalCommitView: View {

    @Environment(AppState.self) private var state
    let tab: DocumentTab
    let commit: GitCommitSummary

    var body: some View {
        ComparisonPane(tab: tab,
                       leftTitle: "Before this commit",
                       rightTitle: "After this commit",
                       loadingMessage: "Reading \(commit.shortHash)…",
                       failureTitle: "Nothing to show for \(commit.shortHash)") {
            HStack(spacing: 8) {
                ComparisonTitle(
                    title: commit.subject,
                    detail: "\(commit.shortHash) · \(commit.author) · "
                        + CommitDate.exact(commit.date),
                    symbol: "clock.arrow.circlepath")
                Spacer()

                Button { state.stepThroughHistory(by: -1) } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Newer commit")
                .disabled(!canStep(-1))

                Button { state.stepThroughHistory(by: 1) } label: {
                    Image(systemName: "chevron.down")
                }
                .help("Older commit")
                .disabled(!canStep(1))

                Button("Back to the Document") { state.closeCommit(for: tab) }
                    .controlSize(.small)
            }
        }
    }

    private func canStep(_ offset: Int) -> Bool {
        guard let index = tab.history.firstIndex(where: { $0.hash == commit.hash }) else {
            return false
        }
        return tab.history.indices.contains(index + offset)
    }
}
