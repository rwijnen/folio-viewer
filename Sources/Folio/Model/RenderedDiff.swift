import Foundation

/// Compares two versions of a Markdown document as they *read*, rather than as they are
/// written: one page in the newer version's order, with what was added, removed and
/// reworded marked on it — a redline.
///
/// The unit is the top-level block the converter emits: a paragraph, a heading, a whole
/// list, table, fence or quote. Blocks are matched on their rendered HTML, not on their
/// source lines, which is what makes this a comparison of the reading rather than of the
/// text: re-wrapping a paragraph or renumbering a list changes the source and not the
/// page, so it is not reported, while changing a link definition at the bottom of the
/// file changes every paragraph that uses it, so they are.
///
/// A reworded block is shown once, with the words that went struck through and the words
/// that came underlined. The marking is done on the rendered HTML rather than on the
/// Markdown: a change that cuts across `**` or a link's brackets has no clean place to
/// put a marker in the source, but in the HTML the tags are whole tokens and only the
/// text between them is marked.
enum RenderedDiff {

    enum Change: Equatable {
        case unchanged
        case added
        case removed
        /// Reworded: shown once, with the changed words marked.
        case modified
    }

    struct Block: Equatable {
        var change: Change
        var html: String
    }

    struct Result {
        var blocks: [Block]
        /// Mermaid diagrams on the page, which decides whether it loads mermaid at all.
        var diagramCount: Int
        /// True when the documents were too large or too different to line up block by
        /// block, so everything between the common start and end is shown as replaced.
        var isCoarse: Bool

        var addedCount: Int { blocks.filter { $0.change == .added }.count }
        var removedCount: Int { blocks.filter { $0.change == .removed }.count }
        var modifiedCount: Int { blocks.filter { $0.change == .modified }.count }
        var hasChanges: Bool { blocks.contains { $0.change != .unchanged } }

        /// The page body: unchanged blocks as they are, changed ones wrapped so the page
        /// can mark them. Each changed run is numbered so it can be stepped to.
        var bodyHTML: String {
            var html = ""
            var number = 0
            for block in blocks {
                guard block.change != .unchanged else {
                    html += block.html
                    continue
                }
                number += 1
                html += "<div class=\"folio-change folio-change-\(block.change.cssName)\" "
                    + "id=\"folio-change-\(number)\">\n" + block.html + "</div>\n"
            }
            return html
        }
    }

    /// Ceiling on the block alignment table, after the common start and end are trimmed.
    static let maximumBlockProduct = 4_000_000
    /// Ceiling on the word alignment inside one reworded block.
    static let maximumTokenProduct = 400_000
    /// Below this share of words in common, two blocks are not "the same paragraph,
    /// reworded" — they are one taken out and another put in, and are shown that way.
    static let minimumMergeSimilarity = 0.5
    /// Below this, a removed and an added block are not paired at all.
    static let minimumPairSimilarity = 0.3
    /// Ceiling on the removed-by-added table that pairs one run of changes. A run past
    /// it — two long documents with nothing in common, or the coarse fallback above —
    /// is shown as all removed, then all added, rather than spending the time and memory
    /// the block ceiling exists to avoid.
    static let maximumPairProduct = 250_000

    static func compare(original: [String], updated: [String], baseURL: URL? = nil) -> Result {
        let old = MarkdownConverter.convert(lines: original, baseURL: baseURL).blocks
        let new = MarkdownConverter.convert(lines: updated, baseURL: baseURL).blocks
        return compare(old: old, new: new)
    }

