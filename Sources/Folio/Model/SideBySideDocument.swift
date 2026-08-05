import Foundation

/// One side of a row: a line number plus its display text and the word ranges to tint.
struct DiffCell {
    var number: Int
    var text: String
    var changedRanges: [Range<Int>] = []
    var characterCount: Int
}

enum RowKind: Equatable {
    case unchanged
    case modified
    case removed
    case added
    /// A skipped region in diff-only mode, labelled with the `@@` header.
    case gap(String)
}

struct DiffRow: Identifiable {
    let id: Int
    var kind: RowKind
    /// nil renders as an empty filler cell (GitHub's grey block).
    var left: DiffCell?
    var right: DiffCell?
}

/// A collapsible run of unchanged rows.
struct Fold: Identifiable, Equatable {
    let id: Int
    /// Rows hidden while the fold is closed.
    var range: Range<Int>
    var count: Int { range.count }
}

/// Everything the split view needs to render one file.
struct SideBySideDocument {
    var rows: [DiffRow] = []
    var folds: [Fold] = []
    /// Full text of both sides, used for syntax highlighting with cross-line state.
    var leftLines: [String] = []
    var rightLines: [String] = []
    var maxColumns: Int = 0
    /// True when the original file was unavailable and only hunk content is shown.
    var isDiffOnly = false
    var warnings: [String] = []
}

/// Turns a parsed file diff (plus, ideally, the original file) into aligned rows.
enum SideBySideBuilder {

    /// Unchanged runs longer than this get folded.
    static let foldThreshold = 12
    /// Unchanged lines kept visible on each side of a fold.
    static let foldEdge = 3

    /// Full-file view: left is the original, right is the patched result.
    static func build(applied: [PatchApplier.AppliedHunk],
                      originalRaw: [String],
                      patchedRaw: [String],
                      warnings: [String]) -> SideBySideDocument {
        let original = TextNormalizer.expandTabs(originalRaw)
        let patched = TextNormalizer.expandTabs(patchedRaw)

        var document = SideBySideDocument()
        document.leftLines = original
        document.rightLines = patched
        document.warnings = warnings

        var rows: [DiffRow] = []
        var folds: [Fold] = []
        var oldIndex = 0
        var newIndex = 0
        var maxColumns = 0

        func cell(_ lines: [String], _ index: Int) -> DiffCell? {
            guard index >= 0, index < lines.count else { return nil }
            let text = lines[index]
            maxColumns = max(maxColumns, text.count)
            return DiffCell(number: index + 1, text: text, characterCount: text.count)
        }

        func emitUnchanged(count: Int) {
            guard count > 0 else { return }
            let start = rows.count
            for _ in 0..<count {
                guard let left = cell(original, oldIndex), let right = cell(patched, newIndex) else {
                    oldIndex += 1
                    newIndex += 1
                    continue
                }
                rows.append(DiffRow(id: rows.count, kind: .unchanged, left: left, right: right))
                oldIndex += 1
                newIndex += 1
            }
            let emitted = rows.count - start
            if emitted > foldThreshold {
                folds.append(Fold(id: folds.count,
                                  range: (start + foldEdge)..<(start + emitted - foldEdge)))
            }
        }

        func flush(_ pendingLeft: inout [DiffCell], _ pendingRight: inout [DiffCell]) {
            guard !pendingLeft.isEmpty || !pendingRight.isEmpty else { return }
            let pairCount = min(pendingLeft.count, pendingRight.count)
            for offset in 0..<pairCount {
                var left = pendingLeft[offset]
                var right = pendingRight[offset]
                if let words = WordDiff.compare(left: left.text, right: right.text) {
                    left.changedRanges = words.left
                    right.changedRanges = words.right
                }
                rows.append(DiffRow(id: rows.count, kind: .modified, left: left, right: right))
            }
            for left in pendingLeft.dropFirst(pairCount) {
                rows.append(DiffRow(id: rows.count, kind: .removed, left: left, right: nil))
            }
            for right in pendingRight.dropFirst(pairCount) {
                rows.append(DiffRow(id: rows.count, kind: .added, left: nil, right: right))
            }
            pendingLeft.removeAll()
            pendingRight.removeAll()
        }

        for entry in applied {
            let hunkStart = max(entry.originalIndex, oldIndex)
            emitUnchanged(count: hunkStart - oldIndex)
            oldIndex = hunkStart
            newIndex = max(entry.newIndex, newIndex)

            var pendingLeft: [DiffCell] = []
            var pendingRight: [DiffCell] = []
            for line in entry.hunk.lines {
                switch line.kind {
                case .context:
                    flush(&pendingLeft, &pendingRight)
                    if let left = cell(original, oldIndex), let right = cell(patched, newIndex) {
                        rows.append(DiffRow(id: rows.count, kind: .unchanged, left: left, right: right))
                    }
                    oldIndex += 1
                    newIndex += 1
                case .removed:
                    if let left = cell(original, oldIndex) { pendingLeft.append(left) }
                    oldIndex += 1
                case .added:
                    if let right = cell(patched, newIndex) { pendingRight.append(right) }
                    newIndex += 1
                }
            }
            flush(&pendingLeft, &pendingRight)
        }

        emitUnchanged(count: max(original.count - oldIndex, 0))

        document.rows = rows
        document.folds = folds
        document.maxColumns = maxColumns
        return document
    }

