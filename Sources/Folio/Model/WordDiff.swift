import Foundation

/// Token-level diff used to highlight the exact words that changed inside a
/// modified line pair (GitHub's intra-line highlighting).
enum WordDiff {

    struct Result {
        /// Character ranges in the left line that were removed.
        var left: [Range<Int>]
        /// Character ranges in the right line that were added.
        var right: [Range<Int>]
    }

    /// Cost ceiling for the LCS table; beyond this we fall back to line-level colour.
    private static let maxTokenProduct = 60_000
    /// Below this token overlap the two lines are unrelated, so word highlighting
    /// would just be noise.
    private static let minSimilarity = 0.2

    private struct Token {
        var text: String
        var range: Range<Int>
    }

    /// Returns nil when word-level highlighting is not worthwhile.
    static func compare(left: String, right: String) -> Result? {
        guard left != right, !left.isEmpty, !right.isEmpty else { return nil }
        let leftTokens = tokenize(left)
        let rightTokens = tokenize(right)
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return nil }
        guard leftTokens.count * rightTokens.count <= maxTokenProduct else { return nil }

        let common = longestCommonSubsequence(leftTokens, rightTokens)
        let significantCommon = common.filter { !leftTokens[$0.0].text.allSatisfy(\.isWhitespace) }.count
        let denominator = max(
            leftTokens.filter { !$0.text.allSatisfy(\.isWhitespace) }.count,
            rightTokens.filter { !$0.text.allSatisfy(\.isWhitespace) }.count
        )
        guard denominator > 0 else { return nil }
        guard Double(significantCommon) / Double(denominator) >= minSimilarity else { return nil }

        var leftMatched = Set<Int>()
        var rightMatched = Set<Int>()
        for pair in common {
            leftMatched.insert(pair.0)
            rightMatched.insert(pair.1)
        }

        let leftRanges = mergeRanges(leftTokens.enumerated().compactMap { index, token in
            leftMatched.contains(index) ? nil : token.range
        })
        let rightRanges = mergeRanges(rightTokens.enumerated().compactMap { index, token in
            rightMatched.contains(index) ? nil : token.range
        })
        if leftRanges.isEmpty && rightRanges.isEmpty { return nil }
        return Result(left: leftRanges, right: rightRanges)
    }

    /// Splits into identifier runs, whitespace runs and single punctuation characters.
    private static func tokenize(_ line: String) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let start = index
            let character = characters[index]
            if character.isLetter || character.isNumber || character == "_" {
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                    index += 1
                }
            } else if character.isWhitespace {
                while index < characters.count, characters[index].isWhitespace {
                    index += 1
                }
            } else {
                index += 1
            }
            tokens.append(Token(text: String(characters[start..<index]), range: start..<index))
        }
        return tokens
    }

    /// Classic DP LCS with backtracking; returns matched index pairs.
    private static func longestCommonSubsequence(_ lhs: [Token], _ rhs: [Token]) -> [(Int, Int)] {
        let rows = lhs.count
        let columns = rhs.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: columns + 1), count: rows + 1)
        for i in stride(from: rows - 1, through: 0, by: -1) {
            for j in stride(from: columns - 1, through: 0, by: -1) {
                if lhs[i].text == rhs[j].text {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < rows && j < columns {
            if lhs[i].text == rhs[j].text {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    /// Joins adjacent ranges so we paint one background per changed span.
    private static func mergeRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = [sorted[0]]
        for range in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
