import Foundation

/// What Folio knows about the repository a document lives in, as of the last refresh.
struct GitSnapshot: Equatable, Sendable {

    /// Where the file stands relative to the last commit.
    enum FileState: String, Equatable, Sendable {
        /// Tracked, and identical to `HEAD`.
        case committed
        /// Tracked, with changes not yet committed.
        case modified
        /// In the repository's folder but not in the repository.
        case untracked
        /// Matched by a `.gitignore` rule, so committing it would need `--force`.
        case ignored
        /// Part of a merge or rebase that is still unresolved.
        case conflicted
    }

    var root: URL
    /// nil when `HEAD` is detached, which is a state Folio can read but will not write in.
    var branch: String?
    /// The tracking branch, `origin/main` style, or nil when there is none.
    var upstream: String?
    /// Commits the upstream has that we do not.
    var behind = 0
    /// Commits we have that the upstream does not — what a push would send.
    var ahead = 0
    var fileState: FileState = .committed
    /// Whether `user.name` and `user.email` are both set. Git will invent an identity
    /// from the hostname rather than refuse, and a commit authored by
    /// `robin@Robins-MacBook.local` is a nuisance to fix afterwards.
    var hasIdentity = false

    /// Whether a commit could work at all, setting aside whether there is anything to
    /// commit. Kept separate because unsaved edits in the editor become something to
    /// commit the moment the save runs — but they cannot rescue an ignored file, an
    /// unresolved merge, a detached `HEAD` or a missing identity.
    var commitIsPossible: Bool {
        guard branch != nil, hasIdentity else { return false }
        return fileState != .ignored && fileState != .conflicted
    }

    /// Committing needs something to commit, a branch to commit on, and someone to
    /// commit as.
    var canCommit: Bool {
        commitIsPossible && (fileState == .modified || fileState == .untracked)
    }

    /// Pushing needs somewhere to push to and something to send.
    var canPush: Bool { upstream != nil && ahead > 0 }

    /// Why the buttons are off, in one sentence, or nil when they are on.
    var blockedReason: String? {
        if fileState == .conflicted {
            return "This file is part of an unfinished merge. Resolve it in a terminal first."
        }
        if fileState == .ignored { return "This file is ignored by .gitignore." }
        if branch == nil { return "HEAD is detached, so there is no branch to commit on." }
        if !hasIdentity { return "Set user.name and user.email in git before committing." }
        if fileState == .committed { return "No changes to commit." }
        return nil
    }

    /// The branch and how far it has drifted, for the header pill: `main ↑2 ↓1`.
    var summary: String {
        var text = branch ?? "detached"
        if ahead > 0 { text += " ↑\(ahead)" }
        if behind > 0 { text += " ↓\(behind)" }
        return text
    }
}

/// The git commands Folio needs, as questions and two answers.
///
/// Reading is unrestricted; writing is deliberately not. There are exactly two write
/// paths — commit one file, and push the current branch to the upstream it already has
/// — and neither takes an argument that could widen it. Nothing here stages the whole
/// tree, force-pushes, checks out, resets, or merges: those belong in a terminal, where
/// the reader can see what they are doing.
enum GitRepository {

    // MARK: - Reading

