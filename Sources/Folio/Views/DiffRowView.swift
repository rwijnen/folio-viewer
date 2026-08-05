import SwiftUI

/// One aligned line pair: original on the left, patched result on the right.
struct DiffRowView: View {

    let row: DiffRow
    let leftSpans: [[SyntaxSpan]]
    let rightSpans: [[SyntaxSpan]]
    let wrap: Bool
    let contentWidth: CGFloat

    @Environment(AppState.self) private var state

    var body: some View {
        if case let .gap(label) = row.kind {
            gapRow(label)
        } else {
            HStack(alignment: .top, spacing: 0) {
                side(cell: row.left, isLeft: true)
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1)
                side(cell: row.right, isLeft: false)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sides

    private func side(cell: DiffCell?, isLeft: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(cell.map { String($0.number) } ?? " ")
                .font(.system(size: Theme.fontSize - 1, design: .monospaced))
                .foregroundStyle(Theme.gutterText)
                .frame(width: Theme.gutterWidth, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.vertical, 1)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(gutterColor(isLeft: isLeft, hasCell: cell != nil))

            HStack(alignment: .top, spacing: 0) {
                Text(marker(isLeft: isLeft))
                    .font(Theme.codeFont)
                    .foregroundStyle(Theme.gutterText)
                    .frame(width: Theme.markerWidth, alignment: .center)
                    .padding(.vertical, 1)
                codeText(cell: cell, isLeft: isLeft)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(cellColor(isLeft: isLeft, hasCell: cell != nil))
        }
        .modifier(SideWidth(wrap: wrap, contentWidth: contentWidth))
    }

    @ViewBuilder
    private func codeText(cell: DiffCell?, isLeft: Bool) -> some View {
        let text = attributedText(cell: cell, isLeft: isLeft)
        if wrap {
            Text(text)
                .font(Theme.codeFont)
                .textSelection(.enabled)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .font(Theme.codeFont)
                .textSelection(.enabled)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .frame(width: contentWidth, alignment: .leading)
        }
    }

    private func attributedText(cell: DiffCell?, isLeft: Bool) -> AttributedString {
        guard let cell else { return AttributedString(" ") }
        let spans = spans(for: cell.number, isLeft: isLeft)
        let base = state.renderer.attributed(
            for: cell,
            key: LineRenderer.Key(row: row.id, isLeft: isLeft),
            spans: spans,
            isRemoved: isLeft
        )
        let ranges = state.searchRanges(inRow: row.id, isLeft: isLeft)
        guard !ranges.isEmpty else { return base }
        var current: Range<Int>?
        if let match = state.currentMatch, match.rowIndex == row.id, match.isLeft == isLeft {
            current = match.range
        }
        return LineRenderer.highlighting(base, ranges: ranges, current: current)
    }

    private func spans(for lineNumber: Int, isLeft: Bool) -> [SyntaxSpan] {
        let table = isLeft ? leftSpans : rightSpans
        let index = lineNumber - 1
        guard table.indices.contains(index) else { return [] }
        return table[index]
    }

    // MARK: - Chrome

    private func marker(isLeft: Bool) -> String {
        switch row.kind {
        case .removed, .modified: return isLeft ? "−" : (row.right == nil ? " " : "+")
        case .added: return isLeft ? " " : "+"
        case .unchanged, .gap: return " "
        }
    }

    private func cellColor(isLeft: Bool, hasCell: Bool) -> Color {
        guard hasCell else { return Theme.fillerBackground }
        switch row.kind {
        case .removed: return isLeft ? Theme.removedBackground : Theme.rowBackground
        case .added: return isLeft ? Theme.rowBackground : Theme.addedBackground
        case .modified: return isLeft ? Theme.removedBackground : Theme.addedBackground
        case .unchanged, .gap: return Theme.rowBackground
        }
    }

    private func gutterColor(isLeft: Bool, hasCell: Bool) -> Color {
        guard hasCell else { return Theme.fillerBackground }
        switch row.kind {
        case .removed: return isLeft ? Theme.removedGutter : Theme.gutterBackground
        case .added: return isLeft ? Theme.gutterBackground : Theme.addedGutter
        case .modified: return isLeft ? Theme.removedGutter : Theme.addedGutter
        case .unchanged, .gap: return Theme.gutterBackground
        }
    }

    private func gapRow(_ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.and.line.horizontal.and.arrow.up")
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: Theme.fontSize - 1, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.foldText)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.foldBackground)
    }
}

/// Equal halves when wrapping, fixed content width when scrolling horizontally.
private struct SideWidth: ViewModifier {
    let wrap: Bool
    let contentWidth: CGFloat

    func body(content: Content) -> some View {
        if wrap {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content.fixedSize(horizontal: true, vertical: false)
        }
    }
}
