import Foundation

/// The YAML block between `---` fences at the top of a Markdown file — what Obsidian,
/// Jekyll, Hugo and most static-site tools call frontmatter.
///
/// Parsed with the subset of YAML that frontmatter actually uses: scalars (plain,
/// quoted, and `|` / `>` blocks), inline `[a, b]` lists, `- item` lists and nested
/// mappings. Anything stranger is kept as text rather than rejected — the point is
/// to show the properties readably, not to validate them.
struct Frontmatter: Equatable {

    indirect enum Value: Equatable {
        case scalar(String)
        case list([Value])
        case map([Entry])
    }

    struct Entry: Equatable {
        var key: String
        var value: Value
    }

    var entries: [Entry]
    /// Lines the block occupies, fences included — the body starts at this index.
    var lineCount: Int

    /// Finds a frontmatter block at the very top of the document, or nil when there is
    /// none. A leading `---` without a closing fence, or with nothing key-shaped inside,
    /// is left alone: it is a thematic break, not frontmatter.
    static func extract(from lines: [String]) -> Frontmatter? {
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let closing = lines.dropFirst().firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed == "---" || trimmed == "..."
        }) else { return nil }
        let body = Array(lines[1..<closing])
        guard body.contains(where: { keyValue($0) != nil }) else { return nil }
        var parser = Parser(lines: body)
        let entries = parser.mapping(indent: parser.nextIndent() ?? 0)
        guard !entries.isEmpty else { return nil }
        return Frontmatter(entries: entries, lineCount: closing + 1)
    }

    // MARK: - Parsing

    private struct Parser {
        let lines: [String]
        var index = 0

        init(lines: [String]) {
            self.lines = lines
        }

        /// Indent of the next meaningful line, skipping blanks and comments.
        mutating func nextIndent() -> Int? {
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    index += 1
                    continue
                }
                return Frontmatter.indent(of: lines[index])
            }
            return nil
        }

        mutating func mapping(indent: Int) -> [Entry] {
            var entries: [Entry] = []
            while let current = nextIndent(), current == indent {
                let line = lines[index]
                guard let (key, rest) = Frontmatter.keyValue(line) else {
                    // Not a key: fold it into the previous value rather than losing it.
                    if case .scalar(let text)? = entries.last?.value {
                        entries[entries.count - 1].value = .scalar(text + " " + line.trimmingCharacters(in: .whitespaces))
                    }
                    index += 1
                    continue
                }
                index += 1
                entries.append(Entry(key: key, value: value(after: rest, parentIndent: indent)))
            }
            return entries
        }

        /// The value for a key whose line ended with `rest` after the colon.
        mutating func value(after rest: String, parentIndent: Int) -> Value {
            let rest = Frontmatter.stripComment(rest).trimmingCharacters(in: .whitespaces)
            if rest == "|" || rest == ">" || rest.hasPrefix("|") || rest.hasPrefix(">") {
                return .scalar(block(folded: rest.hasPrefix(">"), parentIndent: parentIndent))
            }
            if !rest.isEmpty {
                var text = rest
                // A plain scalar may continue on more-indented lines.
                while index < lines.count {
                    let next = lines[index]
                    let trimmed = next.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, Frontmatter.indent(of: next) > parentIndent else { break }
                    text += " " + trimmed
                    index += 1
                }
                return Frontmatter.inlineValue(text)
            }
            // Nothing after the colon: a nested list or mapping, or an empty value.
            let saved = index
            guard let childIndent = nextIndent() else { return .scalar("") }
            let child = lines[index].trimmingCharacters(in: .whitespaces)
            if child.hasPrefix("- ") || child == "-", childIndent >= parentIndent {
                return .list(sequence(indent: childIndent))
            }
            if childIndent > parentIndent {
                return .map(mapping(indent: childIndent))
            }
            index = saved
            return .scalar("")
        }

        mutating func sequence(indent: Int) -> [Value] {
            var items: [Value] = []
            while let current = nextIndent(), current == indent {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") || trimmed == "-" else { break }
                let content = String(trimmed.dropFirst(trimmed == "-" ? 1 : 2))
                let contentIndent = indent + 2
                index += 1
                if let (key, rest) = Frontmatter.keyValue(content), !content.hasPrefix("\""),
                   !content.hasPrefix("'") {
                    // `- key: value` starts a mapping whose other keys sit under `key`.
                    var entries = [Entry(key: key, value: value(after: rest, parentIndent: contentIndent))]
                    if let next = nextIndent(), next == contentIndent {
                        entries += mapping(indent: contentIndent)
                    }
                    items.append(.map(entries))
                } else {
                    var text = content
                    while index < lines.count {
                        let next = lines[index]
                        let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                        guard !nextTrimmed.isEmpty, Frontmatter.indent(of: next) > indent,
                              !nextTrimmed.hasPrefix("- ") else { break }
                        text += " " + nextTrimmed
                        index += 1
                    }
                    items.append(Frontmatter.inlineValue(text))
                }
            }
            return items
        }

        /// A `|` (literal) or `>` (folded) block scalar.
        mutating func block(folded: Bool, parentIndent: Int) -> String {
            var collected: [String] = []
            var blockIndent: Int?
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    collected.append("")
                    index += 1
                    continue
                }
                let lineIndent = Frontmatter.indent(of: line)
                guard lineIndent > parentIndent else { break }
                let base = blockIndent ?? lineIndent
                blockIndent = base
                collected.append(String(line.dropFirst(min(base, lineIndent))))
                index += 1
            }
            while collected.last == "" { collected.removeLast() }
            return folded
                ? collected.split(separator: "", omittingEmptySubsequences: false)
                    .map { $0.joined(separator: " ") }.joined(separator: "\n")
                : collected.joined(separator: "\n")
        }
    }

    // MARK: - Helpers

    static func indent(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    /// `key: rest` when the line is a mapping key, nil otherwise.
    static func keyValue(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("- "), !trimmed.hasPrefix("#") else { return nil }
        var key: String
        var remainder: Substring
        if let quote = trimmed.first, quote == "\"" || quote == "'" {
            guard let end = trimmed.dropFirst().firstIndex(of: quote) else { return nil }
            key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            remainder = trimmed[trimmed.index(after: end)...]
            guard remainder.hasPrefix(":") else { return nil }
            remainder = remainder.dropFirst()
        } else {
            // The first `: ` (or a trailing `:`) separates the key; URLs keep their colons.
            guard let colon = trimmed.range(of: ": ") ?? (trimmed.hasSuffix(":")
                ? trimmed.index(before: trimmed.endIndex)..<trimmed.endIndex : nil) else { return nil }
            key = String(trimmed[..<colon.lowerBound])
            remainder = trimmed[colon.upperBound...]
            guard !key.isEmpty, !key.contains(" #"), key.first != "[", key.first != "{" else { return nil }
        }
        key = key.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, String(remainder))
    }

    /// A value written on one line: a flow list, a quoted string, or plain text.
    static func inlineValue(_ raw: String) -> Value {
        let text = stripComment(raw).trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), text.hasSuffix("]") {
            let inner = String(text.dropFirst().dropLast())
            // `[[Wiki link]]` is a link, not a list holding a list.
            if !inner.hasPrefix("[") || !inner.hasSuffix("]") {
                return .list(splitFlow(inner).map { .scalar(unquote($0)) })
            }
        }
        return .scalar(unquote(text))
    }

    private static func splitFlow(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
                continue
            }
            switch character {
            case "\"", "'": quote = character; current.append(character)
            case "[", "{": depth += 1; current.append(character)
            case "]", "}": depth -= 1; current.append(character)
            case "," where depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default: current.append(character)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts.filter { !$0.isEmpty }
    }

    static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first
        else { return text }
        let inner = String(text.dropFirst().dropLast())
        if first == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        return inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
    }

    /// Drops a ` # comment`, unless the `#` sits inside quotes.
    static func stripComment(_ text: String) -> String {
        var quote: Character?
        var previous: Character = " "
        for (offset, character) in text.enumerated() {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'", previous == " " || offset == 0 {
                quote = character
            } else if character == "#", previous == " " || previous == "\t" {
                return String(text.prefix(offset))
            }
            previous = character
        }
        return text
    }
}
