import Foundation

/// One hit as the Find All pane lists it.
struct FindResult: Identifiable, Equatable {
    /// Its place among all the document's matches, which is the number ⌘G steps through
    /// and the one a click hands back.
    let id: Int
    /// The heading it falls under, when the document has headings.
    var section: String?
    /// Where it is, for views that have line numbers: `12`, or `old 12` in a diff.
    var location: String?
    var before: String
    var match: String
    var after: String
}

/// A run of consecutive results under one heading.
struct FindResultGroup: Identifiable, Equatable {
    /// The id of its first result; a heading can come round twice in a document.
    let id: Int
    var title: String?
    var results: [FindResult]
}

/// Turns the matches each kind of view finds into rows for the Find All pane.
enum FindResults {

    /// How many rows are built. A one-letter query in a long document finds tens of
    /// thousands, and that happens again on every keystroke.
    static let limit = 2000
    static let charactersBefore = 40
    static let charactersAfter = 120

    /// Hits in a source listing or the editor, where `rowIndex` is a line.
    static func text(matches: [SearchMatch], lines: [String],
                     outline: [OutlineItem]) -> [FindResult] {
        var section: String?
        var nextHeading = 0
        return build(matches) { match in
            guard lines.indices.contains(match.rowIndex) else { return nil }
            // Matches arrive in document order, so the headings are only walked once.
            while nextHeading < outline.count, outline[nextHeading].lineIndex <= match.rowIndex {
                section = outline[nextHeading].title
                nextHeading += 1
            }
            return (lines[match.rowIndex], section, "\(match.rowIndex + 1)")
        }
    }

    /// Hits in a side-by-side diff, where `rowIndex` is a row and each row has two sides.
    static func diff(matches: [SearchMatch], rows: [DiffRow]) -> [FindResult] {
        build(matches) { match in
            guard rows.indices.contains(match.rowIndex),
                  let cell = match.isLeft ? rows[match.rowIndex].left : rows[match.rowIndex].right
            else { return nil }
            return (cell.text, nil, "\(match.isLeft ? "old" : "new") \(cell.number)")
        }
    }

    /// Hits as the rendered page reports them, one dictionary each, in `folioFocus` order.
    static func page(_ items: [[String: Any]]) -> [FindResult] {
        items.prefix(limit).enumerated().map { index, item in
            let section = (item["section"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return FindResult(id: index, section: section, location: nil,
                              before: clip(before: item["before"] as? String ?? ""),
                              match: item["match"] as? String ?? "",
                              after: clip(after: item["after"] as? String ?? ""))
        }
    }

    /// Runs of consecutive results that share a heading.
    static func groups(_ results: [FindResult]) -> [FindResultGroup] {
        var groups: [FindResultGroup] = []
        for result in results {
            if let last = groups.indices.last, groups[last].title == result.section {
                groups[last].results.append(result)
            } else {
                groups.append(FindResultGroup(id: result.id, title: result.section, results: [result]))
            }
        }
        return groups
    }

    // MARK: - Snippets

    private static func build(
        _ matches: [SearchMatch],
        source: (SearchMatch) -> (text: String, section: String?, location: String?)?
    ) -> [FindResult] {
        // Several hits on one line are common, and a minified line can be a megabyte.
        var cached: (text: String, characters: [Character])?
        var results: [FindResult] = []
        for (index, match) in matches.prefix(limit).enumerated() {
            guard let found = source(match) else { continue }
            let characters: [Character]
            if let cached, cached.text == found.text {
                characters = cached.characters
            } else {
                characters = Array(found.text)
                cached = (found.text, characters)
            }
            let lower = min(max(match.range.lowerBound, 0), characters.count)
            let upper = min(max(match.range.upperBound, lower), characters.count)
            results.append(FindResult(id: index, section: found.section, location: found.location,
                                      before: clip(before: String(characters[..<lower])),
                                      match: String(characters[lower..<upper]),
                                      after: clip(after: String(characters[upper...]))))
        }
        return results
    }

    static func clip(before text: String) -> String {
        let trimmed = String(text.drop(while: \.isWhitespace))
        return trimmed.count > charactersBefore
            ? "…" + String(trimmed.suffix(charactersBefore)) : trimmed
    }

    static func clip(after text: String) -> String {
        var trimmed = text
        while trimmed.last?.isWhitespace == true { trimmed.removeLast() }
        return trimmed.count > charactersAfter
            ? String(trimmed.prefix(charactersAfter)) + "…" : trimmed
    }
}
