import Foundation

/// Everything in a repository that is not committed yet, as one diff.
///
/// The view this feeds is the one you want after an agent run: five files touched, and a
/// single place to read all of it. Folio has been a multi-file diff viewer since its first
/// commit, so the work here is producing the diff, not showing it.
enum GitWorkingTree {

    struct Changes {
        var root: URL
        /// A unified diff covering everything, ready for the parser.
        var diffText: String
        /// Untracked files beyond the cap, which are not in `diffText`.
        var omittedUntracked: Int

        var isEmpty: Bool { diffText.isEmpty }
    }

    /// Untracked files are diffed one at a time, so a folder someone has dropped ten
    /// thousand files into cannot turn one menu click into ten thousand subprocesses.
    static let untrackedLimit = 100

    /// The uncommitted state of the repository containing `folder`.
    static func uncommittedChanges(in folder: URL, using runner: Git? = nil) async throws
        -> Changes {
        let probe = runner ?? Git(workingDirectory: folder)
        let rootPath = try await probe.require(["rev-parse", "--show-toplevel"])
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).resolvingSymlinksInPath()
        // Everything below runs from the root, so the paths in the diff are the ones the
        // repository uses and the file sidebar resolves them against one folder.
        var git = probe
        git.workingDirectory = root

        // Tracked work, staged and unstaged alike, because a commit would record both.
        var pieces: [String] = []
        let tracked = await git.run(["diff", "HEAD", "--no-color", "-M"])
        if tracked.succeeded, !tracked.output.isEmpty { pieces.append(tracked.output) }

        // `git diff HEAD` says nothing about a file git has never seen, and a new file is
        // exactly what an assistant run tends to leave behind. `--no-index` produces a
        // proper "new file" diff for each without `git add -N`, which would write to the
        // index — and this view is supposed to read.
        let untracked = await untrackedPaths(using: git)
        var omitted = 0
        if untracked.count > untrackedLimit { omitted = untracked.count - untrackedLimit }
        for path in untracked.prefix(untrackedLimit) {
            // Exit status 1 just means "there were differences", which is the point.
            let result = await git.run(["diff", "--no-index", "--no-color", "--", "/dev/null", path])
            if !result.output.isEmpty { pieces.append(result.output) }
        }

        return Changes(root: root,
                       diffText: pieces.joined(separator: "\n"),
                       omittedUntracked: omitted)
    }

    /// Untracked, not-ignored paths, relative to the repository root.
    static func untrackedPaths(using git: Git) async -> [String] {
        // `-z` so a path with a space or a newline survives; `--untracked-files=all` so a
        // new folder is listed file by file rather than as one directory entry, which the
        // diff below could not use.
        let status = await git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        guard status.succeeded else { return [] }
        return status.output
            .split(separator: "\0")
            .filter { $0.hasPrefix("?? ") }
            .map { String($0.dropFirst(3)) }
            .sorted()
    }
}
