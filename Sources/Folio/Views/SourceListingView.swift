import SwiftUI

/// Single-column source listing: line numbers plus syntax-highlighted text.
/// Used for Markdown source mode and for any other text file Folio is handed.
struct SourceListingView: View {

    @Environment(AppState.self) private var state
    let tab: DocumentTab
    let document: TextDocument

    /// Markdown source and a plain source file are different views of a document, so
    /// they get their own remembered positions.
    private var scrollKey: String { document.isMarkdown ? "markdown-source" : "source" }

    var body: some View {
        GeometryReader { geometry in
            let width = contentWidth(available: geometry.size.width)
            ScrollViewReader { proxy in
                ScrollView(state.wrapLines ? .vertical : [.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(document.lines.enumerated()), id: \.offset) { index, line in
                            SourceRowView(index: index, text: line,
                                          spans: spans(at: index),
                                          wrap: state.wrapLines,
                                          contentWidth: width)
                            .id("s\(index)")
                        }
                    }
                    .padding(.vertical, 4)
                    .keepsScrollOffset(key: scrollKey, store: tab.scrollOffsets)
                }
                .onChange(of: state.scrollRequest) {
                    guard let match = state.currentMatch else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo("s\(match.rowIndex)", anchor: .center)
                    }
                }
                .onChange(of: state.sourceScrollRequest) {
                    guard let line = state.sourceScrollLine else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo("s\(line)", anchor: .top)
                    }
                }
            }
        }
        .background(Theme.rowBackground)
    }

    private func spans(at index: Int) -> [SyntaxSpan] {
        document.spans.indices.contains(index) ? document.spans[index] : []
    }

    private func contentWidth(available: CGFloat) -> CGFloat {
        let usable = max(available - Theme.gutterWidth - 14, 200)
        guard !state.wrapLines else { return usable }
        return max(CGFloat(document.maxColumns) * Theme.characterWidth + 12, usable)
    }
}

struct SourceRowView: View {

    @Environment(AppState.self) private var state
    let index: Int
    let text: String
    let spans: [SyntaxSpan]
    let wrap: Bool
    let contentWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("\(index + 1)")
                .font(.system(size: Theme.fontSize - 1, design: .monospaced))
                .foregroundStyle(Theme.gutterText)
                .frame(width: Theme.gutterWidth, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.vertical, 1)

            if wrap {
                Text(attributed)
                    .font(Theme.codeFont)
                    .textSelection(.enabled)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(attributed)
                    .font(Theme.codeFont)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .padding(.vertical, 1)
                    .frame(width: contentWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, 4)
        .background(isCurrentRow ? Theme.searchMatch.opacity(0.25) : Color.clear)
    }

    private var isCurrentRow: Bool {
        state.currentMatch?.rowIndex == index
    }

    private var attributed: AttributedString {
        let cell = DiffCell(number: index + 1, text: text, characterCount: text.count)
        let base = state.renderer.attributed(
            for: cell,
            key: LineRenderer.Key(row: index, isLeft: true),
            spans: spans,
            isRemoved: false
        )
        let ranges = state.searchRanges(inRow: index, isLeft: true)
        guard !ranges.isEmpty else { return base }
        var current: Range<Int>?
        if let match = state.currentMatch, match.rowIndex == index { current = match.range }
        return LineRenderer.highlighting(base, ranges: ranges, current: current)
    }
}
