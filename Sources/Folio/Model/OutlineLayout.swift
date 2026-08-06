import Foundation

/// Turns the flat list of headings into the tree the sidebar shows.
///
/// Nesting comes from the *relative* level of neighbouring headings rather than the
/// number in `#`, because real documents skip levels — an `H1` followed by an `H3` is
/// still a parent and its child, and a document that starts at `H2` has `H2`s at the top
/// level rather than indented under nothing.
struct OutlineLayout {

    struct Row: Identifiable, Equatable {
        var item: OutlineItem
        /// Nesting depth, 0 for a top-level heading.
        var depth: Int
        var hasChildren: Bool
        var parentID: String?

        var id: String { item.id }
    }

    private(set) var rows: [Row] = []
    private var ancestorsByID: [String: [String]] = [:]
    private var descendantsByID: [String: [String]] = [:]

    var isEmpty: Bool { rows.isEmpty }
    /// How deep the document nests, for offering "show N levels".
    var maximumDepth: Int { rows.map(\.depth).max() ?? 0 }

    init(_ outline: [OutlineItem]) {
        // Stack of (level, id) for the headings that could still be a parent.
        var open: [(level: Int, id: String)] = []
        var children: [String: [String]] = [:]

        for item in outline {
            while let last = open.last, item.level <= last.level {
                open.removeLast()
            }
            let parent = open.last?.id
            ancestorsByID[item.id] = open.map(\.id)
            if let parent { children[parent, default: []].append(item.id) }
            rows.append(Row(item: item, depth: open.count, hasChildren: false, parentID: parent))
            open.append((item.level, item.id))
        }

        for index in rows.indices {
            rows[index].hasChildren = children[rows[index].id] != nil
        }
        // Walk once and push each heading onto every ancestor's list, rather than
        // scanning all rows per row.
        for row in rows {
            for ancestor in ancestorsByID[row.id] ?? [] {
                descendantsByID[ancestor, default: []].append(row.id)
            }
        }
    }

    // MARK: - Queries

    func row(_ id: String) -> Row? { rows.first { $0.id == id } }

    func ancestors(of id: String) -> [String] { ancestorsByID[id] ?? [] }

    /// Everything nested under a heading, at any depth.
    func descendants(of id: String) -> [String] { descendantsByID[id] ?? [] }

    /// Hidden when any heading above it is collapsed.
    func isVisible(_ id: String, collapsed: Set<String>) -> Bool {
        ancestors(of: id).allSatisfy { !collapsed.contains($0) }
    }

    func visibleRows(collapsed: Set<String>) -> [Row] {
        rows.filter { isVisible($0.id, collapsed: collapsed) }
    }

    /// The heading to highlight when the one the reader is on is tucked inside a
    /// collapsed section: the nearest ancestor that is actually on screen.
    func nearestVisible(to id: String, collapsed: Set<String>) -> String? {
        guard row(id) != nil else { return nil }
        if isVisible(id, collapsed: collapsed) { return id }
        // Ancestors run outermost-first, so the last visible one is the nearest.
        return ancestors(of: id).last { isVisible($0, collapsed: collapsed) }
    }

    /// Which headings to collapse so that only `levels` levels remain on screen.
    func collapsed(showing levels: Int) -> Set<String> {
        let keep = max(levels, 1)
        return Set(rows.filter { $0.hasChildren && $0.depth >= keep - 1 }.map(\.id))
    }

    /// Every heading that could be collapsed, for "collapse everything".
    var collapsibleIDs: Set<String> {
        Set(rows.filter(\.hasChildren).map(\.id))
    }
}
