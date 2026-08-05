import Foundation

enum TokenKind: Equatable {
    case keyword
    case type
    case constant
    case string
    case number
    case comment
    case annotation
}

/// A coloured span, expressed in character offsets into a single line.
struct SyntaxSpan {
    var range: Range<Int>
    var kind: TokenKind
}

/// A single-pass lexer that colours a whole file at once so block comments and
/// multi-line strings stay correct across line boundaries.
///
/// It is intentionally shallow: no parsing, no semantic analysis. Good enough to
/// read a diff, cheap enough to run on every file you open.
enum SyntaxHighlighter {

    /// Files longer than this are left uncoloured — the pass is linear, but there
    /// is no point spending time on generated blobs.
    static let maxLines = 60_000

    private enum ScanState: Equatable {
        case normal
        case blockComment(depth: Int)
        case multilineString(delimiter: String)
    }

    static func highlight(lines: [String], spec: LanguageSpec) -> [[SyntaxSpan]] {
        guard lines.count <= maxLines, spec.name != LanguageSpec.plain.name else {
            return Array(repeating: [], count: lines.count)
        }
        var result: [[SyntaxSpan]] = []
        result.reserveCapacity(lines.count)
        var state = ScanState.normal
        for line in lines {
            let (spans, nextState) = scan(line: Array(line), spec: spec, state: state)
            result.append(spans)
            state = nextState
        }
        return result
    }

    // MARK: - Line scanner

    private static func scan(line: [Character], spec: LanguageSpec,
                             state initialState: ScanState) -> ([SyntaxSpan], ScanState) {
        var spans: [SyntaxSpan] = []
        var state = initialState
        var index = 0

        while index < line.count {
            switch state {
            case let .blockComment(depth):
                guard let close = spec.blockCommentClose else {
                    state = .normal
                    continue
                }
                let start = index
                var depth = depth
                var closed = false
                while index < line.count {
                    if spec.nestedBlockComments, let open = spec.blockCommentOpen,
                       matches(open, in: line, at: index) {
                        depth += 1
                        index += open.count
                        continue
                    }
                    if matches(close, in: line, at: index) {
                        index += close.count
                        depth -= 1
                        if depth <= 0 {
                            closed = true
                            break
                        }
                        continue
                    }
                    index += 1
                }
                spans.append(SyntaxSpan(range: start..<index, kind: .comment))
                state = closed ? .normal : .blockComment(depth: depth)

            case let .multilineString(delimiter):
                let start = index
                var closed = false
                while index < line.count {
                    if let escape = spec.escapeCharacter, line[index] == escape {
                        index += 2
                        continue
                    }
                    if matches(delimiter, in: line, at: index) {
                        index += delimiter.count
                        closed = true
                        break
                    }
                    index += 1
                }
                spans.append(SyntaxSpan(range: start..<min(index, line.count), kind: .string))
                state = closed ? .normal : .multilineString(delimiter: delimiter)

            case .normal:
                let character = line[index]

                // Line comment: colours the rest of the line.
                if spec.lineComments.contains(where: { matches($0, in: line, at: index) }) {
                    spans.append(SyntaxSpan(range: index..<line.count, kind: .comment))
                    index = line.count
                    continue
                }

                // Block comment open: colour the token, then let the block-comment
                // branch carry on (adjacent comment spans render as one run).
                if let open = spec.blockCommentOpen, matches(open, in: line, at: index) {
                    spans.append(SyntaxSpan(range: index..<(index + open.count), kind: .comment))
                    index += open.count
                    state = .blockComment(depth: 1)
                    continue
                }

                // Multi-line string open.
                if let delimiter = spec.multilineStringDelimiters.first(where: { matches($0, in: line, at: index) }) {
                    let start = index
                    index += delimiter.count
                    var closed = false
                    while index < line.count {
                        if let escape = spec.escapeCharacter, line[index] == escape {
                            index += 2
                            continue
                        }
                        if matches(delimiter, in: line, at: index) {
                            index += delimiter.count
                            closed = true
                            break
                        }
                        index += 1
                    }
                    spans.append(SyntaxSpan(range: start..<min(index, line.count), kind: .string))
                    if !closed { state = .multilineString(delimiter: delimiter) }
                    continue
                }

                // Single-line string.
                if spec.stringDelimiters.contains(character) {
                    let start = index
                    index += 1
                    while index < line.count {
                        if let escape = spec.escapeCharacter, line[index] == escape {
                            index += 2
                            continue
                        }
                        if line[index] == character {
                            index += 1
                            break
                        }
                        index += 1
                    }
                    spans.append(SyntaxSpan(range: start..<min(index, line.count), kind: .string))
                    continue
                }

                // Annotation / preprocessor directive.
                if spec.annotationPrefixes.contains(character),
                   index + 1 < line.count,
                   isIdentifierStart(line[index + 1]) {
                    let start = index
                    index += 1
                    while index < line.count, isIdentifierBody(line[index]) { index += 1 }
                    spans.append(SyntaxSpan(range: start..<index, kind: .annotation))
                    continue
                }

                // Number literal.
                if character.isNumber, index == 0 || !isIdentifierBody(line[index - 1]) {
                    let start = index
                    while index < line.count, isNumberBody(line[index]) { index += 1 }
                    spans.append(SyntaxSpan(range: start..<index, kind: .number))
                    continue
                }

                // Identifier / keyword.
                if isIdentifierStart(character) {
                    let start = index
                    while index < line.count, isIdentifierBody(line[index]) { index += 1 }
                    let word = String(line[start..<index])
                    let lookup = spec.caseSensitive ? word : word.lowercased()
                    if spec.constants.contains(word) || spec.constants.contains(lookup) {
                        spans.append(SyntaxSpan(range: start..<index, kind: .constant))
                    } else if spec.keywords.contains(word) || (!spec.caseSensitive && spec.keywords.contains(lookup)) {
                        spans.append(SyntaxSpan(range: start..<index, kind: .keyword))
                    } else if spec.types.contains(word) {
                        spans.append(SyntaxSpan(range: start..<index, kind: .type))
                    } else if spec.capitalisedIdentifiersAreTypes, let first = word.first, first.isUppercase {
                        spans.append(SyntaxSpan(range: start..<index, kind: .type))
                    }
                    continue
                }

                index += 1
            }
        }

        return (spans, state)
    }

    // MARK: - Character helpers

    private static func matches(_ token: String, in line: [Character], at index: Int) -> Bool {
        guard !token.isEmpty, index + token.count <= line.count else { return false }
        var offset = index
        for character in token {
            if line[offset] != character { return false }
            offset += 1
        }
        return true
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$"
    }

    private static func isIdentifierBody(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$" || character == "-"
    }

    private static func isNumberBody(_ character: Character) -> Bool {
        character.isHexDigit || character == "." || character == "x" || character == "X"
            || character == "_" || character == "e" || character == "E" || character == "b"
            || character == "o" || character == "L" || character == "f" || character == "u"
    }
}
