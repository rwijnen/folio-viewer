import Foundation

/// Parser for unified diffs: `git diff`, `git format-patch`, `diff -u`, `svn diff`.
///
/// The parser is deliberately forgiving — real-world diff files are full of noise
/// (mail headers, commit messages, `index` lines, binary stubs). Anything it does
/// not recognise is skipped rather than treated as an error.
enum DiffParser {

    static func parse(text: String) -> ParsedDiff {
        let lines = TextNormalizer.splitLines(text)
        var result = ParsedDiff()
        var current: FileDiff?
        var sawAnyFile = false
        var index = 0

        func flush() {
            guard var file = current else { return }
            current = nil
            if file.kind == .modified {
                if file.rawOldPath == nil && file.rawNewPath != nil {
                    file.kind = .added
                } else if file.rawNewPath == nil && file.rawOldPath != nil {
                    file.kind = .deleted
                } else if file.hunks.isEmpty && !file.isBinary,
                          file.oldMode != nil || file.newMode != nil {
                    file.kind = .modeOnly
                }
            }
            result.files.append(file)
            sawAnyFile = true
        }

        while index < lines.count {
            let line = lines[index]

            // --- new file entry: `diff --git a/x b/y` --------------------------------
            if line.hasPrefix("diff --git ") {
                flush()
                var file = FileDiff()
                if let (old, new) = parseGitDiffCommand(String(line.dropFirst("diff --git ".count))) {
                    file.rawOldPath = old
                    file.rawNewPath = new
                }
                current = file
                index += 1
                continue
            }

            // --- new file entry: `diff -u old new` / `Index: path` (svn) -------------
            if line.hasPrefix("diff ") || line.hasPrefix("Index: ") {
                flush()
                current = FileDiff()
                index += 1
                continue
            }

            // --- git metadata --------------------------------------------------------
            if line.hasPrefix("new file mode ") {
                if current == nil { current = FileDiff() }
                current?.kind = .added
                current?.newMode = String(line.dropFirst("new file mode ".count))
                index += 1
                continue
            }
            if line.hasPrefix("deleted file mode ") {
                if current == nil { current = FileDiff() }
                current?.kind = .deleted
                current?.oldMode = String(line.dropFirst("deleted file mode ".count))
                index += 1
                continue
            }
            if line.hasPrefix("old mode ") {
                current?.oldMode = String(line.dropFirst("old mode ".count))
                index += 1
                continue
            }
            if line.hasPrefix("new mode ") {
                current?.newMode = String(line.dropFirst("new mode ".count))
                index += 1
                continue
            }
            if line.hasPrefix("rename from ") {
                if current == nil { current = FileDiff() }
                current?.kind = .renamed
                current?.rawOldPath = unescapeGitPath(String(line.dropFirst("rename from ".count)))
                index += 1
                continue
            }
            if line.hasPrefix("rename to ") {
                if current == nil { current = FileDiff() }
                current?.kind = .renamed
                current?.rawNewPath = unescapeGitPath(String(line.dropFirst("rename to ".count)))
                index += 1
                continue
            }
            if line.hasPrefix("copy from ") {
                if current == nil { current = FileDiff() }
                current?.kind = .copied
                current?.rawOldPath = unescapeGitPath(String(line.dropFirst("copy from ".count)))
                index += 1
                continue
            }
            if line.hasPrefix("copy to ") {
                if current == nil { current = FileDiff() }
                current?.kind = .copied
                current?.rawNewPath = unescapeGitPath(String(line.dropFirst("copy to ".count)))
                index += 1
                continue
            }
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch")
                || line.hasPrefix("Files ") && line.hasSuffix("differ") {
                if current == nil { current = FileDiff() }
                current?.isBinary = true
                index += 1
                continue
            }
            if line.hasPrefix("index ") || line.hasPrefix("similarity index ")
                || line.hasPrefix("dissimilarity index ") {
                index += 1
                continue
            }

            // --- file header pair `--- old` / `+++ new` ------------------------------
            if line.hasPrefix("--- "), index + 1 < lines.count, lines[index + 1].hasPrefix("+++ ") {
                // A `---`/`+++` pair always starts a fresh entry unless we are already
                // collecting one that has no paths or hunks yet (the `diff --git` case).
                if let existing = current, !existing.hunks.isEmpty {
                    flush()
                }
                if current == nil { current = FileDiff() }
                let old = parseHeaderPath(String(line.dropFirst(4)))
                let new = parseHeaderPath(String(lines[index + 1].dropFirst(4)))
                // Keep git's rename paths if the header only carries /dev/null noise.
                if old != nil || current?.rawOldPath == nil { current?.rawOldPath = old }
                if new != nil || current?.rawNewPath == nil { current?.rawNewPath = new }
                if old == nil { current?.kind = .added }
                if new == nil { current?.kind = .deleted }
                index += 2
                continue
            }

            // --- hunk ---------------------------------------------------------------
            if line.hasPrefix("@@") {
                guard let header = parseHunkHeader(line) else {
                    index += 1
                    continue
                }
                if current == nil { current = FileDiff() }
                var hunk = DiffHunk(
                    oldStart: header.oldStart,
                    oldCount: header.oldCount,
                    newStart: header.newStart,
                    newCount: header.newCount,
                    heading: header.heading,
                    lines: []
                )
                var remainingOld = header.oldCount
                var remainingNew = header.newCount
                index += 1

                while index < lines.count, remainingOld > 0 || remainingNew > 0 {
                    let body = lines[index]
                    if body.hasPrefix("\\") {  // "\ No newline at end of file"
                        index += 1
                        continue
                    }
                    guard let marker = body.first else {
                        // Tools that strip trailing whitespace emit an empty line for
                        // an unchanged empty line.
                        hunk.lines.append(HunkLine(kind: .context, text: ""))
                        remainingOld -= 1
                        remainingNew -= 1
                        index += 1
                        continue
                    }
                    let content = String(body.dropFirst())
                    switch marker {
                    case " ":
                        hunk.lines.append(HunkLine(kind: .context, text: content))
                        remainingOld -= 1
                        remainingNew -= 1
                    case "-":
                        hunk.lines.append(HunkLine(kind: .removed, text: content))
                        remainingOld -= 1
                    case "+":
                        hunk.lines.append(HunkLine(kind: .added, text: content))
                        remainingNew -= 1
                    default:
                        // Unexpected content: the hunk is over (truncated diff).
                        remainingOld = 0
                        remainingNew = 0
                        continue
                    }
                    index += 1
                }

                // Re-derive the counts from what we actually read; truncated diffs lie.
                hunk.oldCount = hunk.lines.filter { $0.kind != .added }.count
                hunk.newCount = hunk.lines.filter { $0.kind != .removed }.count
                current?.hunks.append(hunk)
                continue
            }

            if !sawAnyFile && current == nil {
                result.preamble.append(line)
            }
            index += 1
        }

        flush()
        return result
    }

