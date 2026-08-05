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

            Menu {
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
        if document.isMarkdown, appState.readingMode == .rendered, let html = appState.renderedPage {
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

/// Heading list for the open Markdown document.
struct OutlineSidebar: View {

    @Environment(AppState.self) private var state
    let document: TextDocument

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
                List {
                    Section("Outline") {
                        ForEach(document.outline) { item in
                            Button {
                                jump(to: item)
                            } label: {
                                HStack(spacing: 6) {
                                    Text("H\(item.level)")
                                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 14, alignment: .leading)
                                    Text(item.title)
                                        .font(.system(size: 11,
                                                      weight: item.level <= 2 ? .semibold : .regular))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .padding(.leading, CGFloat(max(0, item.level - 1)) * 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                state.visibleAnchor == item.id
                                    ? Theme.foldBackground : Color.clear
                            )
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
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
