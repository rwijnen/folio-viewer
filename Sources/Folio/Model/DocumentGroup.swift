import Foundation

/// Which project a document belongs to.
///
/// A group is only ever a name, and it is always chosen by the reader. Deriving one from
/// the folder was tried first and does not survive contact with a real repository: docs
/// split across `guides/`, `reference/` and `adr/` are one project, and folder names make
/// them three.
///
/// There is no registry. A group exists exactly as long as some open document names it,
/// which means it cannot be left behind empty and nothing has to be cleaned up. A
/// document that has not been filed belongs to no group and appears only under
/// "All documents".
enum DocumentGroup {

    /// The groups present among the open documents, in the order the dropdown lists
    /// them: alphabetical, so it does not reshuffle as tabs move about.
    static func listed(from names: [String?]) -> [String] {
        Array(Set(names.compactMap { $0 })).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// Tidies a name the reader typed. nil when nothing is left of it, which is also how
    /// "take this out of its group" is spelled.
    static func sanitised(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