    // MARK: - Header pieces

    struct HunkHeader {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
        var heading: String
    }

    /// Parses `@@ -1,7 +1,9 @@ optional heading`.
    static func parseHunkHeader(_ line: String) -> HunkHeader? {
        guard line.hasPrefix("@@") else { return nil }
        let afterAt = line.dropFirst(2)
        guard let closing = afterAt.range(of: "@@") else { return nil }
        let ranges = afterAt[afterAt.startIndex..<closing.lowerBound]
            .split(separator: " ", omittingEmptySubsequences: true)
        var old: (Int, Int)?
        var new: (Int, Int)?
        for token in ranges {
            if token.hasPrefix("-") { old = parseRange(token.dropFirst()) }
            if token.hasPrefix("+") { new = parseRange(token.dropFirst()) }
        }
        guard let old, let new else { return nil }
        let heading = afterAt[closing.upperBound...].trimmingCharacters(in: .whitespaces)
        return HunkHeader(oldStart: old.0, oldCount: old.1,
                          newStart: new.0, newCount: new.1, heading: heading)
    }

    /// Parses `12,7` or `12` (count defaults to 1).
    private static func parseRange(_ token: Substring) -> (Int, Int)? {
        let parts = token.split(separator: ",", maxSplits: 1)
        guard let start = Int(parts[0]) else { return nil }
        if parts.count == 2 {
            return (start, Int(parts[1]) ?? 1)
        }
        return (start, 1)
    }

    /// Parses `a/src/main.swift\t2026-08-04 10:00:00` → `a/src/main.swift`.
    /// Returns nil for `/dev/null`.
    static func parseHeaderPath(_ raw: String) -> String? {
        var value = raw
        if let tab = value.firstIndex(of: "\t") {
            value = String(value[value.startIndex..<tab])
        } else if let range = value.range(of: "  ") {
            // `diff -u` pads the timestamp with spaces when there is no tab.
            let tail = value[range.upperBound...]
            if tail.first?.isNumber == true { value = String(value[value.startIndex..<range.lowerBound]) }
        }
        value = unescapeGitPath(value.trimmingCharacters(in: .whitespaces))
        if value.isEmpty || value == "/dev/null" { return nil }
        return value
    }

    /// Parses the two paths out of a `diff --git` command line.
    static func parseGitDiffCommand(_ raw: String) -> (String, String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // Quoted form: "a/some file.txt" "b/some file.txt"
        if trimmed.hasPrefix("\"") {
            var paths: [String] = []
            var buffer = ""
            var inQuotes = false
            var escaped = false
            for character in trimmed {
                if escaped {
                    buffer.append(character)
                    escaped = false
                    continue
                }
                if character == "\\" && inQuotes {
                    buffer.append(character)
                    escaped = true
                    continue
                }
                if character == "\"" {
                    if inQuotes {
                        paths.append(buffer)
                        buffer = ""
                    }
                    inQuotes.toggle()
                    continue
                }
                if inQuotes { buffer.append(character) }
            }
            if paths.count >= 2 {
                return (unescapeGitPath(paths[0]), unescapeGitPath(paths[1]))
            }
            return nil
        }

        let tokens = trimmed.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return nil }
        // Paths with spaces are ambiguous without quoting; git emits `a/x b/x`, so
        // split on the first ` b/` when both prefixes are present.
        if tokens.count > 2, let marker = trimmed.range(of: " b/") {
            let old = String(trimmed[trimmed.startIndex..<marker.lowerBound])
            let new = String(trimmed[trimmed.index(after: marker.lowerBound)...])
            return (old, new)
        }
        return (tokens[0], tokens[1])
    }

    /// Undoes git's C-style quoting of unusual bytes in paths.
    static func unescapeGitPath(_ path: String) -> String {
        var value = path
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        guard value.contains("\\") else { return value }
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let next = iterator.next() else {
                result.append(character)
                break
            }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            default: result.append(next)
            }
        }
        return result
    }
}
