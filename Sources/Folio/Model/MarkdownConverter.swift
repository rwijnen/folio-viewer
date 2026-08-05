import Foundation

/// One heading, used for the outline sidebar and for scroll-to-heading.
struct OutlineItem: Identifiable, Equatable {
    /// Slug, unique within the document — also the HTML anchor id.
    let id: String
    var level: Int
    var title: String
    /// 0-based index into the source lines.
    var lineIndex: Int
}

/// Markdown → HTML, written in Swift so it is unit-testable and so the only
/// JavaScript in the app is mermaid itself.
///
/// Supports the CommonMark subset that documents actually use, plus the GitHub
/// extensions: ATX and setext headings, fenced and indented code, blockquotes,
/// ordered/unordered/task lists with nesting, pipe tables, thematic breaks,
/// reference links, images, autolinks, emphasis, strikethrough and inline code.
/// ` ```mermaid ` fences become diagram containers instead of code blocks.
///
/// Raw HTML is escaped, except a whitelist of attribute-free formatting tags —
/// a viewer should never execute markup it was handed.
enum MarkdownConverter {

    struct Output {
        var bodyHTML: String
        var outline: [OutlineItem]
        var diagramCount: Int
    }

    /// Tags passed through verbatim when they appear as raw HTML. No attributes,
    /// nothing that can load or run anything.
    static let allowedRawTags: Set<String> = [
        "br", "b", "strong", "i", "em", "u", "s", "strike", "del", "ins", "mark",
        "sub", "sup", "kbd", "small", "code", "details", "summary", "dl", "dt", "dd",
    ]

    static func convert(lines: [String], baseURL: URL? = nil) -> Output {
        let builder = Builder(baseURL: baseURL)
        builder.collectLinkDefinitions(lines)
        let body = builder.blocks(lines, lineOffset: 0)
        return Output(bodyHTML: body, outline: builder.outline, diagramCount: builder.diagramCount)
    }

    // MARK: - Builder

    private final class Builder {

        let baseURL: URL?
        var outline: [OutlineItem] = []
        var diagramCount = 0
        private var slugCounts: [String: Int] = [:]
        private var linkDefinitions: [String: String] = [:]

        init(baseURL: URL?) {
            self.baseURL = baseURL
        }

        // MARK: Link definitions

