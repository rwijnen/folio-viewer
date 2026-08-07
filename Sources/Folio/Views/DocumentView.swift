import AppKit
import SwiftUI

/// The detail pane for a Markdown or plain-text document.
struct DocumentView: View {

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    let tab: DocumentTab
    let document: TextDocument

    var body: some View {
        VStack(spacing: 0) {
            header
            if let report = appState.diagramReport, report.contains("fail") || report.contains("missing") {
                Banner(text: report.contains("missing")
                       ? "mermaid.min.js is missing from the app bundle — diagram source is shown instead."
                       : "Some mermaid diagrams could not be drawn; their source is shown in place.",
                       systemImage: "exclamationmark.triangle.fill", tint: .orange) { EmptyView() }
            }
            if appState.isFindPresented {
                FindBar()
            }
            Divider()
            content
        }
        .background(Theme.rowBackground)
        .onAppear { appState.isDarkAppearance = colorScheme == .dark }
        .onChange(of: colorScheme) { appState.isDarkAppearance = colorScheme == .dark }
        .sheet(isPresented: Bindable(appState).isCommitSheetPresented) {
            CommitSheet(tab: tab)
                .environment(appState)
        }
    }

    // MARK: - Header

    private var header: some View {
        @Bindable var state = appState
        return HStack(spacing: 8) {
            Image(systemName: document.isMarkdown ? "doc.text" : "doc.plaintext")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(document.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(document.folder.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()

            if let count = diagramLabel {
                Label(count, systemImage: "chart.xyaxis.line")
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.gutterBackground, in: Capsule())
            }
            Text(document.isMarkdown ? "Markdown" : document.languageName)
                .font(.system(size: 10))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.gutterBackground, in: Capsule())
            Text("\(document.lines.count) lines")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if tab.isDirty {
                Text("Edited")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
            }

            GitStatusPill(tab: tab)

            if document.isMarkdown {
                Picker("", selection: Binding(get: { appState.readingMode },
                                              set: { appState.setReadingMode($0) })) {
                    ForEach(ReadingMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                .help("⌘1 rendered · ⌘2 source")
            }

            if tab.isEditable {
                Button {
                    appState.saveActiveDocument()
                } label: {
                    Label("Save", systemImage: "arrow.down.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!tab.isDirty)
                .help("Save to disk (⌘S)")
            }

            Menu {
                if tab.isEditable {
                    Button("Save") { appState.saveActiveDocument() }
                        .disabled(!tab.isDirty)
                    Button("Revert to Saved") { appState.revertDraft(for: tab) }
                        .disabled(!tab.isDirty)
                    Divider()
                }
                if tab.git != nil {
                    Button("Commit…") { appState.presentCommitSheet() }
                        .disabled(!appState.canCommit(tab))
                    if let upstream = tab.git?.upstream {
                        Button("Push to \(upstream)") { appState.pushActiveDocument() }
                            .disabled(!appState.canPush(tab))
                    }
                    Divider()
                }
                Button("Reload from Disk") { appState.reloadTextDocument() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Copy Source") { copySource() }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([document.url])
                }
                Button("Open in Default App") {
                    NSWorkspace.shared.open(document.url)
                }
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

    private var diagramLabel: String? {
        guard document.isMarkdown, document.diagramCount > 0 else { return nil }
        return "\(document.diagramCount) diagram\(document.diagramCount == 1 ? "" : "s")"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if document.isMarkdown, appState.readingMode == .source, tab.isEditable {
            MarkdownEditorView(tab: tab, version: tab.editorVersion)
                .background(Theme.rowBackground)
        } else if document.isMarkdown, appState.readingMode == .rendered,
                  let html = appState.renderedPage {
            MarkdownWebView(tab: tab,
                            html: html,
                            token: appState.renderedPageToken,
                            baseURL: document.folder,
                            query: appState.searchQuery,
                            caseSensitive: appState.searchCaseSensitive,
                            focusRequest: appState.renderedFocusRequest,
                            focusTarget: appState.renderedFocusTarget,
                            anchorRequest: appState.anchorRequest,
                            anchor: appState.pendingAnchor)
        } else {
            SourceListingView(tab: tab, document: document)
        }
    }

    private func copySource() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(document.lines.joined(separator: "\n"), forType: .string)
        appState.statusMessage = "Copied \(document.lines.count) lines to the clipboard."
    }
}

/// Heading list for the open Markdown document, foldable section by section.
struct OutlineSidebar: View {

    @Environment(AppState.self) private var state
    let tab: DocumentTab
    let document: TextDocument

    private var layout: OutlineLayout { tab.outlineLayout }
    private var visibleRows: [OutlineLayout.Row] {
        layout.visibleRows(collapsed: tab.collapsedOutline)
    }
    /// The heading the reader is on, or the nearest one still on screen if it is folded
    /// away — so the highlight never disappears into a collapsed section.
    private var highlighted: String? {
        layout.nearestVisible(to: state.visibleAnchor, collapsed: tab.collapsedOutline)
    }

    var body: some View {
        VStack(spacing: 0) {
            if document.outline.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 20, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text("No headings")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                List {
                    ForEach(visibleRows) { row in
                        OutlineRow(row: row,
                                   isCurrent: highlighted == row.id,
                                   isCollapsed: tab.collapsedOutline.contains(row.id),
                                   hiddenCount: layout.descendants(of: row.id).count,
                                   onToggle: { subtree in
                                       state.toggleOutlineSection(row.id, includingDescendants: subtree)
                                   },
                                   onJump: { jump(to: row.item) })
                        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
            footer
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 4) {
            Text("Outline")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            if !tab.collapsedOutline.isEmpty {
                Text("\(visibleRows.count) of \(layout.rows.count)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)

            Menu {
                Button("Expand All") { state.expandWholeOutline() }
                Button("Collapse All") { state.collapseWholeOutline() }
                Divider()
                // The point of the whole feature: fold a long document down until its
                // shape fits on one screen.
                ForEach(1...max(layout.maximumDepth + 1, 1), id: \.self) { levels in
                    Button(levels == 1 ? "Top Level Only" : "Show \(levels) Levels") {
                        state.showOutlineLevels(levels)
                    }
                }
            } label: {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("How much of the outline to show")

            Button {
                if tab.collapsedOutline.isEmpty {
                    state.collapseWholeOutline()
                } else {
                    state.expandWholeOutline()
                }
            } label: {
                Image(systemName: tab.collapsedOutline.isEmpty
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(tab.collapsedOutline.isEmpty ? "Collapse all sections" : "Expand all sections")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
                .font(.system(size: 9))
            Text(document.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func jump(to item: OutlineItem) {
        if document.isMarkdown, state.readingMode == .rendered {
            state.scrollToAnchor(item.id)
            state.visibleAnchor = item.id
        } else {
            state.scrollSource(to: item.lineIndex)
        }
    }
}

/// One heading in the sidebar: a disclosure triangle when it has anything under it,
/// indented by how deeply it nests.
struct OutlineRow: View {

    let row: OutlineLayout.Row
    let isCurrent: Bool
    let isCollapsed: Bool
    /// How many headings are folded away underneath, shown as a badge.
    let hiddenCount: Int
    /// `true` when ⌥ was held, meaning the whole subtree.
    var onToggle: (Bool) -> Void
    var onJump: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Group {
                if row.hasChildren {
                    Button {
                        onToggle(NSEvent.modifierFlags.contains(.option))
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .frame(width: 12, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(isCollapsed ? "Expand (⌥ for everything below)"
                                      : "Collapse (⌥ for everything below)")
                } else {
                    Color.clear.frame(width: 12, height: 12)
                }
            }

            Button(action: onJump) {
                HStack(spacing: 5) {
                    Text(row.item.title)
                        .font(.system(size: 11,
                                      weight: isCurrent ? .semibold
                                                        : (row.depth == 0 ? .medium : .regular)))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(row.depth == 0 ? .primary : .secondary)
                    Spacer(minLength: 0)
                    // A folded section says how much is hidden, so nothing is lost.
                    if isCollapsed {
                        Text("\(hiddenCount)")
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.gutterBackground, in: Capsule())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(row.depth) * 11)
        .padding(.vertical, 1)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isCurrent ? Theme.foldBackground : .clear)
        }
    }
}