    /// Everything the interface needs about `fileURL`, or nil when it is not in a
    /// repository — which is the common case and costs one failed `rev-parse`.
    static func snapshot(for fileURL: URL, using git: Git? = nil) async -> GitSnapshot? {
        let folder = fileURL.deletingLastPathComponent()
        let git = git ?? Git(workingDirectory: folder)

        let rootResult = await git.run(["rev-parse", "--show-toplevel"])
        guard rootResult.succeeded, !rootResult.trimmed.isEmpty else { return nil }
        // `isDirectory: true` rather than letting URL work it out: URL only adds a
        // directory's trailing slash when it stats the path, so the same folder compares
        // unequal depending on how its URL was built. Saying so makes it deterministic.
        let root = URL(fileURLWithPath: rootResult.trimmed, isDirectory: true)
            .resolvingSymlinksInPath()

        var snapshot = GitSnapshot(root: root)

        // Fails on a detached HEAD, which is exactly how we detect one.
        let branch = await git.run(["symbolic-ref", "--quiet", "--short", "HEAD"])
        snapshot.branch = branch.succeeded ? branch.trimmed : nil

        let upstream = await git.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
        snapshot.upstream = upstream.succeeded ? upstream.trimmed : nil

        if snapshot.upstream != nil {
            // `--left-right` counts each side of the fork: left is the upstream, so
            // behind; right is us, so ahead.
            let counts = await git.run(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"])
            let parts = counts.trimmed.split(whereSeparator: \.isWhitespace)
            if counts.succeeded, parts.count == 2 {
                snapshot.behind = Int(parts[0]) ?? 0
                snapshot.ahead = Int(parts[1]) ?? 0
            }
        }

        snapshot.fileState = await fileState(of: fileURL, using: git)
        snapshot.hasIdentity = await hasIdentity(using: git)
        return snapshot
    }

    static func fileState(of fileURL: URL, using git: Git) async -> GitSnapshot.FileState {
        // `-z` because a path with a space or a quote is reported mangled otherwise, and
        // `--ignored` so an ignored file is distinguishable from a merely untracked one.
        let status = await git.run(["status", "--porcelain=v1", "--ignored", "-z", "--", fileURL.path])
        guard status.succeeded else { return .committed }
        // NUL-separated records; the code is the first two characters of the first one.
        guard let record = status.output.split(separator: "\0").first, record.count >= 2 else {
            // No record at all: tracked and unchanged. An empty repository with no
            // commits yet reports nothing for a tracked file either, but there cannot be
            // one — a file with no record is in HEAD.
            return .committed
        }
        let code = String(record.prefix(2))
        if code == "??" { return .untracked }
        if code == "!!" { return .ignored }
        // Either side being `U`, or both sides being the same letter, is a conflict.
        if code.contains("U") || code == "AA" || code == "DD" { return .conflicted }
        return .modified
    }

    /// Whether git has a name and an address to sign a commit with.
    static func hasIdentity(using git: Git) async -> Bool {
        let config = await git.run(["config", "--get-regexp", "^user\\.(name|email)$"])
        guard config.succeeded else { return false }
        var name = false
        var email = false
        for line in config.output.split(separator: "\n") {
            // `user.name Robin Wijnen` — key, space, value. An empty value does not count.
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, !parts[1].trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
            }
            if parts[0] == "user.name" { name = true }
            if parts[0] == "user.email" { email = true }
        }
        return name && email
    }

    // MARK: - Writing

    struct Commit: Equatable, Sendable {
        /// The abbreviated hash, as git prints it.
        var hash: String
        var subject: String
    }

    /// Commits one file, and only that file.
    ///
    /// The pathspec on `git commit` is what keeps this narrow: whatever else the reader
    /// has staged in that repository stays staged and uncommitted. `git add` runs first
    /// because a file git has never seen cannot be named in a commit pathspec.
    static func commit(file fileURL: URL, message: String, using git: Git) async throws -> Commit {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            throw Git.Failure(command: "commit", status: 1, message: "A commit needs a message.")
        }

        try await git.require(["add", "--", fileURL.path])
        // Hooks run here, so this gets the longer of the two local timeouts.
        try await git.require(["commit", "--message", message, "--", fileURL.path],
                              timeout: Git.localTimeout)

        let described = await git.run(["log", "-1", "--pretty=format:%h%n%s"])
        let lines = described.output.split(separator: "\n", omittingEmptySubsequences: false)
        return Commit(hash: lines.first.map(String.init) ?? "",
                      subject: lines.count > 1 ? String(lines[1]) : message)
    }

    /// Sends the current branch to the upstream it already tracks.
    ///
    /// Spelled out as `HEAD:refs/heads/<name>` rather than a bare `git push`, so it does
    /// not depend on the reader's `push.default` and cannot be redirected by it. There is
    /// no force, and no `--set-upstream`: a branch that tracks nothing is reported to the
    /// reader instead, because choosing where a new branch lives is not a decision to
    /// make on someone's behalf. A push rejected as non-fast-forward is reported too —
    /// Folio does not pull, rebase or merge to make it go through.
    static func push(upstream: String, using git: Git) async throws -> String {
        let parts = upstream.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else {
            throw Git.Failure(command: "push", status: 1,
                              message: "Could not tell which remote \(upstream) is on.")
        }
        let remote = String(parts[0])
        let branch = String(parts[1])
        let result = await git.run(["push", "--porcelain", remote, "HEAD:refs/heads/\(branch)"],
                                   timeout: Git.remoteTimeout)
        guard result.succeeded else {
            throw Git.Failure(command: "push", status: result.status, message: Git.describe(result))
        }
        return summarise(push: result.output, remote: remote, branch: branch)
    }

    /// Turns `--porcelain` push output into one readable line.
    ///
    /// The format is a tab-separated record per ref, whose first character is a flag:
    /// a space is a fast-forward, `*` a new ref, `=` already up to date.
    static func summarise(push output: String, remote: String, branch: String) -> String {
        for line in output.split(separator: "\n") where line.hasPrefix("\t") || line.hasPrefix("*")
            || line.hasPrefix("=") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let summary = fields[2]
            if line.hasPrefix("=") { return "\(remote)/\(branch) was already up to date." }
            if line.hasPrefix("*") { return "Created \(remote)/\(branch)." }
            return "Pushed to \(remote)/\(branch) (\(summary))."
        }
        return "Pushed to \(remote)/\(branch)."
    }
}
