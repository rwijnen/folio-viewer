import Foundation

/// Works out which source lines a selection covers.
///
/// A selection made in the rendered view is the text as it was laid out, not the Markdown
/// that produced it: `**no channel**` arrives as `no channel`, a link arrives as its
/// label, and a list bullet is gone. So the passage cannot be found by searching the
/// source for it verbatim. Both sides are reduced to their words first — markers stripped,
/// whitespace flattened — and compared on that.
///
/// The same reasoning as locating a diff hunk by content rather than by its line numbers:
/// the text is the thing that is true, and the position follows from it.
enum AnnotationLocator {

    /// Inline Markdown removed, whitespace flattened, case kept — what the reader saw.
    static func words(_ text: String) -> String {
        var result = text
        for token in ["**", "__", "~~", "`", "*", "_", "#", ">"] {
            result = result.replacingOccurrences(of: token, with: "")
        }
        result = result.replacingOccurrences(
            of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        // List markers and blockquote arrows are furniture, not words.
        result = result.replacingOccurrences(
            of: "^\\s*(?:[-+]|\\d+[.)])\\s+", with: "", options: .regularExpression)
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The lines `selection` covers, or nil when it cannot be found at all.
    ///
    /// `hint` is where the rendered block said it begins. It only orders the search: the
    /// nearest match wins, so a phrase repeated through a document lands on the one the
    /// reader actually selected rather than the first in the file.
    static func locate(selection: String, in lines: [String],
                       hint: Int? = nil) -> ClosedRange<Int>? {
        let needle = words(selection)
        guard !needle.isEmpty, !lines.isEmpty else { return nil }
        let haystack = lines.map(words)

        // A selection inside one line is the common case and the cheapest to settle.
        let singles = haystack.indices.filter {
            !haystack[$0].isEmpty && haystack[$0].contains(needle)
        }
        if let best = nearest(singles, to: hint) { return best...best }

        // Otherwise it runs across lines: grow a window from each starting line until it
        // holds the selection, which also copes with a sentence wrapped mid-paragraph.
        var spans: [ClosedRange<Int>] = []
        let opening = firstWords(needle)
        for start in haystack.indices where haystack[start].contains(opening) {
            // A selection usually begins part-way through a line, so the test is whether
            // the line *holds* the opening words, not whether it starts with them.
            var joined = haystack[start]
            var end = start
            while end + 1 < haystack.count, joined.count < needle.count * 2 + 80 {
                end += 1
                joined += haystack[end].isEmpty ? "" : " " + haystack[end]
                if joined.contains(needle) {
                    spans.append(start...end)
                    break
                }
            }
        }
        guard let best = spans.min(by: { distance($0.lowerBound, hint) < distance($1.lowerBound, hint) })
        else { return nil }
        return best
    }

    private static func firstWords(_ needle: String) -> String {
        needle.split(separator: " ").prefix(3).joined(separator: " ")
    }

    private static func nearest(_ candidates: [Int], to hint: Int?) -> Int? {
        candidates.min { distance($0, hint) < distance($1, hint) }
    }

    private static func distance(_ line: Int, _ hint: Int?) -> Int {
        guard let hint else { return line }
        return abs(line - hint)
    }
}
