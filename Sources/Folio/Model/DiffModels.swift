import Foundation

/// What kind of change a single file entry inside a diff represents.
enum FileChangeKind: String {
    case added
    case deleted
    case modified
    case renamed
    case copied
    case modeOnly

    var symbol: String {
        switch self {
        case .added: return "plus.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .renamed: return "arrow.triangle.turn.up.right.circle.fill"
        case .copied: return "doc.on.doc.fill"
        case .modeOnly: return "lock.circle.fill"
        }
    }
}

enum HunkLineKind {
    case context
    case removed
    case added
}

struct HunkLine {
    var kind: HunkLineKind
    var text: String
}

struct DiffHunk {
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    /// Trailing text on the `@@ ... @@` line (usually the enclosing function).
    var heading: String
    var lines: [HunkLine]

    var oldLines: [String] {
        lines.compactMap { $0.kind == .added ? nil : $0.text }
    }

    var newLines: [String] {
        lines.compactMap { $0.kind == .removed ? nil : $0.text }
    }

    var headerText: String {
        let base = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        return heading.isEmpty ? base : "\(base) \(heading)"
    }
}

/// One file entry parsed out of a unified diff.
struct FileDiff: Identifiable {
    let id = UUID()
    /// Path exactly as written in the `---` line (already unquoted, timestamp stripped).
    var rawOldPath: String?
    /// Path exactly as written in the `+++` line.
    var rawNewPath: String?
    var kind: FileChangeKind = .modified
    var isBinary = false
    var hunks: [DiffHunk] = []
    var oldMode: String?
    var newMode: String?

    var additions: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count }
    }

    var deletions: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count }
    }

    /// Path used in the UI: the new path when the file still exists, else the old one.
    var displayPath: String {
        let candidate = rawNewPath ?? rawOldPath ?? "(unknown)"
        return PathResolver.stripVCSPrefix(candidate)
    }

    var displayName: String {
        (displayPath as NSString).lastPathComponent
    }

    var displayDirectory: String {
        let dir = (displayPath as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }

    var renameDescription: String? {
        guard kind == .renamed || kind == .copied,
              let old = rawOldPath, let new = rawNewPath else { return nil }
        let verb = kind == .renamed ? "renamed from" : "copied from"
        return "\(verb) \(PathResolver.stripVCSPrefix(old)) → \(PathResolver.stripVCSPrefix(new))"
    }

    /// True when the diff carries no line-level content we can render.
    var hasNoContent: Bool { hunks.isEmpty }
}

/// A parsed diff document: the list of file entries plus anything we could not attribute.
struct ParsedDiff {
    var files: [FileDiff] = []
    /// Text before the first file entry (commit message from `git format-patch`, etc.).
    var preamble: [String] = []
}
