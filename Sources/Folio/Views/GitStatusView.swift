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
                Button("Commit…") { state.presentCommitSheet() }
                if let upstream = snapshot.upstream {
                    Button("Push to \(upstream)") { state.pushActiveDocument() }
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
                GitStatusLabel(snapshot: snapshot, isBusy: tab.gitActivity != nil)
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
            if let colour = Self.stateColour(snapshot.fileState) {
                Circle()
                    .fill(colour)
                    .frame(width: 5, height: 5)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.gutterBackground, in: Capsule())
    }

    /// No dot for a file that matches the last commit — a quiet header means nothing
    /// needs doing, which is the state a reader is in most of the time.
    static func stateColour(_ fileState: GitSnapshot.FileState) -> Color? {
        switch fileState {
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
            .disabled(isBusy || !hasMessage)
        }
    }

    private var isBusy: Bool { tab.gitActivity != nil }

    private var hasMessage: Bool {
        !appState.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
