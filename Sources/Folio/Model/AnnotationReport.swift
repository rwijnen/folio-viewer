import Foundation

/// Turns a document's annotations into something you can hand to an assistant.
///
/// The output is prose with the file named at the top, because that is what the receiving
/// end needs first: *which* file, then *what* in it, then *what to do about it*. Each item
/// carries the lines it covers and the source as it stands right now — read from the file
/// at the moment the report is made, not remembered from when the note was written — so
/// what the assistant is asked to change is what is actually there.
enum AnnotationReport {

    /// Lines of source quoted back for each item. Enough to locate the passage without
    /// pasting the document.
    static let contextLimit = 12

    static func text(for annotations: [Annotation],
                     file: URL,
                     sourceLines: [String],
                     relativeTo root: URL? = nil) -> String {
        guard !annotations.isEmpty else { return "" }
        let ordered = annotations.sorted { ($0.startLine, $0.created) < ($1.startLine, $1.created) }

        var out = ["# Requested changes to `\(path(of: file, relativeTo: root))`", ""]
        out.append(summary(of: ordered))
        out.append("")
        out.append("Line numbers are 1-based and refer to the file as it stands now.")
        out.append("")

        for (index, annotation) in ordered.enumerated() {
            out.append("## \(index + 1). \(annotation.kind.label) — \(annotation.lineLabel)")
            out.append("")

            let source = self.source(for: annotation, in: sourceLines)
            if !source.isEmpty {
                out.append("Source as it stands:")
                out.append("")
                out.append("```")
                out.append(contentsOf: source)
                out.append("```")
                out.append("")
            }

            let quote = annotation.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            if !quote.isEmpty, source.isEmpty || !sourceContains(quote, source) {
                // Worth repeating only when the rendered selection does not already read
                // plainly in the source above — a selection inside a table or a link, say.
                out.append("Selected text: “\(collapsed(quote))”")
                out.append("")
            }

            out.append(annotation.kind == .changeRequest ? "**Change requested:**" : "**Note:**")
            out.append("")
            out.append(annotation.comment.trimmingCharacters(in: .whitespacesAndNewlines))
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Pieces

    static func summary(of annotations: [Annotation]) -> String {
        let changes = annotations.count { $0.kind == .changeRequest }
        let notes = annotations.count - changes
        var parts: [String] = []
        if changes > 0 { parts.append("\(changes) change request\(changes == 1 ? "" : "s")") }
        if notes > 0 { parts.append("\(notes) note\(notes == 1 ? "" : "s")") }
        return parts.joined(separator: " and ") + "."
    }

    /// The file as the reader would name it: relative to the repository when there is one,
    /// because that is what an assistant working in the repository can act on.
    static func path(of file: URL, relativeTo root: URL?) -> String {
        guard let root else { return file.path }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return file.path.hasPrefix(rootPath)
            ? String(file.path.dropFirst(rootPath.count))
            : file.path
    }

    /// The annotated lines, clamped to the file and to a readable length.
    static func source(for annotation: Annotation, in lines: [String]) -> [String] {
        guard !lines.isEmpty else { return [] }
        let start = max(0, min(annotation.startLine, lines.count - 1))
        let end = max(start, min(annotation.endLine, lines.count - 1))
        let slice = Array(lines[start...end])
        guard slice.count > contextLimit else { return slice }
        return Array(slice.prefix(contextLimit)) + ["… \(slice.count - contextLimit) more lines"]
    }

    private static func sourceContains(_ quote: String, _ source: [String]) -> Bool {
        let joined = collapsed(source.joined(separator: " "))
        return joined.contains(collapsed(quote))
    }

    /// Whitespace flattened, so a selection spanning a wrapped line still matches.
    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