    static func compare(old: [MarkdownConverter.Block], new: [MarkdownConverter.Block]) -> Result {
        // Identity is the HTML with what only says *where* it is taken out: the source
        // line it came from, and a heading's id, which gains a suffix when an earlier
        // heading with the same title is added. Outside code, a run of whitespace reads
        // as one space, so re-wrapping a paragraph is not a change either.
        var identities: [String: Int] = [:]
        func identity(_ block: MarkdownConverter.Block) -> Int {
            var key = comparable(block.html)
            if !key.contains("<pre") {
                key = key.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            }
            if let known = identities[key] { return known }
            identities[key] = identities.count
            return identities.count - 1
        }
        let oldIDs = old.map(identity)
        let newIDs = new.map(identity)

        var prefix = 0
        while prefix < min(old.count, new.count), oldIDs[prefix] == newIDs[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              oldIDs[old.count - 1 - suffix] == newIDs[new.count - 1 - suffix] {
            suffix += 1
        }

        let oldMiddle = Array(oldIDs[prefix..<(old.count - suffix)])
        let newMiddle = Array(newIDs[prefix..<(new.count - suffix)])
        var isCoarse = false
        let middle: [Operation]
        if oldMiddle.count * newMiddle.count > maximumBlockProduct {
            isCoarse = true
            middle = oldMiddle.indices.map { .delete($0) } + newMiddle.indices.map { .insert($0) }
        } else {
            middle = script(oldMiddle, newMiddle)
        }

        var blocks: [Block] = new[..<prefix].map { Block(change: .unchanged, html: $0.html) }

        // Removed and added blocks gather between two that match, and are settled once
        // the next match (or the end) shows the run is complete.
        var removed: [MarkdownConverter.Block] = []
        var added: [MarkdownConverter.Block] = []
        func settle() {
            blocks += settleRun(removed: removed, added: added)
            removed = []
            added = []
        }
        for operation in middle {
            switch operation {
            case let .equal(_, j):
                settle()
                blocks.append(Block(change: .unchanged, html: new[prefix + j].html))
            case let .delete(i):
                removed.append(old[prefix + i])
            case let .insert(j):
                added.append(new[prefix + j])
            }
        }
        settle()
        blocks += new[(new.count - suffix)...].map { Block(change: .unchanged, html: $0.html) }

        let diagrams = blocks.reduce(0) { $0 + $1.html.components(separatedBy: "class=\"mermaid\"").count - 1 }
        return Result(blocks: blocks, diagramCount: diagrams, isCoarse: isCoarse)
    }

    // MARK: - A run of changes

    /// Orders one run of removed and added blocks. Each removed block is paired with the
    /// added block most like it, keeping their order; a pair is shown as one reworded
    /// block when enough survives, and as removed-then-added when it does not. What is
    /// left unpaired is shown where it falls.
    private static func settleRun(removed: [MarkdownConverter.Block],
                                  added: [MarkdownConverter.Block]) -> [Block] {
        if removed.isEmpty { return added.map { Block(change: .added, html: $0.html) } }
        if added.isEmpty { return removed.map { Block(change: .removed, html: removedHTML($0.html)) } }
        guard removed.count * added.count <= maximumPairProduct else {
            return removed.map { Block(change: .removed, html: removedHTML($0.html)) }
                + added.map { Block(change: .added, html: $0.html) }
        }

        let pairs = pairing(removed.map { words($0.html) }, added.map { words($0.html) })
        var result: [Block] = []
        var i = 0
        var j = 0
        for (pairedOld, pairedNew) in pairs + [(removed.count, added.count)] {
            while i < pairedOld {
                result.append(Block(change: .removed, html: removedHTML(removed[i].html)))
                i += 1
            }
            while j < pairedNew {
                result.append(Block(change: .added, html: added[j].html))
                j += 1
            }
            guard pairedOld < removed.count else { break }
            result += reworded(from: removed[pairedOld].html, to: added[pairedNew].html)
            i = pairedOld + 1
            j = pairedNew + 1
        }
        return result
    }

    /// The order-keeping pairing of removed to added blocks with the most words in common,
    /// counting only pairs similar enough to be the same block reworded.
    private static func pairing(_ old: [[String]], _ new: [[String]]) -> [(Int, Int)] {
        let rows = old.count, columns = new.count
        var similarity = [Double](repeating: 0, count: rows * columns)
        for i in 0..<rows {
            for j in 0..<columns {
                similarity[i * columns + j] = overlap(old[i], new[j])
            }
        }
        // best[i][j]: the best total over old[i...] and new[j...].
        var best = [Double](repeating: 0, count: (rows + 1) * (columns + 1))
        let width = columns + 1
        for i in stride(from: rows - 1, through: 0, by: -1) {
            for j in stride(from: columns - 1, through: 0, by: -1) {
                var value = max(best[(i + 1) * width + j], best[i * width + j + 1])
                let score = similarity[i * columns + j]
                if score >= minimumPairSimilarity {
                    value = max(value, score + best[(i + 1) * width + j + 1])
                }
                best[i * width + j] = value
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < rows, j < columns {
            let score = similarity[i * columns + j]
            if score >= minimumPairSimilarity,
               best[i * width + j] == score + best[(i + 1) * width + j + 1] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if best[(i + 1) * width + j] >= best[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    /// One block, before and after. Merged into one with the changed words marked when
    /// the two are close enough and the block is prose; otherwise both, the old one first.
    private static func reworded(from old: String, to new: String) -> [Block] {
        let separate = [Block(change: .removed, html: removedHTML(old)),
                        Block(change: .added, html: new)]
        // Code and diagrams read as a whole: marking words inside a highlighted listing
        // or a diagram's source is noise, and a diagram cannot be drawn half-changed.
        guard !old.contains("<pre"), !new.contains("<pre") else { return separate }
        guard let merged = mergedHTML(from: old, to: new) else { return separate }
        return [Block(change: .modified, html: merged)]
    }

    /// The newer block's HTML, every tag of it, with the words taken out put back in
    /// `<del>` and the words put in wrapped in `<ins>`. Old tags are dropped rather than
    /// marked: keeping only the newer block's tags is what keeps the result well formed.
    /// Nil when the two have too little in common for marking words to help.
    static func mergedHTML(from old: String, to new: String) -> String? {
        let a = tokens(old)
        let b = tokens(new)
        guard a.count * b.count <= maximumTokenProduct else { return nil }
        let operations = script(a.map(\.key), b.map(\.key))

        let common = operations.reduce(0) { count, operation in
            if case let .equal(i, _) = operation, a[i].isWord { return count + 1 }
            return count
        }
        let longest = max(a.filter(\.isWord).count, b.filter(\.isWord).count)
        guard longest > 0, Double(common) / Double(longest) >= minimumMergeSimilarity else { return nil }

        var html = ""
        var deleted = ""
        var inserted = ""
        /// Marks the words but not the space after them, so a highlight ends where the
        /// word does.
        func marked(_ text: String, tag: String) -> String {
            let words = text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            return "<\(tag) class=\"folio-word\">\(words)</\(tag)>" + text.dropFirst(words.count)
        }
        func flushDeleted() {
            // Whitespace that went on its own is the newer layout's business, not a change.
            if !deleted.allSatisfy(\.isWhitespace) {
                html += marked(deleted, tag: "del")
            }
            deleted = ""
        }
        func flushInserted() {
            html += inserted.allSatisfy(\.isWhitespace) ? inserted : marked(inserted, tag: "ins")
            inserted = ""
        }
        for operation in operations {
            switch operation {
            case let .equal(_, j):
                flushDeleted()
                flushInserted()
                html += b[j].text
            case let .delete(i):
                // Text only. Its tags are gone with it, and its whitespace is kept so the
                // words do not run together.
                if !a[i].isTag { deleted += a[i].text }
            case let .insert(j):
                // Deletions come first in a run, so what went reads before what came.
                flushDeleted()
                if b[j].isTag {
                    flushInserted()
                    html += b[j].text
                } else {
                    inserted += b[j].text
                }
            }
        }
        flushDeleted()
        flushInserted()
        return html
    }

    // MARK: - HTML handling

    /// A removed block keeps its look but loses what would make it a second target in
    /// the page: its heading id, and the source line it came from in a version that is
    /// not the one on the page.
    static func removedHTML(_ html: String) -> String {
        comparable(html)
    }

    /// The HTML without `id` and `data-line` attributes.
    static func comparable(_ html: String) -> String {
        guard html.contains(" id=\"") || html.contains(" data-line=\"") else { return html }
        return html.replacingOccurrences(of: #" (?:id|data-line)="[^"]*""#, with: "",
                                         options: .regularExpression)
    }

    struct Token {
        var text: String
        var isTag: Bool
        var isWord: Bool
        /// What two tokens are compared by: a tag without where it came from, and any
        /// run of whitespace as any other.
        var key: String {
            if isTag { return RenderedDiff.comparable(text) }
            return isWord || !text.allSatisfy(\.isWhitespace) ? text : " "
        }
    }

    /// Splits HTML into whole tags, entities, words, runs of whitespace and single
    /// characters. An entity stays whole so that marking never cuts one in two.
    static func tokens(_ html: String) -> [Token] {
        var result: [Token] = []
        let characters = Array(html)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            var end = index + 1
            var isTag = false
            var isWord = false
            if character == "<", let close = characters[index...].firstIndex(of: ">") {
                end = close + 1
                isTag = true
            } else if character == "&",
                      let close = characters[index..<min(characters.count, index + 12)].firstIndex(of: ";"),
                      close > index + 1,
                      characters[(index + 1)..<close].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "#" }) {
                end = close + 1
                isWord = true
            } else if character.isLetter || character.isNumber {
                while end < characters.count, characters[end].isLetter || characters[end].isNumber
                        || characters[end] == "_" {
                    end += 1
                }
                isWord = true
            } else if character.isWhitespace {
                while end < characters.count, characters[end].isWhitespace { end += 1 }
            }
            result.append(Token(text: String(characters[index..<end]), isTag: isTag, isWord: isWord))
            index = end
        }
        return result
    }

    /// The words of a block, lower-cased, for judging how alike two blocks are.
    private static func words(_ html: String) -> [String] {
        tokens(html).filter { $0.isWord }.map { $0.text.lowercased() }
    }

    /// Shared words over the longer block's word count, counting repeats.
    private static func overlap(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var counts: [String: Int] = [:]
        for word in a { counts[word, default: 0] += 1 }
        var shared = 0
        for word in b where counts[word, default: 0] > 0 {
            counts[word]! -= 1
            shared += 1
        }
        return Double(shared) / Double(max(a.count, b.count))
    }

    // MARK: - Alignment

    enum Operation: Equatable {
        case equal(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    /// The longest common subsequence as an edit script, deletions before insertions
    /// within a run of changes.
    static func script<T: Hashable>(_ a: [T], _ b: [T]) -> [Operation] {
        let width = b.count + 1
        var table = [Int32](repeating: 0, count: (a.count + 1) * width)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i * width + j] = a[i] == b[j]
                    ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var operations: [Operation] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                operations.append(.equal(i, j))
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                operations.append(.delete(i))
                i += 1
            } else {
                operations.append(.insert(j))
                j += 1
            }
        }
        while i < a.count { operations.append(.delete(i)); i += 1 }
        while j < b.count { operations.append(.insert(j)); j += 1 }
        return operations
    }
}

extension RenderedDiff.Change {
    var cssName: String {
        switch self {
        case .unchanged: return "unchanged"
        case .added: return "added"
        case .removed: return "removed"
        case .modified: return "modified"
        }
    }
}
