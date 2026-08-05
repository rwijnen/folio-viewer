import SwiftUI

/// Builds the attributed text for one code cell: syntax colours plus intra-line
/// word-diff backgrounds, merged in a single pass.
///
/// Results are cached per row and side; the cache is dropped whenever another file
/// is opened, which keeps scrolling smooth without unbounded growth.
@MainActor
final class LineRenderer {

    struct Key: Hashable {
        var row: Int
        var isLeft: Bool
    }

    private var cache: [Key: AttributedString] = [:]

    func reset() {
        cache.removeAll(keepingCapacity: true)
    }

    func attributed(for cell: DiffCell, key: Key, spans: [SyntaxSpan], isRemoved: Bool) -> AttributedString {
        if let cached = cache[key] { return cached }
        let built = Self.build(text: cell.text, spans: spans,
                              changedRanges: cell.changedRanges, isRemoved: isRemoved)
        cache[key] = built
        return built
    }

    nonisolated static func build(text: String, spans: [SyntaxSpan],
                                  changedRanges: [Range<Int>], isRemoved: Bool) -> AttributedString {
        let characters = Array(text)
        guard !characters.isEmpty else {
            var blank = AttributedString(" ")
            blank.foregroundColor = Theme.codeText
            return blank
        }

        var kinds = [TokenKind?](repeating: nil, count: characters.count)
        for span in spans {
            let lower = max(0, span.range.lowerBound)
            let upper = min(characters.count, span.range.upperBound)
            guard lower < upper else { continue }
            for index in lower..<upper { kinds[index] = span.kind }
        }

        var changed = [Bool](repeating: false, count: characters.count)
        for range in changedRanges {
            let lower = max(0, range.lowerBound)
            let upper = min(characters.count, range.upperBound)
            guard lower < upper else { continue }
            for index in lower..<upper { changed[index] = true }
        }

        let wordColor = isRemoved ? Theme.removedWord : Theme.addedWord
        var result = AttributedString()
        var index = 0
        while index < characters.count {
            let kind = kinds[index]
            let isChanged = changed[index]
            var end = index + 1
            while end < characters.count, kinds[end] == kind, changed[end] == isChanged {
                end += 1
            }
            var segment = AttributedString(String(characters[index..<end]))
            segment.foregroundColor = kind.map(Theme.color(for:)) ?? Theme.codeText
            if isChanged { segment.backgroundColor = wordColor }
            result += segment
            index = end
        }
        return result
    }

    /// Paints search matches on top of an already-built line.
    nonisolated static func highlighting(_ base: AttributedString, ranges: [Range<Int>],
                                         current: Range<Int>?) -> AttributedString {
        guard !ranges.isEmpty else { return base }
        var result = base
        let length = base.characters.count
        for range in ranges {
            guard range.lowerBound >= 0, range.upperBound <= length, range.lowerBound < range.upperBound
            else { continue }
            let start = result.index(result.startIndex, offsetByCharacters: range.lowerBound)
            let end = result.index(result.startIndex, offsetByCharacters: range.upperBound)
            let isCurrent = current == range
            result[start..<end].backgroundColor = isCurrent ? Theme.currentSearchMatch : Theme.searchMatch
            if isCurrent {
                result[start..<end].foregroundColor = Theme.dynamic(light: .black, dark: .white)
            }
        }
        return result
    }
}
