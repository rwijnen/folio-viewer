import Foundation

/// One commit that touched a file, as the sidebar lists it.
struct GitCommitSummary: Identifiable, Equatable, Sendable {
    var hash: String
    var shortHash: String
    var author: String
    var date: Date
    var subject: String
    /// What the file was called at this commit. Differs from today's name across a
    /// rename, and `git show` needs the contemporary one.
    var path: String
    /// `Co-Authored-By` trailers, verbatim — `Claude Opus 5 <noreply@anthropic.com>`.
    ///
    /// Folio does not try to work out which of them are people and which are models;
    /// git does not record that, and a list of vendor addresses would be wrong within
    /// the year. It reports who the commit says helped and lets the reader judge.
    var coAuthors: [String] = []

    var id: String { hash }

    var isCoAuthored: Bool { !coAuthors.isEmpty }

    /// The first co-author's name without the address, for a badge.
    var coAuthorName: String? {
        guard let first = coAuthors.first else { return nil }
        guard let bracket = first.firstIndex(of: "<") else { return first }
        let name = first[..<bracket].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? first : name
    }
}

/// Reading a file's past. Nothing here writes.
///
/// The whole feature rests on Folio already having a side-by-side view: git hands over a
/// unified diff and the content the file had before it, which is exactly the pair the
/// existing diff pipeline takes. Nothing about rows, folds, word diffing or highlighting
/// had to be written again.
enum GitHistory {

    /// Enough for any document a person is reading, and a bound on the work if someone
    /// opens a file with ten thousand commits behind it.
    static let defaultLimit = 200

    /// The commits that touched `fileURL`, newest first.
    ///
    /// `--follow` keeps the history going across renames, which prose files collect —
    /// and it is why each commit carries its own path rather than today's.
    static func commits(for fileURL: URL,
                        limit: Int = defaultLimit,
                        using git: Git) async throws -> [GitCommitSummary] {
        // Record and field separators rather than newlines and spaces: a commit subject
        // can contain anything, including both.
        // Co-author values are separated by \u{2} inside their own field, since a
        // name can contain anything a field separator might otherwise be mistaken for.
        let format = "%x1e%H%x1f%h%x1f%an%x1f%aI%x1f%s%x1f"
            + "%(trailers:key=Co-Authored-By,valueonly,separator=%x02)%x1f"
        let output = try await git.require([
            "log", "--follow", "--max-count=\(limit)", "--name-only",
            "--pretty=format:\(format)", "--", fileURL.path,
        ])
        return parseLog(output)
    }

    static func parseLog(_ output: String) -> [GitCommitSummary] {
        var commits: [GitCommitSummary] = []
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime]

        for record in output.split(separator: "\u{1e}", omittingEmptySubsequences: true) {
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count >= 6 else { continue }
            // `--name-only` writes the path after the format, so it trails the last field.
            let trailing = fields.count > 6 ? fields[6] : ""
            let path = trailing.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            let coAuthors = fields[5]
                .split(separator: "\u{2}")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            commits.append(GitCommitSummary(hash: String(fields[0]),
                                            shortHash: String(fields[1]),
                                            author: String(fields[2]),
                                            date: dates.date(from: String(fields[3])) ?? Date(),
                                            subject: String(fields[4]),
                                            path: path,
                                            coAuthors: coAuthors))
        }
        return commits
    }

    /// What one commit did to one file: the parsed diff, plus the content the file had
    /// going in, which is what the split view puts on the left.
    struct Change: Sendable {
        var diff: FileDiff
        var parentLines: [String]
        /// True when there is no parent content — the commit that introduced the file,
        /// or a root commit.
        var isNew: Bool
    }

    static func change(at commit: GitCommitSummary, using git: Git) async throws -> Change {
        let path = commit.path.isEmpty ? nil : commit.path
        guard let path else {
            throw Git.Failure(command: "show", status: 1,
                              message: "Could not tell what this file was called at \(commit.shortHash).")
        }

        // `--format=` suppresses the commit header, leaving the diff on its own.
        // `-M` so a rename is reported as one, matching what the log followed.
        let diffText = try await git.require(
            ["show", "--format=", "--no-color", "-M", commit.hash, "--", path])
        guard let file = DiffParser.parse(text: diffText).files.first else {
            throw Git.Failure(command: "show", status: 1,
                              message: "\(commit.shortHash) records no change to this file.")
        }

        // Across a rename the previous content is under the previous name. The raw path
        // still carries git's `a/` prefix, which is part of the diff's grammar and not
        // part of any path in the repository — asking for `a/note.md` finds nothing, and
        // every commit would then look like the one that added the file.
        let parentPath = file.rawOldPath.map(PathResolver.stripVCSPrefix) ?? path
        let parent = await git.run(["show", "\(commit.hash)^:\(parentPath)"])
        // Failure here is the ordinary case for the commit that added the file, and for
        // a root commit, which has no parent to ask about.
        guard parent.succeeded, file.kind != .added else {
            return Change(diff: file, parentLines: [], isNew: true)
        }
        return Change(diff: file, parentLines: TextNormalizer.splitLines(parent.output), isNew: false)
    }

    /// The file exactly as it stood at a commit, for reading rather than comparing.
    static func contents(of commit: GitCommitSummary, using git: Git) async throws -> String {
        try await git.require(["show", "\(commit.hash):\(commit.path)"])
    }
}
