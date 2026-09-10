import Foundation

/// Which project a document belongs to.
///
/// A group is only ever a name. There is no registry and nothing to create or delete: a
/// group exists exactly as long as some open document is in it. That keeps the whole
/// feature to one string per tab, and means a group cannot be left behind empty.
///
/// The name comes from the folder the file is in, unless the reader has said otherwise.
enum DocumentGroup {

    /// The group a document falls into when nobody has said otherwise.
    ///
    /// `isFolder` is for the repository-wide view, whose `url` *is* a folder rather than
    /// a file in one — without it that tab would group under the repository's parent,
    /// away from every document it is about.
    static func automatic(for url: URL, isFolder: Bool = false) -> String {
        let folder = isFolder ? url : url.deletingLastPathComponent()
        let name = folder.lastPathComponent
        // Some URL forms leave nothing behind; the path always says something. A file at
        // the root of a volume genuinely groups under "/", which is at least unambiguous.
        return name.isEmpty ? folder.path : name
    }

    /// The groups present among a set of names, in the order the tab bar should list
    /// them: alphabetical, so the dropdown does not reshuffle as tabs move about.
    static func listed(from names: [String]) -> [String] {
        Array(Set(names)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// Trims a name the reader typed. nil when there is nothing left of it, which is how
    /// "put this back on automatic" is spelled.
    static func sanitised(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
