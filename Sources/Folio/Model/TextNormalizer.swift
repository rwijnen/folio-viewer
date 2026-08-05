import Foundation

/// Line splitting and display normalisation shared by the parser, the patcher and the views.
enum TextNormalizer {

    static let tabWidth = 4

    /// Splits text into lines, dropping the empty element produced by a trailing
    /// newline and stripping CR so CRLF files compare cleanly against diff content.
    static func splitLines(_ text: String) -> [String] {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        var lines = body.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
    }

    /// Expands tabs to the next tab stop so the two panels line up column-for-column.
    /// Everything downstream (syntax spans, word diff, search) works on the expanded
    /// text, which keeps character offsets consistent across all of them.
    static func expandTabs(_ line: String) -> String {
        guard line.contains("\t") else { return line }
        var result = ""
        var column = 0
        for character in line {
            if character == "\t" {
                let spaces = tabWidth - (column % tabWidth)
                result.append(String(repeating: " ", count: spaces))
                column += spaces
            } else {
                result.append(character)
                column += 1
            }
        }
        return result
    }

    static func expandTabs(_ lines: [String]) -> [String] {
        lines.map(expandTabs)
    }

    /// Heuristic check so we do not try to render binaries as text.
    static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(4096)
        guard !sample.isEmpty else { return false }
        if sample.contains(0) { return true }
        return false
    }

    /// Reads a text file, tolerating non-UTF8 encodings.
    static func readText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if looksBinary(data) {
            throw ReadError.binary
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw ReadError.unknownEncoding
    }

    enum ReadError: LocalizedError {
        case binary
        case unknownEncoding

        var errorDescription: String? {
            switch self {
            case .binary: return "The file appears to be binary."
            case .unknownEncoding: return "The file is not UTF-8 or Latin-1 text."
            }
        }
    }
}
