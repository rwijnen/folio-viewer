import SwiftUI

/// Sidebar listing every file entry in the diff.
struct FileListView: View {

    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section {
                    ForEach(state.files) { entry in
                        FileRow(entry: entry)
                            .tag(entry.id)
                            .contextMenu {
                                Button("Locate Original…") {
                                    state.presentLocateOriginalPanel(for: entry.id)
                                }
                                if let url = entry.originalURL {
                                    Button("Reveal Original in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    }
                                }
                            }
                    }
                } header: {
                    Text("\(state.files.count) file\(state.files.count == 1 ? "" : "s") changed")
                }
            }
            .listStyle(.sidebar)

            Divider()
            baseFolderFooter
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { state.selectedFileID },
            set: { newValue in
                if let newValue { state.selectFile(newValue) }
            }
        )
    }

    private var baseFolderFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                Text("Original files")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Change…") { state.presentBaseFolderPanel() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
            Text(state.baseFolder?.path ?? "Not set — choose the folder the diff was made in")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(state.baseFolder == nil ? .orange : .secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                ChangeCounts(additions: state.totalAdditions, deletions: state.totalDeletions)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FileRow: View {
    let entry: FileEntry

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.diff.kind.symbol)
                .font(.system(size: 10))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(entry.diff.displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.originalURL == nil && entry.diff.kind != .added {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("Original file not found")
                    }
                    if entry.diff.isBinary {
                        Text("binary")
                            .font(.system(size: 8, weight: .semibold))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                if !entry.diff.displayDirectory.isEmpty {
                    Text(entry.diff.displayDirectory)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            ChangeCounts(additions: entry.diff.additions, deletions: entry.diff.deletions)
        }
        .padding(.vertical, 2)
    }

    private var tint: Color {
        switch entry.diff.kind {
        case .added: return .green
        case .deleted: return .red
        case .renamed, .copied: return .blue
        case .modified: return .orange
        case .modeOnly: return .secondary
        }
    }
}
