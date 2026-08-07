import AppKit
import SwiftUI

/// The right-hand pane: header, column titles and the scrolling split diff.
struct SplitDiffView: View {

    @Environment(AppState.self) private var state
    let tab: DocumentTab
    let entry: FileEntry
    let file: LoadedFile
    /// Overridable because the two sides are not always a patch's before and after —
    /// a comparison against the copy on disk wants saying so.
    var leftTitle = "Original"
    var rightTitle = "Modified"

    var body: some View {
        VStack(spacing: 0) {
            header
            if let reason = file.degradedReason {
                Banner(text: reason, systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                    Button("Locate Original…") {
                        state.presentLocateOriginalPanel(for: entry.id)
                    }
                    .buttonStyle(.link)
                }
            }
            if let notice = file.notice {
                Banner(text: notice, systemImage: "arrow.uturn.backward.circle.fill", tint: .blue) {
                    EmptyView()
                }
            }
            if !file.document.warnings.isEmpty {
                Banner(text: file.document.warnings.joined(separator: " "),
                       systemImage: "info.circle.fill", tint: .blue) { EmptyView() }
            }
            if state.isFindPresented {
                FindBar()
            }
            columnHeaders
            Divider()
            rows
        }
        .background(Theme.rowBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.diff.kind.symbol)
                .foregroundStyle(color(for: entry.diff.kind))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.diff.displayName)
                    .font(.system(size: 13, weight: .semibold))
                if !entry.diff.displayDirectory.isEmpty {
                    Text(entry.diff.displayDirectory)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            if let rename = entry.diff.renameDescription {
                Text(rename)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(file.languageName)
                .font(.system(size: 10))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.gutterBackground, in: Capsule())
            ChangeCounts(additions: entry.diff.additions, deletions: entry.diff.deletions)
            Menu {
                Button("Copy Original File") { copy(file.document.leftLines) }
                    .disabled(file.document.leftLines.isEmpty)
                Button("Copy Modified File") { copy(file.document.rightLines) }
                    .disabled(file.document.rightLines.isEmpty)
                Divider()
                Button("Reveal Original in Finder") {
                    if let url = file.originalURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .disabled(file.originalURL == nil)
                Button("Locate Original…") { state.presentLocateOriginalPanel(for: entry.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.gutterBackground)
    }

    private var columnHeaders: some View {
        // The divider is an overlay rather than a stack item on purpose: a Rectangle
        // inside the HStack is vertically flexible, which makes the whole header band
        // stretch and eat the space meant for the rows.
        HStack(alignment: .top, spacing: 0) {
            columnTitle(leftTitle, detail: originalDetail)
            columnTitle(rightTitle, detail: modifiedDetail)
        }
        .overlay(alignment: .center) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
        .background(Theme.gutterBackground)
    }

    private var originalDetail: String {
        if file.document.isDiffOnly { return "diff content only" }
        if entry.diff.kind == .added { return "new file" }
        if file.leftIsReconstructed {
            return "\(file.document.leftLines.count) lines · reconstructed from the diff"
        }
        return "\(file.document.leftLines.count) lines · on disk"
    }

    private var modifiedDetail: String {
        if file.document.isDiffOnly { return "diff content only" }
        if entry.diff.kind == .deleted { return "file deleted" }
        if file.leftIsReconstructed {
            return "\(file.document.rightLines.count) lines · the file on disk"
        }
        return "\(file.document.rightLines.count) lines · patch applied in memory"
    }

    private func columnTitle(_ title: String, detail: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Rows

    private var rows: some View {
        GeometryReader { geometry in
            let width = contentWidth(available: geometry.size.width)
            ScrollViewReader { proxy in
                ScrollView(state.wrapLines ? .vertical : [.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.displayItems) { item in
                            switch item {
                            case let .row(index):
                                if file.document.rows.indices.contains(index) {
                                    DiffRowView(row: file.document.rows[index],
                                                leftSpans: file.leftSpans,
                                                rightSpans: file.rightSpans,
                                                wrap: state.wrapLines,
                                                contentWidth: width)
                                    .id(item.id)
                                }
                            case let .fold(fold):
                                FoldRowView(fold: fold)
                                    .id(item.id)
                            }
                        }
                    }
                    .keepsScrollOffset(key: "diff:\(entry.id.uuidString)",
                                       store: tab.scrollOffsets)
                }
                .onChange(of: state.scrollRequest) {
                    guard let match = state.currentMatch else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo("r\(match.rowIndex)", anchor: .center)
                    }
                }
            }
        }
    }

    private func contentWidth(available: CGFloat) -> CGFloat {
        let halfViewport = max((available - 2 * (Theme.gutterWidth + 6 + Theme.markerWidth) - 1) / 2, 200)
        guard !state.wrapLines else { return halfViewport }
        let measured = CGFloat(file.document.maxColumns) * Theme.characterWidth + 12
        return max(measured, halfViewport)
    }

    // MARK: - Helpers

    private func copy(_ lines: [String]) {
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.statusMessage = "Copied \(lines.count) lines to the clipboard."
    }

    private func color(for kind: FileChangeKind) -> Color {
        switch kind {
        case .added: return .green
        case .deleted: return .red
        case .renamed, .copied: return .blue
        case .modified: return .orange
        case .modeOnly: return .secondary
        }
    }
}

/// The "N unchanged lines" marker that expands a folded run.
struct FoldRowView: View {
    @Environment(AppState.self) private var state
    let fold: Fold

    var body: some View {
        Button {
            state.toggleFold(fold)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 10))
                Text("\(fold.count) unchanged lines")
                    .font(.system(size: 10, weight: .medium))
                Spacer(minLength: 0)
                Text("Click to expand")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(Theme.foldText)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.foldBackground)
            .overlay(alignment: .top) { Divider() }
            .overlay(alignment: .bottom) { Divider() }
        }
        .buttonStyle(.plain)
    }
}

struct ChangeCounts: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            if additions > 0 {
                Text("+\(additions)")
                    .foregroundStyle(Color.green)
            }
            if deletions > 0 {
                Text("−\(deletions)")
                    .foregroundStyle(Color.red)
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
    }
}

struct Banner<Accessory: View>: View {
    let text: String
    let systemImage: String
    let tint: Color
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.system(size: 11))
            accessory()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}
