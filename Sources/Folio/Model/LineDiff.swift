import Foundation

/// Computes a line-level diff between two versions of a text.
///
/// Until now Folio only ever *read* diffs — a patch file, or one produced by git. This is
/// the first place it has to work one out for itself, because the two things being
/// compared are a file on disk and a buffer in memory, and neither git nor a patch file
/// knows about the second one.
///
/// The output is deliberately the same shape the patch pipeline produces, so the split
/// view, folds, word-level highlighting and search all apply unchanged.
enum LineDiff {

    /// Unchanged lines kept either side of a change, matching what a unified diff carries.
    static let context = 3

    /// Ceiling on the LCS table, measured *after* the common prefix and suffix are
    /// trimmed away. Two thousand changed lines on each side is far past any real edit;
    /// beyond it the file is shown as wholly replaced rather than spending seconds and
    /// several hundred megabytes proving it.
    static let maximumProduct = 4_000_000

    struct Result {
        var applied: [PatchApplier.AppliedHunk]
        /// True when the two versions were too large or too dissimilar to align line by
        /// line, so the whole of the differing region is reported as replaced.
        var isCoarse: Bool

        var isEmpty: Bool { applied.isEmpty }
    }

    /// Compares two versions of a file.
    static func compare(original: [String], updated: [String]) -> Result {
        // Trim what is identical at each end first. This is not just an optimisation: an
        // edit to one paragraph of a long document leaves a middle of a few lines, which
        // is what keeps the table below small enough to be worth building at all.
        var prefix = 0
        let shortest = min(original.count, updated.count)
        while prefix < shortest, original[prefix] == updated[prefix] { prefix += 1 }

        var suffix = 0
        while suffix < shortest - prefix,
              original[original.count - 1 - suffix] == updated[updated.count - 1 - suffix] {
            suffix += 1
        }

        let oldMiddle = Array(original[prefix..<(original.count - suffix)])
        let newMiddle = Array(updated[prefix..<(updated.count - suffix)])
        if oldMiddle.isEmpty, newMiddle.isEmpty {
            return Result(applied: [], isCoarse: false)
        }

        let middle: [Operation]
        var isCoarse = false
        if oldMiddle.count * newMiddle.count > maximumProduct {
            isCoarse = true
            middle = oldMiddle.map { .remove($0) } + newMiddle.map { .add($0) }
        } else {
            middle = script(from: oldMiddle, to: newMiddle)
        }

        // The trimmed ends go back on as unchanged operations. They were removed to keep
        // the table small, not to leave them out — the lines immediately around a change
        // are its context, and a hunk without them has nothing for the patch to anchor to.
        let operations = original[0..<prefix].map { Operation.keep($0) }
            + middle
            + original[(original.count - suffix)...].map { Operation.keep($0) }

        return Result(applied: hunks(from: operations), isCoarse: isCoarse)
    }

    // MARK: - The edit script

    private enum Operation {
        case keep(String)
        case remove(String)
        case add(String)
    }

    /// Longest common subsequence, walked back into an edit script.
    private static func script(from original: [String], to updated: [String]) -> [Operation] {
        let rows = original.count
        let columns = updated.count
        // One flat array rather than nested ones: this is the hot allocation, and the
        // table is (rows + 1) × (columns + 1).
        var lengths = [Int](repeating: 0, count: (rows + 1) * (columns + 1))
        func index(_ row: Int, _ column: Int) -> Int { row * (columns + 1) + column }

        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                lengths[index(row, column)] = original[row] == updated[column]
                    ? lengths[index(row + 1, column + 1)] + 1
                    : max(lengths[index(row + 1, column)], lengths[index(row, column + 1)])
            }
        }

        var operations: [Operation] = []
        var row = 0
        var column = 0
        while row < rows, column < columns {
            if original[row] == updated[column] {
                operations.append(.keep(original[row]))
                row += 1
                column += 1
            } else if lengths[index(row + 1, column)] >= lengths[index(row, column + 1)] {
                operations.append(.remove(original[row]))
                row += 1
            } else {
                operations.append(.add(updated[column]))
                column += 1
            }
        }
        while row < rows {
            operations.append(.remove(original[row]))
            row += 1
        }
        while column < columns {
            operations.append(.add(updated[column]))
            column += 1
        }
        return operations
    }

    // MARK: - Grouping into hunks

    /// Turns the edit script back into hunks with context, positioned in the whole file.
    private static func hunks(from operations: [Operation]) -> [PatchApplier.AppliedHunk] {
        // Where each operation sits in the two whole files.
        var placed: [(operation: Operation, oldIndex: Int, newIndex: Int)] = []
        var oldIndex = 0
        var newIndex = 0
        for operation in operations {
            placed.append((operation, oldIndex, newIndex))
            switch operation {
            case .keep: oldIndex += 1; newIndex += 1
            case .remove: oldIndex += 1
            case .add: newIndex += 1
            }
        }

        // Runs of changes, each widened by the context either side, merged where they
        // would otherwise overlap.
        var ranges: [Range<Int>] = []
        var cursor = 0
        while cursor < placed.count {
            guard !isKeep(placed[cursor].operation) else {
                cursor += 1
                continue
            }
            var end = cursor
            var gap = 0
            var scan = cursor
            // Keep extending while any change is within twice the context — closer than
            // that and two hunks would print overlapping context anyway.
            while scan < placed.count, gap <= context * 2 {
                if isKeep(placed[scan].operation) {
                    gap += 1
                } else {
                    gap = 0
                    end = scan
                }
                scan += 1
            }
            let lower = max(0, cursor - context)
            let upper = min(placed.count, end + context + 1)
            if let last = ranges.last, last.upperBound >= lower {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, upper)
            } else {
                ranges.append(lower..<upper)
            }
            cursor = end + 1
        }

        return ranges.map { range in
            var lines: [HunkLine] = []
            var oldCount = 0
            var newCount = 0
            for entry in placed[range] {
                switch entry.operation {
                case let .keep(text):
                    lines.append(HunkLine(kind: .context, text: text))
                    oldCount += 1
                    newCount += 1
                case let .remove(text):
                    lines.append(HunkLine(kind: .removed, text: text))
                    oldCount += 1
                case let .add(text):
                    lines.append(HunkLine(kind: .added, text: text))
                    newCount += 1
                }
            }
            let first = placed[range.lowerBound]
            // Hunk headers are 1-based, the way a unified diff writes them.
            let hunk = DiffHunk(oldStart: first.oldIndex + 1, oldCount: oldCount,
                                newStart: first.newIndex + 1, newCount: newCount,
                                heading: "", lines: lines)
            return PatchApplier.AppliedHunk(hunk: hunk,
                                            originalIndex: first.oldIndex,
                                            newIndex: first.newIndex,
                                            offset: 0,
                                            fuzzy: false)
        }
    }

    private static func isKeep(_ operation: Operation) -> Bool {
        if case .keep = operation { return true }
        return false
    }
}