        func collectLinkDefinitions(_ lines: [String]) {
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("["), let closing = trimmed.range(of: "]:") else { continue }
                let label = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing.lowerBound])
                var target = trimmed[closing.upperBound...].trimmingCharacters(in: .whitespaces)
                if let space = target.firstIndex(of: " ") { target = String(target[..<space]) }
                target = target.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                guard !label.isEmpty, !target.isEmpty else { continue }
                linkDefinitions[label.lowercased()] = target
            }
        }

        private func isLinkDefinition(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), let closing = trimmed.range(of: "]:") else { return false }
            let label = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing.lowerBound])
            return linkDefinitions[label.lowercased()] != nil
        }

        // MARK: Block level

        func blocks(_ lines: [String], lineOffset: Int) -> String {
            var html = ""
            var index = 0

            while index < lines.count {
                let line = lines[index]

                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                    continue
                }
                if isLinkDefinition(line) {
                    index += 1
                    continue
                }

                // Fenced code / mermaid
                if let fence = Fence(opening: line) {
                    var body: [String] = []
                    index += 1
                    while index < lines.count, !fence.closes(lines[index]) {
                        body.append(lines[index])
                        index += 1
                    }
                    if index < lines.count { index += 1 }  // consume the closing fence
                    html += codeBlockHTML(body: body, info: fence.info)
                    continue
                }

                // ATX heading
                if let heading = atxHeading(line) {
                    html += headingHTML(level: heading.level, text: heading.text,
                                        lineIndex: lineOffset + index)
                    index += 1
                    continue
                }

                if isThematicBreak(line) {
                    html += "<hr>\n"
                    index += 1
                    continue
                }

                // Blockquote: gather the run, strip one level of markers, recurse.
                if isBlockquote(line) {
                    var quoted: [String] = []
                    while index < lines.count, isBlockquote(lines[index])
                        || (!quoted.isEmpty && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty) {
                        quoted.append(stripBlockquoteMarker(lines[index]))
                        index += 1
                    }
                    html += "<blockquote>\n" + blocks(quoted, lineOffset: lineOffset + index - quoted.count)
                        + "</blockquote>\n"
                    continue
                }

                // Pipe table: header row followed by a delimiter row.
                if index + 1 < lines.count, line.contains("|"), isTableDelimiter(lines[index + 1]) {
                    let (table, consumed) = tableHTML(lines, start: index)
                    html += table
                    index += consumed
                    continue
                }

                // Lists
                if ListMarker(line: line) != nil {
                    let (list, consumed) = listHTML(lines, start: index, lineOffset: lineOffset)
                    html += list
                    index += consumed
                    continue
                }

                // Indented code block (4 spaces), but only outside lists.
                if line.hasPrefix("    ") {
                    var body: [String] = []
                    while index < lines.count,
                          lines[index].hasPrefix("    ") || lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        if lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                           !(index + 1 < lines.count && lines[index + 1].hasPrefix("    ")) {
                            break
                        }
                        body.append(String(lines[index].dropFirst(4)))
                        index += 1
                    }
                    html += codeBlockHTML(body: body, info: "")
                    continue
                }

                // Raw HTML block: pass the whitelist through, escape the rest.
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("<"), looksLikeHTMLBlock(line) {
                    var raw: [String] = []
                    while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        raw.append(lines[index])
                        index += 1
                    }
                    html += raw.map { allowWhitelistedTags(escapeHTML($0)) }.joined(separator: "\n") + "\n"
                    continue
                }

                // Paragraph, honouring setext underlines.
                var paragraph: [String] = []
                var emittedHeading = false
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    if !paragraph.isEmpty, let level = setextLevel(candidate) {
                        html += headingHTML(level: level, text: paragraph.joined(separator: " "),
                                            lineIndex: lineOffset + index - paragraph.count)
                        index += 1
                        emittedHeading = true
                        break
                    }
                    // A block starter interrupts the paragraph.
                    if !paragraph.isEmpty, atxHeading(candidate) != nil || Fence(opening: candidate) != nil
                        || isThematicBreak(candidate) || isBlockquote(candidate)
                        || ListMarker(line: candidate) != nil {
                        break
                    }
                    paragraph.append(candidate)
                    index += 1
                }
                if !emittedHeading, !paragraph.isEmpty {
                    html += "<p>" + inline(paragraph.joined(separator: "\n")) + "</p>\n"
                }
            }

            return html
        }

        // MARK: Headings

        private func headingHTML(level: Int, text: String, lineIndex: Int) -> String {
            let rendered = inline(text)
            let slug = uniqueSlug(for: text)
            outline.append(OutlineItem(id: slug, level: level,
                                       title: plainText(text), lineIndex: lineIndex))
            return "<h\(level) id=\"\(slug)\" data-line=\"\(lineIndex)\">\(rendered)</h\(level)>\n"
        }

        private func uniqueSlug(for text: String) -> String {
            var base = plainText(text).lowercased()
                .replacingOccurrences(of: "'", with: "")
                .map { character -> Character in
                    if character.isLetter || character.isNumber { return character }
                    return "-"
                }
                .reduce(into: "") { result, character in
                    if character == "-", result.last == "-" { return }
                    result.append(character)
                }
            base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if base.isEmpty { base = "section" }
            let count = (slugCounts[base] ?? 0) + 1
            slugCounts[base] = count
            return count == 1 ? base : "\(base)-\(count - 1)"
        }

        /// Markdown with the formatting characters removed — for outline titles.
        private func plainText(_ text: String) -> String {
            var result = text
            for token in ["**", "__", "`", "~~", "*", "_"] {
                result = result.replacingOccurrences(of: token, with: "")
            }
            result = result.replacingOccurrences(
                of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1",
                options: .regularExpression)
            return result.trimmingCharacters(in: .whitespaces)
        }

        // MARK: Code blocks

        private func codeBlockHTML(body: [String], info: String) -> String {
            let language = info.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
            if language == "mermaid" {
                diagramCount += 1
                let source = body.joined(separator: "\n")
                return "<div class=\"diagram\"><pre class=\"mermaid\">\(escapeHTML(source))</pre>"
                    + "<pre class=\"diagram-source\">\(escapeHTML(source))</pre></div>\n"
            }
            let spec = LanguageCatalog.spec(forFenceInfo: language)
            let highlighted = Self.highlightedHTML(lines: body, spec: spec)
            let label = language.isEmpty ? "" : " data-language=\"\(escapeHTML(language))\""
            return "<pre class=\"code\"\(label)><code>\(highlighted)</code></pre>\n"
        }

        /// Reuses the app's lexer so fenced code looks like the diff panels do.
        static func highlightedHTML(lines: [String], spec: LanguageSpec) -> String {
            let table = SyntaxHighlighter.highlight(lines: lines, spec: spec)
            var result: [String] = []
            for (index, line) in lines.enumerated() {
                let characters = Array(line)
                var kinds = [TokenKind?](repeating: nil, count: characters.count)
                if table.indices.contains(index) {
                    for span in table[index] {
                        let lower = max(0, span.range.lowerBound)
                        let upper = min(characters.count, span.range.upperBound)
                        guard lower < upper else { continue }
                        for offset in lower..<upper { kinds[offset] = span.kind }
                    }
                }
                var rendered = ""
                var offset = 0
                while offset < characters.count {
                    let kind = kinds[offset]
                    var end = offset + 1
                    while end < characters.count, kinds[end] == kind { end += 1 }
                    let chunk = escapeHTML(String(characters[offset..<end]))
                    if let kind {
                        rendered += "<span class=\"tk-\(cssClass(for: kind))\">\(chunk)</span>"
                    } else {
                        rendered += chunk
                    }
                    offset = end
                }
                result.append(rendered)
            }
            return result.joined(separator: "\n")
        }

        static func cssClass(for kind: TokenKind) -> String {
            switch kind {
            case .keyword: return "keyword"
            case .type: return "type"
            case .constant: return "constant"
            case .string: return "string"
            case .number: return "number"
            case .comment: return "comment"
            case .annotation: return "annotation"
            }
        }

        // MARK: Tables

        private func tableHTML(_ lines: [String], start: Int) -> (String, Int) {
            let headerCells = splitTableRow(lines[start])
            let alignments = splitTableRow(lines[start + 1]).map { cell -> String in
                let trimmed = cell.trimmingCharacters(in: .whitespaces)
                let left = trimmed.hasPrefix(":")
                let right = trimmed.hasSuffix(":")
                if left && right { return " style=\"text-align:center\"" }
                if right { return " style=\"text-align:right\"" }
                if left { return " style=\"text-align:left\"" }
                return ""
            }
            func alignment(_ column: Int) -> String {
                alignments.indices.contains(column) ? alignments[column] : ""
            }

            var html = "<table>\n<thead>\n<tr>"
            for (column, cell) in headerCells.enumerated() {
                html += "<th\(alignment(column))>\(inline(cell))</th>"
            }
            html += "</tr>\n</thead>\n<tbody>\n"

            var index = start + 2
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty || !line.contains("|") { break }
                let cells = splitTableRow(line)
                html += "<tr>"
                for column in 0..<max(cells.count, headerCells.count) {
                    let value = column < cells.count ? cells[column] : ""
                    html += "<td\(alignment(column))>\(inline(value))</td>"
                }
                html += "</tr>\n"
                index += 1
            }
            html += "</tbody>\n</table>\n"
            return (html, index - start)
        }

        private func splitTableRow(_ line: String) -> [String] {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
            var cells: [String] = []
            var current = ""
            var escaped = false
            for character in trimmed {
                if escaped {
                    current.append(character)
                    escaped = false
                    continue
                }
                if character == "\\" {
                    escaped = true
                    current.append(character)
                    continue
                }
                if character == "|" {
                    cells.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    continue
                }
                current.append(character)
            }
            cells.append(current.trimmingCharacters(in: .whitespaces))
            return cells
        }

        // MARK: Lists

        private func listHTML(_ lines: [String], start: Int, lineOffset: Int) -> (String, Int) {
            guard let first = ListMarker(line: lines[start]) else { return ("", 1) }
            let ordered = first.ordered
            var items: [[String]] = []
            var current: [String] = []
            var index = start
            var loose = false
            var sawBlank = false

            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.isEmpty {
                    // A blank line ends the list unless more indented content follows.
                    let next = index + 1
                    guard next < lines.count else { break }
                    let following = lines[next]
                    let followingIndent = following.prefix(while: { $0 == " " }).count
                    let isItem = ListMarker(line: following) != nil
                    if followingIndent > first.indent || (isItem && followingIndent >= first.indent) {
                        sawBlank = true
                        current.append("")
                        index += 1
                        continue
                    }
                    break
                }

                if let marker = ListMarker(line: line), marker.indent <= first.indent {
                    if !current.isEmpty { items.append(current) }
                    if sawBlank { loose = true }
                    sawBlank = false
                    current = [marker.content]
                    index += 1
                    continue
                }

                let indent = line.prefix(while: { $0 == " " }).count
                if indent > first.indent || !current.isEmpty {
                    // Continuation or nested block: drop the item's indent.
                    let strip = min(indent, first.indent + first.markerWidth)
                    current.append(String(line.dropFirst(strip)))
                    index += 1
                    continue
                }
                break
            }
            if !current.isEmpty { items.append(current) }

            var html = ordered ? "<ol\(first.startAttribute)>\n" : "<ul>\n"
            for item in items {
                html += "<li\(taskClass(item.first ?? ""))>"
                html += itemHTML(item, loose: loose, lineOffset: lineOffset)
                html += "</li>\n"
            }
            html += ordered ? "</ol>\n" : "</ul>\n"
            return (html, index - start)
        }

        private func taskClass(_ firstLine: String) -> String {
            TaskMarker(line: firstLine) == nil ? "" : " class=\"task\""
        }

        private func itemHTML(_ item: [String], loose: Bool, lineOffset: Int) -> String {
            var content = item
            var checkbox = ""
            if let task = TaskMarker(line: content.first ?? "") {
                checkbox = "<input type=\"checkbox\" disabled\(task.checked ? " checked" : "")> "
                content[0] = task.rest
            }
            while content.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { content.removeLast() }

            let isComplex = content.dropFirst().contains { line in
                line.trimmingCharacters(in: .whitespaces).isEmpty
                    || ListMarker(line: line) != nil
                    || Fence(opening: line) != nil
                    || atxHeading(line) != nil
                    || isBlockquote(line)
            }
            if !isComplex {
                return checkbox + inline(content.joined(separator: "\n"))
            }
            // Nested blocks: the first line stays inline so the bullet text is not
            // wrapped in its own paragraph.
            var html = checkbox
            var rest = content
            let lead = rest.removeFirst()
            html += inline(lead)
            let nested = blocks(rest, lineOffset: lineOffset)
            if loose {
                return "<p>" + checkbox + inline(lead) + "</p>\n" + nested
            }
            return html + "\n" + nested
        }

        // MARK: Inline

        private static let codePlaceholderStart = "\u{1}"
        private static let codePlaceholderEnd = "\u{2}"

        func inline(_ raw: String) -> String {
            // 1. Lift code spans out so nothing else touches their contents.
            var codeSpans: [String] = []
            var text = ""
            let characters = Array(raw)
            var index = 0
            while index < characters.count {
                if characters[index] == "\\", index + 1 < characters.count,
                   "\\`*_{}[]()#+-.!<>~|".contains(characters[index + 1]) {
                    // Backslash escape: keep the literal character, hide it from the
                    // emphasis and link passes.
                    codeSpans.append("literal:" + String(characters[index + 1]))
                    text += Self.codePlaceholderStart + String(codeSpans.count - 1) + Self.codePlaceholderEnd
                    index += 2
                    continue
                }
                if characters[index] == "`" {
                    var ticks = 0
                    while index + ticks < characters.count, characters[index + ticks] == "`" { ticks += 1 }
                    let fence = String(repeating: "`", count: ticks)
                    let remainder = String(characters[(index + ticks)...])
                    if let closing = remainder.range(of: fence) {
                        codeSpans.append("code:" + String(remainder[remainder.startIndex..<closing.lowerBound]))
                        text += Self.codePlaceholderStart + String(codeSpans.count - 1) + Self.codePlaceholderEnd
                        let consumed = remainder.distance(from: remainder.startIndex, to: closing.upperBound)
                        index += ticks + consumed
                        continue
                    }
                }
                text.append(characters[index])
                index += 1
            }

            // 2. Escape everything, then re-allow the formatting whitelist.
            text = MarkdownConverter.allowWhitelistedTags(MarkdownConverter.escapeHTML(text))

            // 3. Images, then links (image first so `![…](…)` is not read as a link).
            text = replaceMatches(in: text, pattern: "!\\[([^\\]]*)\\]\\(\\s*([^)\\s]+)(?:\\s+&quot;([^&]*)&quot;)?\\s*\\)") { groups in
                self.imageHTML(alt: groups[0] ?? "", source: groups[1] ?? "", title: groups[2])
            }
            text = replaceMatches(in: text, pattern: "\\[([^\\]]*)\\]\\(\\s*([^)\\s]+)(?:\\s+&quot;([^&]*)&quot;)?\\s*\\)") { groups in
                self.linkHTML(text: groups[0] ?? "", target: groups[1] ?? "", title: groups[2])
            }
            text = replaceMatches(in: text, pattern: "\\[([^\\]]+)\\]\\[([^\\]]*)\\]") { groups in
                let label = (groups[1]?.isEmpty == false ? groups[1]! : groups[0] ?? "").lowercased()
                guard let target = self.linkDefinitions[label] else { return nil }
                return self.linkHTML(text: groups[0] ?? "", target: target, title: nil)
            }
            text = replaceMatches(in: text, pattern: "&lt;(https?://[^\\s&]+)&gt;") { groups in
                self.linkHTML(text: groups[0] ?? "", target: groups[0] ?? "", title: nil)
            }

            // 4. Emphasis. Strong before emphasis so `***x***` nests correctly.
            text = replaceMatches(in: text, pattern: "\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*") { "<strong>\($0[0] ?? "")</strong>" }
            text = replaceMatches(in: text, pattern: "(?<![A-Za-z0-9_])__(?=\\S)(.+?)(?<=\\S)__(?![A-Za-z0-9_])") { "<strong>\($0[0] ?? "")</strong>" }
            text = replaceMatches(in: text, pattern: "~~(?=\\S)(.+?)(?<=\\S)~~") { "<del>\($0[0] ?? "")</del>" }
            text = replaceMatches(in: text, pattern: "\\*(?=\\S)([^*]+?)(?<=\\S)\\*") { "<em>\($0[0] ?? "")</em>" }
            text = replaceMatches(in: text, pattern: "(?<![A-Za-z0-9_])_(?=\\S)([^_]+?)(?<=\\S)_(?![A-Za-z0-9_])") { "<em>\($0[0] ?? "")</em>" }

            // 5. Hard line breaks, then soft ones.
            text = text.replacingOccurrences(of: "  \n", with: "<br>\n")
            text = text.replacingOccurrences(of: "\\\n", with: "<br>\n")

            // 6. Put the code spans back.
            for (position, span) in codeSpans.enumerated() {
                let placeholder = Self.codePlaceholderStart + String(position) + Self.codePlaceholderEnd
                let replacement: String
                if span.hasPrefix("code:") {
                    replacement = "<code>" + MarkdownConverter.escapeHTML(String(span.dropFirst(5))) + "</code>"
                } else {
                    replacement = MarkdownConverter.escapeHTML(String(span.dropFirst("literal:".count)))
                }
                text = text.replacingOccurrences(of: placeholder, with: replacement)
            }
            return text
        }

        private func linkHTML(text: String, target: String, title: String?) -> String {
            let safe = MarkdownConverter.sanitiseURL(target)
            let titleAttribute = title.map { " title=\"\($0)\"" } ?? ""
            guard let safe else { return text }
            let external = safe.hasPrefix("http://") || safe.hasPrefix("https://")
            return "<a href=\"\(safe)\"\(titleAttribute)\(external ? " data-external=\"1\"" : "")>\(text)</a>"
        }

        /// Local images are inlined as data URIs: the page has no network access and
        /// no file read access, so this is the only way they can appear.
        private func imageHTML(alt: String, source: String, title: String?) -> String {
            let titleAttribute = title.map { " title=\"\($0)\"" } ?? ""
            if source.hasPrefix("data:") {
                return "<img src=\"\(source)\" alt=\"\(alt)\"\(titleAttribute)>"
            }
            if source.hasPrefix("http://") || source.hasPrefix("https://") {
                return "<span class=\"missing-image\">🖼 \(alt.isEmpty ? source : alt) "
                    + "<span class=\"hint\">(remote image not loaded)</span></span>"
            }
            guard let baseURL else {
                return "<span class=\"missing-image\">🖼 \(alt)</span>"
            }
            let decoded = source.replacingOccurrences(of: "%20", with: " ")
            let url = baseURL.appendingPathComponent(decoded).standardizedFileURL
            guard let data = try? Data(contentsOf: url), data.count < 8_000_000 else {
                return "<span class=\"missing-image\">🖼 \(alt.isEmpty ? decoded : alt) "
                    + "<span class=\"hint\">(not found next to the document)</span></span>"
            }
            let mime = MarkdownConverter.mimeType(forExtension: url.pathExtension.lowercased())
            return "<img src=\"data:\(mime);base64,\(data.base64EncodedString())\" alt=\"\(alt)\"\(titleAttribute)>"
        }

        private func replaceMatches(in text: String, pattern: String,
                                    _ transform: ([String?]) -> String?) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
            else { return text }
            let source = text as NSString
            var result = ""
            var cursor = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                var groups: [String?] = []
                for group in 1..<match.numberOfRanges {
                    let range = match.range(at: group)
                    groups.append(range.location == NSNotFound ? nil : source.substring(with: range))
                }
                guard let replacement = transform(groups) else { continue }
                result += source.substring(with: NSRange(location: cursor,
                                                         length: match.range.location - cursor))
                result += replacement
                cursor = match.range.location + match.range.length
            }
            result += source.substring(from: cursor)
            return result
        }
    }

    // MARK: - Static helpers

    static func escapeHTML(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    /// Turns `&lt;br&gt;` back into `<br>` for the whitelist only — attributes and
    /// everything else stay escaped.
    static func allowWhitelistedTags(_ escaped: String) -> String {
        let names = allowedRawTags.joined(separator: "|")
        guard let regex = try? NSRegularExpression(
            pattern: "&lt;(/?)(\(names))\\s*(/?)&gt;", options: [.caseInsensitive]) else { return escaped }
        let source = escaped as NSString
        return regex.stringByReplacingMatches(
            in: escaped, range: NSRange(location: 0, length: source.length),
            withTemplate: "<$1$2$3>")
    }

    /// Only http(s), mailto and in-page anchors survive; `javascript:` and friends are dropped.
    static func sanitiseURL(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") || value.hasPrefix("http://") || value.hasPrefix("https://")
            || value.hasPrefix("mailto:") {
            return value
        }
        if value.contains(":") { return nil }
        // Relative path to another document: keep it, the app resolves clicks itself.
        return value
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "heic": return "image/heic"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Line classification

    struct Fence {
        var character: Character
        var length: Int
        var info: String

        init?(opening line: String) {
            let trimmed = line.drop(while: { $0 == " " })
            guard line.prefix(while: { $0 == " " }).count <= 3,
                  let first = trimmed.first, first == "`" || first == "~" else { return nil }
            let length = trimmed.prefix(while: { $0 == first }).count
            guard length >= 3 else { return nil }
            let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
            // An info string may not contain a backtick.
            if first == "`", info.contains("`") { return nil }
            self.character = first
            self.length = length
            self.info = info
        }

        func closes(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.allSatisfy({ $0 == character }) else { return false }
            return trimmed.count >= length
        }
    }

    struct ListMarker {
        var indent: Int
        var ordered: Bool
        var content: String
        var markerWidth: Int
        var start: Int?

        var startAttribute: String {
            guard let start, start != 1 else { return "" }
            return " start=\"\(start)\""
        }

        init?(line: String) {
            let indent = line.prefix(while: { $0 == " " }).count
            guard indent <= 8 else { return nil }
            let body = line.dropFirst(indent)
            guard let first = body.first else { return nil }

            if first == "-" || first == "*" || first == "+" {
                let rest = body.dropFirst()
                guard rest.first == " " || rest.isEmpty else { return nil }
                // `- - -` is a thematic break, not a list.
                if MarkdownConverter.isThematicBreak(line) { return nil }
                self.indent = indent
                self.ordered = false
                self.content = String(rest.dropFirst())
                self.markerWidth = 2
                self.start = nil
                return
            }

            let digits = body.prefix(while: { $0.isNumber })
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let afterDigits = body.dropFirst(digits.count)
            guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
            let rest = afterDigits.dropFirst()
            guard rest.first == " " || rest.isEmpty else { return nil }
            self.indent = indent
            self.ordered = true
            self.content = String(rest.dropFirst())
            self.markerWidth = digits.count + 2
            self.start = Int(digits)
        }
    }

    struct TaskMarker {
        var checked: Bool
        var rest: String

        init?(line: String) {
            let trimmed = line.drop(while: { $0 == " " })
            guard trimmed.hasPrefix("[") , trimmed.count >= 3 else { return nil }
            let marker = trimmed.dropFirst().prefix(1)
            guard trimmed.dropFirst(2).first == "]" else { return nil }
            switch marker.lowercased() {
            case " ": checked = false
            case "x": checked = true
            default: return nil
            }
            rest = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
    }

    static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        guard line.prefix(while: { $0 == " " }).count <= 3 else { return nil }
        let trimmed = line.drop(while: { $0 == " " })
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Strip an optional closing run of hashes.
        while text.hasSuffix("#") { text = String(text.dropLast()) }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    static func setextLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    static func isThematicBreak(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { $0 == "-" } || trimmed.allSatisfy { $0 == "*" }
            || trimmed.allSatisfy { $0 == "_" }
    }

    static func isBlockquote(_ line: String) -> Bool {
        line.prefix(while: { $0 == " " }).count <= 3 && line.drop(while: { $0 == " " }).hasPrefix(">")
    }

    static func stripBlockquoteMarker(_ line: String) -> String {
        var body = line.drop(while: { $0 == " " })
        if body.hasPrefix(">") {
            body = body.dropFirst()
            if body.hasPrefix(" ") { body = body.dropFirst() }
        }
        return String(body)
    }

    static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { "|:- ".contains($0) } && trimmed.contains("-")
    }

    /// True only for something shaped like a real tag, so a line that is just an
    /// autolink (`<https://example.com>`) still goes through inline conversion.
    static func looksLikeHTMLBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<"), trimmed.count > 1 else { return false }
        var rest = trimmed.dropFirst()
        if rest.hasPrefix("!") { return true }  // comment or doctype
        if rest.hasPrefix("/") { rest = rest.dropFirst() }
        guard rest.first?.isLetter == true else { return false }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        guard let next = rest.dropFirst(name.count).first else { return true }
        return next == ">" || next == "/" || next == " " || next == "\t"
    }
}

extension LanguageCatalog {

    /// Maps a fence info string (```swift, ```sh, ```yml) onto a lexer spec.
    static func spec(forFenceInfo info: String) -> LanguageSpec {
        switch info {
        case "": return .plain
        case "sh", "shell", "bash", "zsh", "console", "terminal": return shell
        case "js", "javascript", "node", "jsx": return javascript
        case "ts", "typescript", "tsx": return typescript
        case "py", "python": return python
        case "yml", "yaml": return yaml
        case "html", "xml", "svg", "plist": return xml
        case "objc", "objective-c", "c", "h": return cLike
        case "c++", "cpp": return cpp
        case "cs", "csharp", "c#": return csharp
        case "rb", "ruby": return ruby
        case "rs", "rust": return rust
        case "kt", "kotlin": return kotlin
        case "apex", "cls", "trigger": return apex
        case "soql", "sql": return sql
        case "toml", "ini", "cfg", "conf", "properties", "dotenv", "env": return ini
        case "scss", "sass", "less", "css": return css
        case "diff", "patch", "text", "txt", "plain", "none", "md", "markdown": return .plain
        default: return spec(forPath: "fence.\(info)")
        }
    }
}
