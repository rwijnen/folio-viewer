import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {

    @Environment(AppState.self) private var state
    @State private var isTargetedForDrop = false

    var body: some View {
        VStack(spacing: 0) {
            if !state.tabs.isEmpty {
                TabBar()
            }
            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }
        }
        .navigationTitle(state.documentTitle)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            for url in urls { state.open(at: url) }
            return true
        } isTargeted: { targeted in
            isTargetedForDrop = targeted
        }
        .overlay {
            if isTargetedForDrop {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .alert("Couldn't open that file",
               isPresented: Binding(get: { state.errorMessage != nil },
                                    set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        switch state.content {
        case .diff:
            if state.files.isEmpty { EmptySidebar() } else { FileListView() }
        case .markdown:
            if let document = state.textDocument { OutlineSidebar(document: document) }
        case .source:
            if let document = state.textDocument {
                OutlineSidebar(document: document)
            } else {
                EmptySidebar()
            }
        case .none:
            EmptySidebar()
        }
    }

    private var subtitle: String {
        if let document = state.textDocument {
            var parts = [document.isMarkdown ? "Markdown" : document.languageName]
            if document.diagramCount > 0 {
                parts.append("\(document.diagramCount) diagram\(document.diagramCount == 1 ? "" : "s")")
            }
            parts.append("\(document.lines.count) lines")
            return parts.joined(separator: " · ")
        }
        guard !state.files.isEmpty else { return "" }
        return "\(state.files.count) file\(state.files.count == 1 ? "" : "s") · +\(state.totalAdditions) −\(state.totalDeletions)"
    }

    @ViewBuilder
    private var detail: some View {
        if let tab = state.active, let document = tab.textDocument {
            DocumentView(tab: tab, document: document)
        } else {
            diffDetail
        }
    }

    @ViewBuilder
    private var diffDetail: some View {
        switch state.loadState {
        case .empty:
            WelcomeView()
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Applying patch…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.rowBackground)
        case let .failed(message):
            MessageView(title: "Nothing to compare", message: message, systemImage: "doc.questionmark")
        case let .loaded(file):
            if let tab = state.active, let entry = tab.selectedEntry {
                SplitDiffView(tab: tab, entry: entry, file: file)
            } else {
                WelcomeView()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if state.content == .diff {
                Button {
                    state.selectAdjacentFile(offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Previous file (⌘[)")
                .disabled(state.files.count < 2)

                Button {
                    state.selectAdjacentFile(offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .help("Next file (⌘])")
                .disabled(state.files.count < 2)
            }

            Spacer()

            if state.textDocument?.isMarkdown == true {
                Picker("", selection: Binding(get: { state.readingMode },
                                              set: { state.setReadingMode($0) })) {
                    ForEach(ReadingMode.allCases) { mode in
                        Image(systemName: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Rendered (⌘1) or source (⌘2)")
            }

            if !state.searchesRenderedPage {
                Button {
                    state.wrapLines.toggle()
                } label: {
                    Image(systemName: state.wrapLines ? "text.append" : "arrow.left.and.right")
                }
                .help(state.wrapLines ? "Wrapping long lines — click to scroll horizontally instead" : "Scrolling long lines — click to wrap")
            }

            if state.content == .diff {
                Button {
                    state.expandAllFolds()
                } label: {
                    Image(systemName: "arrow.up.and.down.text.horizontal")
                }
                .help("Expand all unchanged context")
                .disabled(state.loadedFile?.document.folds.isEmpty ?? true)
            }

            Button {
                if state.isFindPresented { state.dismissFind() } else { state.presentFind() }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Find in this document (⌘F)")
            .disabled(!state.canFind)
        }
    }

}

/// Shown before any diff is open.
struct WelcomeView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 46, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Open a diff or a Markdown document")
                .font(.system(size: 15, weight: .medium))
            Text("Drop .diff, .patch or .md files here, or press ⌘O.\nDiffs are shown side by side with the original read from disk and the patch applied in memory. Markdown opens rendered, with mermaid diagrams drawn, and a switch to the raw source. Open as many as you like — each gets a tab.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Open…") { state.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.rowBackground)
    }
}

struct EmptySidebar: View {
    var body: some View {
        VStack {
            Text("No files")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MessageView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .thin))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.rowBackground)
    }
}
