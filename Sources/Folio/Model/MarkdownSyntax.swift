import Foundation

/// Highlighting for Markdown *source* mode.
///
/// The generic lexer is token-oriented and Markdown is line-oriented, so this is a
/// separate pass: it colours structure (headings, list markers, quotes, emphasis,
/// links, inline code) and hands fenced code blocks to the real lexer for whatever
/// language the fence declares.
enum MarkdownSyntax {

    static func spans(for lines: [String]) -> [[SyntaxSpan]] {
        var result = [[SyntaxSpan]](repeating: [], count: lines.count)
        var index = 0

        while index < lines.count {
            let line = lines[index]

            // Fenced block: colour the fences, lex the body as its own language.
            if let fence = MarkdownConverter.Fence(opening: line) {
                result[index] = [SyntaxSpan(range: 0..<line.count, kind: .annotation)]
                let bodyStart = index + 1
                var bodyEnd = bodyStart
                while bodyEnd < lines.count, !fence.closes(lines[bodyEnd]) { bodyEnd += 1 }
                if bodyStart < bodyEnd {
                    let body = Array(lines[bodyStart..<bodyEnd])
                    let language = fence.info.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
                    if language == "mermaid" {
                        for offset in body.indices {
                            result[bodyStart + offset] = mermaidSpans(body[offset])
                        }
                    } else {
                        let spec = LanguageCatalog.spec(forFenceInfo: language)
                        let inner = SyntaxHighlighter.highlight(lines: body, spec: spec)
                        for offset in inner.indices { result[bodyStart + offset] = inner[offset] }
                    }
                }
                if bodyEnd < lines.count {
                    result[bodyEnd] = [SyntaxSpan(range: 0..<lines[bodyEnd].count, kind: .annotation)]
                }
                index = bodyEnd + 1
                continue
            }

            result[index] = lineSpans(line)
            index += 1
        }
        return result
    }

    // MARK: - Single line

    private static func lineSpans(_ line: String) -> [SyntaxSpan] {
        let characters = Array(line)
        guard !characters.isEmpty else { return [] }

        if MarkdownConverter.atxHeading(line) != nil {
            return [SyntaxSpan(range: 0..<characters.count, kind: .keyword)]
        }
        if MarkdownConverter.isThematicBreak(line) || MarkdownConverter.setextLevel(line) != nil {
            return [SyntaxSpan(range: 0..<characters.count, kind: .annotation)]
        }

        var spans: [SyntaxSpan] = []
        var contentStart = 0

        // Leading structure: blockquote markers and list bullets.
        var cursor = characters.prefix(while: { $0 == " " }).count
        while cursor < characters.count, characters[cursor] == ">" {
            spans.append(SyntaxSpan(range: cursor..<(cursor + 1), kind: .comment))
            cursor += 1
            if cursor < characters.count, characters[cursor] == " " { cursor += 1 }
            contentStart = cursor
        }
        if let marker = MarkdownConverter.ListMarker(line: String(characters[contentStart...])) {
            let markerStart = contentStart + marker.indent
            let markerEnd = min(markerStart + marker.markerWidth - 1, characters.count)
            if markerStart < markerEnd {
                spans.append(SyntaxSpan(range: markerStart..<markerEnd, kind: .constant))
            }
            contentStart = min(markerEnd + 1, characters.count)
            if let task = MarkdownConverter.TaskMarker(line: String(characters[contentStart...])) {
                let box = contentStart..<min(contentStart + 3, characters.count)
                spans.append(SyntaxSpan(range: box, kind: task.checked ? .number : .comment))
                contentStart = box.upperBound
            }
        }
        if characters.count > contentStart, String(characters[contentStart...]).hasPrefix("|") {
            // Table row: dim the pipes so the columns stand out.
            for (offset, character) in characters.enumerated() where character == "|" {
                spans.append(SyntaxSpan(range: offset..<(offset + 1), kind: .comment))
            }
        }

        spans.append(contentsOf: inlineSpans(characters, from: contentStart))
        return spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Inline code, emphasis and links. Code wins, so a `**` inside backticks is ignored.
    private static func inlineSpans(_ characters: [Character], from start: Int) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        var covered = [Bool](repeating: false, count: characters.count)
        var index = start

        func cover(_ range: Range<Int>, _ kind: TokenKind) {
            guard range.lowerBound >= 0, range.upperBound <= characters.count,
                  range.lowerBound < range.upperBound else { return }
            for position in range where covered[position] { return }
            for position in range { covered[position] = true }
            spans.append(SyntaxSpan(range: range, kind: kind))
        }

        // Inline code first.
        while index < characters.count {
            guard characters[index] == "`" else {
                index += 1
                continue
            }
            var end = index + 1
            while end < characters.count, characters[end] != "`" { end += 1 }
            if end < characters.count {
                cover(index..<(end + 1), .string)
                index = end + 1
            } else {
                index += 1
            }
        }

        // Emphasis runs.
        for token in ["**", "__", "~~"] {
            spans.append(contentsOf: paired(characters, token: token, kind: .type, covered: &covered))
        }
        for token in ["*", "_"] {
            spans.append(contentsOf: paired(characters, token: token, kind: .type, covered: &covered))
        }

        // Links and images: `[text](target)` — target dimmed, brackets kept plain.
        index = start
        while index < characters.count {
            guard characters[index] == "[" else {
                index += 1
                continue
            }
            guard let closing = findCharacter("]", in: characters, from: index + 1),
                  closing + 1 < characters.count, characters[closing + 1] == "(",
                  let target = findCharacter(")", in: characters, from: closing + 2) else {
                index += 1
                continue
            }
            cover((index + 1)..<closing, .constant)
            cover((closing + 2)..<target, .comment)
            index = target + 1
        }

        return spans
    }

