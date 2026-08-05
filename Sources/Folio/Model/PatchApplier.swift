import Foundation

/// Applies unified-diff hunks to the original file content, entirely in memory.
///
/// Nothing is ever written back to disk — the result is only used to render the
/// right-hand panel. Line numbers in diffs drift, so each hunk is located by
/// content search around its declared position (the same tolerance `patch(1)`
/// applies) and the offset it actually landed at is reported back so the
/// side-by-side builder can map rows to real line numbers.
enum PatchApplier {

    struct AppliedHunk {
        var hunk: DiffHunk
        /// 0-based index in the original file where this hunk's old content starts.
        var originalIndex: Int
        /// 0-based index in the produced file where this hunk's new content starts.
        var newIndex: Int
        /// Non-zero when the hunk did not land at its declared line number.
        var offset: Int
        /// True when the match ignored whitespace or dropped outer context.
        var fuzzy: Bool
    }

    struct Result {
        var newLines: [String]
        var applied: [AppliedHunk]
        /// Hunks that landed somewhere other than their declared position, or matched fuzzily.
        var warnings: [String]
    }

    enum Failure: LocalizedError {
        case hunkDidNotApply(index: Int, line: Int)

        var errorDescription: String? {
            switch self {
            case let .hunkDidNotApply(index, line):
                return "Hunk #\(index) (at line \(line)) does not match the original file."
            }
        }
    }

    /// Flips a patch so it turns the changed file back into the original.
    ///
    /// Used when the file on disk is already the patched version — applying the
    /// reversed hunks reconstructs the original for the left-hand panel.
    static func reverse(_ hunks: [DiffHunk]) -> [DiffHunk] {
        hunks.map { hunk in
            DiffHunk(
                oldStart: hunk.newStart,
                oldCount: hunk.newCount,
                newStart: hunk.oldStart,
                newCount: hunk.oldCount,
                heading: hunk.heading,
                lines: hunk.lines.map { line in
                    switch line.kind {
                    case .context: return line
                    case .removed: return HunkLine(kind: .added, text: line.text)
                    case .added: return HunkLine(kind: .removed, text: line.text)
                    }
                }
            )
        }
    }

    static func apply(hunks: [DiffHunk], to original: [String]) throws -> Result {
        var output: [String] = []
        var applied: [AppliedHunk] = []
        var warnings: [String] = []
        var cursor = 0  // next unconsumed line in `original`

        for (number, hunk) in hunks.enumerated() {
            let oldLines = hunk.oldLines
            // A zero-length old range (`@@ -2,0 +3,2 @@`, produced by `diff -U0`)
            // means "insert after old line 2", so its target is oldStart, not oldStart - 1.
            let declared = oldLines.isEmpty ? hunk.oldStart : hunk.oldStart - 1
            let preferred = max(cursor, declared)

            guard let match = locate(oldLines, in: original, preferred: preferred, notBefore: cursor) else {
                throw Failure.hunkDidNotApply(index: number + 1, line: hunk.oldStart)
            }

            output.append(contentsOf: original[cursor..<match.index])
            let newIndex = output.count
            output.append(contentsOf: hunk.newLines)

            let offset = match.index - declared
            applied.append(AppliedHunk(hunk: hunk, originalIndex: match.index,
                                       newIndex: newIndex, offset: offset, fuzzy: match.fuzzy))
            if offset != 0 {
                warnings.append("Hunk #\(number + 1) applied with offset \(offset > 0 ? "+" : "")\(offset) lines.")
            }
            if match.fuzzy {
                warnings.append("Hunk #\(number + 1) matched with reduced context (whitespace or context mismatch).")
            }
            cursor = match.index + oldLines.count
        }

        if cursor < original.count {
            output.append(contentsOf: original[cursor...])
        }
        return Result(newLines: output, applied: applied, warnings: warnings)
    }

    // MARK: - Hunk location

    private struct Match {
        var index: Int
        var fuzzy: Bool
    }

    private static func locate(_ needle: [String], in haystack: [String],
                               preferred: Int, notBefore: Int) -> Match? {
        if needle.isEmpty {
            // Pure insertion: nothing to match, clamp the declared position.
            return Match(index: min(max(preferred, notBefore), haystack.count), fuzzy: false)
        }
        let upperBound = haystack.count - needle.count
        guard upperBound >= notBefore else { return nil }

        // Pass 1: exact, searching outward from the declared position.
        if let index = search(needle, haystack, preferred, notBefore, upperBound, compare: { $0 == $1 }) {
            return Match(index: index, fuzzy: false)
        }
        // Pass 2: ignore trailing whitespace differences.
        if let index = search(needle, haystack, preferred, notBefore, upperBound, compare: equalIgnoringTrailingSpace) {
            return Match(index: index, fuzzy: true)
        }
        // Pass 3: ignore all whitespace.
        if let index = search(needle, haystack, preferred, notBefore, upperBound, compare: equalIgnoringAllSpace) {
            return Match(index: index, fuzzy: true)
        }
        // Pass 4: drop one line of outer context on each side (patch's fuzz factor).
        if needle.count > 2 {
            let trimmed = Array(needle[1..<(needle.count - 1)])
            if let index = search(trimmed, haystack, preferred + 1, notBefore, haystack.count - trimmed.count,
                                  compare: equalIgnoringTrailingSpace) {
                return Match(index: max(notBefore, index - 1), fuzzy: true)
            }
        }
        return nil
    }

    private static func search(_ needle: [String], _ haystack: [String],
                               _ preferred: Int, _ lowerBound: Int, _ upperBound: Int,
                               compare: (String, String) -> Bool) -> Int? {
        guard upperBound >= lowerBound else { return nil }
        let start = min(max(preferred, lowerBound), upperBound)
        if matches(needle, haystack, at: start, compare: compare) { return start }
        var distance = 1
        let span = max(upperBound - lowerBound, 1)
        while distance <= span {
            let forward = start + distance
            if forward <= upperBound, matches(needle, haystack, at: forward, compare: compare) {
                return forward
            }
            let backward = start - distance
            if backward >= lowerBound, matches(needle, haystack, at: backward, compare: compare) {
                return backward
            }
            distance += 1
        }
        return nil
    }

    private static func matches(_ needle: [String], _ haystack: [String], at index: Int,
                                compare: (String, String) -> Bool) -> Bool {
        guard index >= 0, index + needle.count <= haystack.count else { return false }
        for offset in 0..<needle.count {
            if !compare(needle[offset], haystack[index + offset]) { return false }
        }
        return true
    }

    private static func equalIgnoringTrailingSpace(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmedTrailingWhitespace() == rhs.trimmedTrailingWhitespace()
    }

    private static func equalIgnoringAllSpace(_ lhs: String, _ rhs: String) -> Bool {
        lhs.filter { !$0.isWhitespace } == rhs.filter { !$0.isWhitespace }
    }
}

extension String {
    func trimmedTrailingWhitespace() -> String {
        var result = self
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return result
    }
}