    /// A file that exists on only one side: everything added, or everything removed.
    static func wholeFile(lines: [String], added: Bool) -> SideBySideDocument {
        let hunk = DiffHunk(
            oldStart: 1, oldCount: added ? 0 : lines.count,
            newStart: 1, newCount: added ? lines.count : 0,
            heading: "",
            lines: lines.map { HunkLine(kind: added ? .added : .removed, text: $0) }
        )
        let applied = [PatchApplier.AppliedHunk(hunk: hunk, originalIndex: 0, newIndex: 0,
                                                offset: 0, fuzzy: false)]
        return build(applied: applied,
                     originalRaw: added ? [] : lines,
                     patchedRaw: added ? lines : [],
                     warnings: [])
    }

    /// Fallback view built from the diff alone: only the hunks, no surrounding file.
    static func buildDiffOnly(file: FileDiff, warnings: [String]) -> SideBySideDocument {
        var document = SideBySideDocument()
        document.isDiffOnly = true
        document.warnings = warnings

        var rows: [DiffRow] = []
        var leftLines: [String] = []
        var rightLines: [String] = []
        var maxColumns = 0

        // Diff-only mode has no full file, so we synthesise dense line arrays for the
        // syntax highlighter: index = line number - 1, gaps filled with empty strings.
        func store(_ lines: inout [String], number: Int, text: String) {
            while lines.count < number - 1 { lines.append("") }
            if lines.count == number - 1 {
                lines.append(text)
            } else if number - 1 < lines.count {
                lines[number - 1] = text
            }
        }

        func makeCell(_ lines: inout [String], number: Int, raw: String) -> DiffCell {
            let text = TextNormalizer.expandTabs(raw)
            maxColumns = max(maxColumns, text.count)
            store(&lines, number: number, text: text)
            return DiffCell(number: number, text: text, characterCount: text.count)
        }

        func flush(_ pendingLeft: inout [DiffCell], _ pendingRight: inout [DiffCell]) {
            guard !pendingLeft.isEmpty || !pendingRight.isEmpty else { return }
            let pairCount = min(pendingLeft.count, pendingRight.count)
            for offset in 0..<pairCount {
                var left = pendingLeft[offset]
                var right = pendingRight[offset]
                if let words = WordDiff.compare(left: left.text, right: right.text) {
                    left.changedRanges = words.left
                    right.changedRanges = words.right
                }
                rows.append(DiffRow(id: rows.count, kind: .modified, left: left, right: right))
            }
            for left in pendingLeft.dropFirst(pairCount) {
                rows.append(DiffRow(id: rows.count, kind: .removed, left: left, right: nil))
            }
            for right in pendingRight.dropFirst(pairCount) {
                rows.append(DiffRow(id: rows.count, kind: .added, left: nil, right: right))
            }
            pendingLeft.removeAll()
            pendingRight.removeAll()
        }

        for hunk in file.hunks {
            rows.append(DiffRow(id: rows.count, kind: .gap(hunk.headerText), left: nil, right: nil))
            var oldNumber = hunk.oldStart
            var newNumber = hunk.newStart
            var pendingLeft: [DiffCell] = []
            var pendingRight: [DiffCell] = []
            for line in hunk.lines {
                switch line.kind {
                case .context:
                    flush(&pendingLeft, &pendingRight)
                    let left = makeCell(&leftLines, number: oldNumber, raw: line.text)
                    let right = makeCell(&rightLines, number: newNumber, raw: line.text)
                    rows.append(DiffRow(id: rows.count, kind: .unchanged, left: left, right: right))
                    oldNumber += 1
                    newNumber += 1
                case .removed:
                    pendingLeft.append(makeCell(&leftLines, number: oldNumber, raw: line.text))
                    oldNumber += 1
                case .added:
                    pendingRight.append(makeCell(&rightLines, number: newNumber, raw: line.text))
                    newNumber += 1
                }
            }
            flush(&pendingLeft, &pendingRight)
        }

        document.rows = rows
        document.leftLines = leftLines
        document.rightLines = rightLines
        document.maxColumns = maxColumns
        return document
    }
}