    private static func paired(_ characters: [Character], token: String,
                               kind: TokenKind, covered: inout [Bool]) -> [SyntaxSpan] {
        let marker = Array(token)
        var spans: [SyntaxSpan] = []
        var index = 0
        while index + marker.count <= characters.count {
            guard matches(marker, characters, index), !covered[index] else {
                index += 1
                continue
            }
            var search = index + marker.count
            var found: Int?
            while search + marker.count <= characters.count {
                if matches(marker, characters, search), !covered[search] {
                    found = search
                    break
                }
                search += 1
            }
            guard let end = found else { return spans }
            let range = index..<(end + marker.count)
            var blocked = false
            for position in range where covered[position] { blocked = true }
            if !blocked {
                for position in range { covered[position] = true }
                spans.append(SyntaxSpan(range: range, kind: kind))
            }
            index = end + marker.count
        }
        return spans
    }

    private static func matches(_ marker: [Character], _ characters: [Character], _ index: Int) -> Bool {
        guard index + marker.count <= characters.count else { return false }
        for offset in 0..<marker.count where characters[index + offset] != marker[offset] { return false }
        return true
    }

    private static func findCharacter(_ character: Character, in characters: [Character],
                                      from index: Int) -> Int? {
        var position = index
        while position < characters.count {
            if characters[position] == character { return position }
            position += 1
        }
        return nil
    }

    /// Mermaid source: colour the keywords that start a diagram or an arrow.
    private static func mermaidSpans(_ line: String) -> [SyntaxSpan] {
        let keywords = ["graph", "flowchart", "sequenceDiagram", "classDiagram", "stateDiagram",
                        "stateDiagram-v2", "erDiagram", "journey", "gantt", "pie", "gitGraph",
                        "mindmap", "timeline", "quadrantChart", "requirementDiagram", "C4Context",
                        "subgraph", "end", "participant", "actor", "loop", "alt", "else", "opt",
                        "par", "and", "note", "activate", "deactivate", "class", "state", "section",
                        "title", "direction", "click", "style", "classDef", "linkStyle"]
        let characters = Array(line)
        var spans: [SyntaxSpan] = []
        var index = 0
        while index < characters.count {
            if characters[index].isLetter {
                let start = index
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber
                        || characters[index] == "-" || characters[index] == "_" {
                    index += 1
                }
                let word = String(characters[start..<index])
                if keywords.contains(word) {
                    spans.append(SyntaxSpan(range: start..<index, kind: .keyword))
                }
                continue
            }
            if "-=>|<.o*".contains(characters[index]) {
                let start = index
                while index < characters.count, "-=>|<.o*".contains(characters[index]) { index += 1 }
                if index - start >= 2 {
                    spans.append(SyntaxSpan(range: start..<index, kind: .annotation))
                }
                continue
            }
            if characters[index] == "\"" {
                let start = index
                index += 1
                while index < characters.count, characters[index] != "\"" { index += 1 }
                if index < characters.count { index += 1 }
                spans.append(SyntaxSpan(range: start..<index, kind: .string))
                continue
            }
            if characters[index] == "%" , index + 1 < characters.count, characters[index + 1] == "%" {
                spans.append(SyntaxSpan(range: index..<characters.count, kind: .comment))
                break
            }
            index += 1
        }
        return spans
    }
}
