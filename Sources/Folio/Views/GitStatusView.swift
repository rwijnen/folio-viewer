import SwiftUI

/// The branch and file state, in the document header, with the git actions behind it.
///
/// Everything git can do from inside Folio is in this one menu. Keeping it in a single
/// place is deliberate: a reader should be able to see the whole of the app's reach into
/// their repository at a glance, rather than discovering it a button at a time.
struct GitStatusPill: View {

    @Environment(AppState.self) private var state
    let tab: DocumentTab

    var body: some View {
        if let snapshot = tab.git {
            Menu {
                Button("Uncommitted Changes…") { state.showWorkingChanges(for: tab) }
                    .disabled(!state.hasWorkingChanges(tab))
                Divider()
                Button("Commit…") { state.presentCommitSheet() }
                    .disabled(!state.canCommit(tab))
                if let upstream = snapshot.upstream {
                    Button("Push to \(upstream)") { state.pushActiveDocument() }
                        .disabled(!state.canPush(tab))
                }
                Divider()
                Button("Refresh Status") { state.refreshGitStatus(for: tab) }
                if let reason = blockedReason(snapshot) {
                    Divider()
                    // A disabled row, so the menu says why rather than leaving the
                    // reader to guess at a command that does nothing.
                    Text(reason)
                }
            } label: {
                GitStatusLabel(snapshot: snapshot,
                               isBusy: tab.gitActivity != nil,
                               hasUnsavedEdits: tab.isDirty)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tab.gitActivity ?? helpText(snapshot))
        }
    }

    /// The blocking reason, unless it is only that there are unsaved edits — those
    /// become something to commit the moment the save runs.
    private func blockedReason(_ snapshot: GitSnapshot) -> String? {
        if tab.isDirty, snapshot.commitIsPossible, snapshot.fileState == .committed {
            return nil
        }
        return snapshot.blockedReason
    }

    private func helpText(_ snapshot: GitSnapshot) -> String {
        var parts = ["On \(snapshot.branch ?? "a detached HEAD")"]
        switch snapshot.fileState {
        case .committed: parts.append(tab.isDirty ? "unsaved edits" : "no changes")
        case .modified: parts.append("edited since the last commit")
        case .untracked: parts.append("not yet in the repository")
        case .ignored: parts.append("ignored")
        case .conflicted: parts.append("conflicted")
        }
        if snapshot.ahead > 0 { parts.append("\(snapshot.ahead) to push") }
        if snapshot.behind > 0 { parts.append("\(snapshot.behind) to pull") }
        return parts.joined(separator: " · ")
    }
}

/// The pill itself: branch, drift, and a dot for the file's state.
///
/// Separate from the menu that wraps it so it can be rendered on its own — a `Menu` is
/// AppKit-backed and comes out blank offscreen, which would leave the one piece of git
/// state that is always on screen impossible to check without a person looking at it.
struct GitStatusLabel: View {

    let snapshot: GitSnapshot
    var isBusy = false
    /// Edits still in the editor. They are not in the file yet, so git cannot see them,
    /// but they are the commonest reason a reader is looking at this pill at all.
    var hasUnsavedEdits = false

    var body: some View {
        HStack(spacing: 4) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
            }
            Text(snapshot.summary)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)

            // The whole point of the pill: whether this file needs committing, in words.
            if let label = Self.label(for: snapshot, hasUnsavedEdits: hasUnsavedEdits) {
                Text("·")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(Self.tint(for: snapshot, hasUnsavedEdits: hasUnsavedEdits)
                                     ?? .secondary)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background {
            let tint = Self.tint(for: snapshot, hasUnsavedEdits: hasUnsavedEdits)
            Capsule()
                .fill(tint?.opacity(0.14) ?? Theme.gutterBackground)
                .overlay { Capsule().strokeBorder((tint ?? .clear).opacity(0.35)) }
        }
    }

    /// What the file needs, or nil when it needs nothing.
    ///
    /// Unsaved edits win over what git sees. They are about to become a change, and
    /// saying "no changes" while the reader is mid-sentence is simply wrong.
    static func label(for snapshot: GitSnapshot, hasUnsavedEdits: Bool) -> String? {
        if hasUnsavedEdits, snapshot.fileState == .committed { return "unsaved" }
        if hasUnsavedEdits, snapshot.fileState == .modified {
            return snapshot.changeLabel.map { "\($0), unsaved" } ?? "unsaved"
        }
        return snapshot.changeLabel
    }

    /// A quiet pill means nothing needs doing, which is the state a reader is in most of
    /// the time; anything else is coloured by how much it wants attention.
    static func tint(for snapshot: GitSnapshot, hasUnsavedEdits: Bool) -> Color? {
        if snapshot.fileState == .conflicted { return .red }
        if hasUnsavedEdits { return .orange }
        switch snapshot.fileState {
        case .committed: return nil
        case .modified: return .orange
        case .untracked: return .blue
        case .ignored: return .gray
        case .conflicted: return .red
        }
    }
}

/// Writing the commit message, and choosing whether it goes further than this machine.
struct CommitSheet: View {

    @Environment(AppState.self) private var appState
    let tab: DocumentTab

    var body: some View {
        @Bindable var state = appState
        return VStack(alignment: .leading, spacing: 12) {
            header

            TextEditor(text: $state.commitMessage)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 92)
                .padding(4)
                .overlay {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.gutterBackground)
                }
                .disabled(isBusy)

            notes

            if let upstream = tab.git?.upstream {
                Toggle("Push to \(upstream) afterwards", isOn: $state.commitShouldPush)
                    .toggleStyle(.checkbox)
                    .disabled(isBusy)
            } else {
                Label("This branch tracks no remote, so there is nothing to push to.",
                      systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 460)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Commit \(tab.name)")
                .font(.system(size: 14, weight: .semibold))
            if let snapshot = tab.git {
                Text("\(snapshot.root.lastPathComponent) · \(snapshot.branch ?? "detached HEAD")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Anything the reader should know before pressing the button.
    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            if tab.isDirty {
                Label("Unsaved changes will be saved first.", systemImage: "arrow.down.doc")
                    .foregroundStyle(.orange)
            }
            if tab.git?.fileState == .untracked {
                Label("This file is not in the repository yet; it will be added.",
                      systemImage: "plus.circle")
            }
            if let behind = tab.git?.behind, behind > 0 {
                // Worth flagging, because a push will be rejected until they pull — and
                // Folio will not pull for them.
                Label("\(behind) commit\(behind == 1 ? "" : "s") to pull first. "
                      + "A push would be rejected.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Label("Only \(tab.name) is committed. Anything else you have staged stays "
                  + "staged.", systemImage: "doc.text")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
    }

    private var footer: some View {
        HStack {
            if let activity = tab.gitActivity {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(activity)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { appState.dismissCommitSheet() }
                .keyboardShortcut(.cancelAction)
                .disabled(isBusy)
            Button(appState.commitShouldPush && tab.git?.upstream != nil
                   ? "Commit and Push" : "Commit") {
                appState.commitActiveDocument(message: appState.commitMessage,
                                              thenPush: appState.commitShouldPush)
                appState.dismissCommitSheet()
            }
            .buttonStyle(.borderedProminent)
            // ⌘↩ rather than ↩: Return belongs to the message field, where a commit
            // message's second paragraph starts.
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isBusy || !hasMessage || !appState.canCommit(tab))
        }
    }

    private var isBusy: Bool { tab.gitActivity != nil }

    private var hasMessage: Bool {
        !appState.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
