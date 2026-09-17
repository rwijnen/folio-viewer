import Foundation

/// A note or a change request the reader left against a passage of a document.
///
/// Folio does not touch the document to record one. An annotation is a reference *to* a
/// passage — the lines it covers and the words that were selected — kept beside the file
/// rather than inside it, so a document under review reads exactly as its author wrote it.
struct Annotation: Identifiable, Equatable, Codable, Sendable {

    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        /// An observation. Something to know, not necessarily something to do.
        case note
        /// Something that should change.
        case changeRequest

        var id: String { rawValue }

        var label: String {
            switch self {
            case .note: return "Note"
            case .changeRequest: return "Change request"
            }
        }

        var symbol: String {
            switch self {
            case .note: return "text.bubble"
            case .changeRequest: return "pencil.line"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    /// The passage as it read where it was selected.
    ///
    /// From the rendered view this is the laid-out text, without the Markdown that
    /// produced it — `**bold**` arrives as `bold`. That is what the reader saw, so it is
    /// what the report quotes back; the source itself is read from the file at the
    /// moment the report is made.
    var quote: String
    /// The source lines the passage covers, 0-based and inclusive.
    var startLine: Int
    var endLine: Int
    var comment: String
    var created = Date()

    /// `56` or `56–58`, as a person would write it — 1-based, the way an editor counts.
    var lineLabel: String {
        startLine == endLine ? "line \(startLine + 1)" : "lines \(startLine + 1)–\(endLine + 1)"
    }
}
