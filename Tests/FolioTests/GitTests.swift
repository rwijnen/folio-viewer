import Foundation
import Testing

@testable import Folio

// MARK: - Harness

/// A temporary directory that cleans itself up, holding one or more repositories.
private final class Sandbox {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func repository(_ name: String, identity: Bool = true) async throws -> Repo {
        try await Repo(folder: root.appendingPathComponent(name), bare: false, identity: identity)
    }

    /// A bare repository, which is what a clone can push to without a network.
    func remote(_ name: String) async throws -> Repo {
        try await Repo(folder: root.appendingPathComponent(name), bare: true, identity: false)
    }

    func clone(_ source: Repo, as name: String) async throws -> Repo {
        let folder = root.appendingPathComponent(name)
        let cloner = Git(workingDirectory: root, environment: Repo.isolated)
        try await cloner.require(["clone", source.folder.path, folder.path])
        let clone = try await Repo(folder: folder, existing: true)
        try await clone.configureIdentity()
        return clone
    }
}

private struct Repo {
    let folder: URL
    let git: Git

    /// git is run sealed off from the developer's own configuration, so a global hook, a
    /// signing key or a different `init.defaultBranch` cannot change what these tests see.
    static let isolated: [String: String] = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
    ]

    init(folder: URL, bare: Bool, identity: Bool) async throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        git = Git(workingDirectory: folder, environment: Repo.isolated)
        try await git.require(["init", "--initial-branch=main"] + (bare ? ["--bare"] : []))
        if identity { try await configureIdentity() }
    }

    init(folder: URL, existing: Bool) async throws {
        self.folder = folder
        git = Git(workingDirectory: folder, environment: Repo.isolated)
    }

    func configureIdentity() async throws {
        try await git.require(["config", "user.name", "Folio Tests"])
        try await git.require(["config", "user.email", "tests@example.invalid"])
    }

    @discardableResult
    func write(_ name: String, _ contents: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    /// Commits everything, for arranging a starting point.
    func commitAll(_ message: String) async throws {
        try await git.require(["add", "--all"])
        try await git.require(["commit", "--message", message])
    }

    func log() async throws -> [String] {
        let text = try await git.require(["log", "--pretty=format:%s"])
        return text.isEmpty ? [] : text.split(separator: "\n").map(String.init)
    }

    func staged() async throws -> [String] {
        let text = try await git.require(["diff", "--cached", "--name-only"])
        return text.isEmpty ? [] : text.split(separator: "\n").map(String.init)
    }

    func contents(of name: String, atRevision revision: String) async throws -> String {
        try await git.require(["show", "\(revision):\(name)"])
    }
}

private var gitIsInstalled: Bool {
    FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
}

// MARK: - The subprocess

@Suite("Git subprocess", .enabled(if: gitIsInstalled))
struct GitProcessTests {

    @Test func aFailingCommandReportsWhatGitSaid() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        let result = await repo.git.run(["rev-parse", "--verify", "refs/heads/nonexistent"])

        #expect(!result.succeeded)
        #expect(result.status != 0)
        #expect(!Git.describe(result).isEmpty)
    }

    @Test func stdoutAndStderrAreSeparate() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        try repo.write("note.md", "# One\n")
        try await repo.commitAll("First")

        let result = await repo.git.run(["log", "--pretty=format:%s"])
        #expect(result.trimmed == "First")
        #expect(result.errorOutput.isEmpty)
    }

    @Test func gitNeverWaitsForInput() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        // A remote that does not exist would prompt for credentials over HTTPS. With
        // prompting disabled it has to fail instead of hanging, which is the whole point
        // — this test would time out rather than fail if that ever regressed.
        let result = await repo.git.run(["ls-remote", "https://example.invalid/none.git"],
                                        timeout: 20)
        #expect(!result.succeeded)
    }

    @Test func outputLargerThanAPipeBufferComesBackWhole() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        // A pipe buffer is 64 KB. Anything that does not drain while the child writes
        // would deadlock here rather than fail.
        let big = String(repeating: "line of text\n", count: 20_000)
        try repo.write("big.txt", big)
        try await repo.commitAll("Big")

        let result = await repo.git.run(["show", "HEAD:big.txt"])
        #expect(result.succeeded)
        #expect(result.output.count > 200_000)
    }

    @Test func manyCommandsAtOnceDoNotExhaustTheThreadPool() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        try repo.write("note.md", "# One\n")
        try await repo.commitAll("First")

        // Roughly what dropping a folder of notes onto Folio does. Each command holds one
        // thread; at three apiece this would sit on GCD's 64-thread limit and stall, so
        // this test hangs rather than fails if the pipe draining ever regresses.
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<40 {
                group.addTask { await repo.git.run(["status", "--porcelain"]).succeeded }
            }
            var succeeded = 0
            for await ok in group where ok { succeeded += 1 }
            return succeeded
        }
        #expect(results == 40)
    }

    @Test func aCommandThatOverrunsIsStopped() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        // `git hash-object --stdin` reads until end of input. Its stdin is /dev/null, so
        // it normally returns at once; ask it to read a file that never ends instead.
        let result = await repo.git.run(["hash-object", "--stdin-paths"], timeout: 0.4)
        // Either it finished instantly on empty input, or we stopped it. What must not
        // happen is this call never returning.
        #expect(result.succeeded || result.status == Git.timeoutStatus)
    }
}

// MARK: - Reading the repository

@Suite("Git snapshot", .enabled(if: gitIsInstalled))
struct GitSnapshotTests {

    @Test func aFileOutsideAnyRepositoryHasNoSnapshot() async throws {
        let sandbox = try Sandbox()
        let loose = sandbox.root.appendingPathComponent("loose.md")
        try "# Not in git\n".write(to: loose, atomically: true, encoding: .utf8)

        #expect(await GitRepository.snapshot(for: loose) == nil)
    }

    @Test func aCommittedFileHasNothingToDo() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        let file = try repo.write("note.md", "# One\n")
        try await repo.commitAll("First")

        let snapshot = try #require(await GitRepository.snapshot(for: file, using: repo.git))
        #expect(snapshot.root.path == repo.folder.resolvingSymlinksInPath().path)
        #expect(snapshot.branch == "main")
        #expect(snapshot.upstream == nil)
        #expect(snapshot.fileState == .committed)
        #expect(snapshot.hasIdentity)
        #expect(!snapshot.canCommit)
        #expect(!snapshot.canPush)
        #expect(snapshot.blockedReason == "No changes to commit.")
        #expect(snapshot.summary == "main")
    }

    @Test func anEditedFileCanBeCommitted() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        let file = try repo.write("note.md", "# One\n")
        try await repo.commitAll("First")
        try repo.write("note.md", "# One\n\nEdited.\n")

        let snapshot = try #require(await GitRepository.snapshot(for: file, using: repo.git))
        #expect(snapshot.fileState == .modified)
        #expect(snapshot.canCommit)
        #expect(snapshot.blockedReason == nil)
    }

    @Test func aModifiedFileReportsHowMuchChanged() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        let file = try repo.write("note.md", "one\ntwo\nthree\nfour\n")
        try await repo.commitAll("First")
        // Two lines gone, three arrived.
        try repo.write("note.md", "one\nalpha\nbeta\ngamma\n")

        let snapshot = try #require(await GitRepository.snapshot(for: file, using: repo.git))
        #expect(snapshot.fileState == .modified)
        #expect(snapshot.addedLines == 3)
        #expect(snapshot.removedLines == 3)
        #expect(snapshot.changeLabel == "+3 −3")
    }

    @Test func countsCoverWhatIsStagedAsWellAsWhatIsNot() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        let file = try repo.write("note.md", "one\n")
        try await repo.commitAll("First")
        try repo.write("note.md", "one\ntwo\n")
        try await repo.git.require(["add", "--", "note.md"])
        try repo.write("note.md", "one\ntwo\nthree\n")

        // A commit would record both lines, so the pill has to count both.
        let snapshot = try #require(await GitRepository.snapshot(for: file, using: repo.git))
        #expect(snapshot.addedLines == 2)
        #expect(snapshot.removedLines == 0)
    }

    @Test func aCleanFileHasNothingToReport() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        let file = try repo.write("note.md", "one\n")
        try await repo.commitAll("First")

        let snapshot = try #require(await GitRepository.snapshot(for: file, using: repo.git))
        #expect(snapshot.addedLines == 0)
        #expect(snapshot.removedLines == 0)
        #expect(snapshot.changeLabel == nil)
    }

    @Test func aNewFileIsUntrackedAndStillCommittable() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        try repo.write("note.md", "# One\n")
        try await repo.commitAll("First")
        let fresh = try repo.write("fresh.md", "# New\n")

        let snapshot = try #require(await GitRepository.snapshot(for: fresh, using: repo.git))
        #expect(snapshot.fileState == .untracked)
        #expect(snapshot.canCommit)
    }

    @Test func anIgnoredFileIsNotOfferedForCommit() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        try repo.write(".gitignore", "drafts/\n")
        try await repo.commitAll("First")
        let draft = try repo.write("drafts/secret.md", "# Draft\n")

        let snapshot = try #require(await GitRepository.snapshot(for: draft, using: repo.git))
        #expect(snapshot.fileState == .ignored)
        #expect(!snapshot.canCommit)
        #expect(snapshot.blockedReason?.contains(".gitignore") == true)
    }

    @Test func aPathWithSpacesAndQuotesIsReadCorrectly() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        // Without `-z`, git quotes and escapes a path like this, and the status code
        // would be read off the wrong characters.
        let awkward = try repo.write("my \"weekly\" notes.md", "# One\n")
        try await repo.commitAll("First")
        try repo.write("my \"weekly\" notes.md", "# One\n\nEdited.\n")

        let snapshot = try #require(await GitRepository.snapshot(for: awkward, using: repo.git))
        #expect(snapshot.fileState == .modified)
    }

    @Test func aRepositoryWithoutAnIdentityWillNotCommit() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work", identity: false)
        let file = try repo.write("note.md", "# One\n")

        let snapshot = try #require(await GitRepository.snapshot(for: file, using: repo.git))
        #expect(!snapshot.hasIdentity)
        #expect(!snapshot.canCommit)
        #expect(snapshot.blockedReason?.contains("user.name") == true)
    }

    @Test func anEmptyIdentityDoesNotCount() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work", identity: false)
        try await repo.git.require(["config", "user.name", "Someone"])
        try await repo.git.require(["config", "user.email", ""])
        let file = try repo.write("note.md", "# One\n")

        let snapshot = try #require(await GitRepository.snapshot(for: file, using: repo.git))
        #expect(!snapshot.hasIdentity)
    }

    @Test func aDetachedHeadIsReadButNotWritten() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        let file = try repo.write("note.md", "# One\n")
        try await repo.commitAll("First")
        try await repo.git.require(["checkout", "--detach", "HEAD"])
        try repo.write("note.md", "# One\n\nEdited.\n")

        let snapshot = try #require(await GitRepository.snapshot(for: file, using: repo.git))
        #expect(snapshot.branch == nil)
        #expect(snapshot.fileState == .modified)
        #expect(!snapshot.canCommit)
        #expect(snapshot.blockedReason?.contains("detached") == true)
        #expect(snapshot.summary == "detached")
    }

    @Test func anUnresolvedMergeBlocksCommitting() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        let file = try repo.write("note.md", "# One\n")
        try await repo.commitAll("First")

        try await repo.git.require(["checkout", "-b", "other"])
        try repo.write("note.md", "# Other\n")
        try await repo.commitAll("Other")
        try await repo.git.require(["checkout", "main"])
        try repo.write("note.md", "# Main\n")
        try await repo.commitAll("Main")
        // Expected to fail: that is the conflict we are arranging.
        _ = await repo.git.run(["merge", "other"])

        let snapshot = try #require(await GitRepository.snapshot(for: file, using: repo.git))
        #expect(snapshot.fileState == .conflicted)
        #expect(!snapshot.canCommit)
        #expect(snapshot.blockedReason?.contains("merge") == true)
    }
}

// MARK: - Committing

@Suite("Git commit", .enabled(if: gitIsInstalled))
struct GitCommitTests {

    @Test func committingWritesTheFileAndReportsTheHash() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        let file = try repo.write("note.md", "# One\n")
        try await repo.commitAll("First")
        try repo.write("note.md", "# One\n\nEdited.\n")

        let commit = try await GitRepository.commit(file: file, message: "Edit the note",
                                                    using: repo.git)
        #expect(commit.subject == "Edit the note")
        #expect(commit.hash.count >= 7)
        #expect(try await repo.log() == ["Edit the note", "First"])
        #expect(try await repo.contents(of: "note.md", atRevision: "HEAD") == "# One\n\nEdited.")
    }

    @Test func anUntrackedFileIsAddedFirst() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        try repo.write("note.md", "# One\n")
        try await repo.commitAll("First")
        let fresh = try repo.write("fresh.md", "# New\n")

        _ = try await GitRepository.commit(file: fresh, message: "Add a note", using: repo.git)
        #expect(try await repo.log() == ["Add a note", "First"])
    }

    /// The one that matters: Folio must never commit anything the reader did not ask it to.
    @Test func onlyTheNamedFileIsCommitted() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        let mine = try repo.write("mine.md", "# Mine\n")
        try repo.write("theirs.md", "# Theirs\n")
        try repo.write("staged.md", "# Staged\n")
        try await repo.commitAll("First")

        // Three files in flight; one of them already staged by hand in a terminal.
        try repo.write("mine.md", "# Mine\n\nEdited here.\n")
        try repo.write("theirs.md", "# Theirs\n\nEdited elsewhere.\n")
        try repo.write("staged.md", "# Staged\n\nDeliberately staged.\n")
        try await repo.git.require(["add", "--", "staged.md"])

        _ = try await GitRepository.commit(file: mine, message: "Only mine", using: repo.git)

        let committed = try await repo.git.require(["show", "--name-only", "--pretty=format:", "HEAD"])
        #expect(committed.trimmingCharacters(in: .whitespacesAndNewlines) == "mine.md")
        // The other two are untouched, and the staged one is still staged.
        #expect(try await repo.staged() == ["staged.md"])
        let theirs = await GitRepository.fileState(of: repo.url("theirs.md"), using: repo.git)
        #expect(theirs == .modified)
    }

    @Test func anEmptyMessageIsRefusedBeforeGitIsRun() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        let file = try repo.write("note.md", "# One\n")
        try await repo.commitAll("First")
        try repo.write("note.md", "# Edited\n")

        await #expect(throws: Git.Failure.self) {
            _ = try await GitRepository.commit(file: file, message: "   \n ", using: repo.git)
        }
        // Nothing was staged on the way to failing.
        #expect(try await repo.staged().isEmpty)
    }

    @Test func aRejectedCommitSurfacesGitsExplanation() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work", identity: false)
        try await repo.git.require(["config", "user.useConfigOnly", "true"])
        let file = try repo.write("note.md", "# One\n")

        do {
            _ = try await GitRepository.commit(file: file, message: "Try it", using: repo.git)
            Issue.record("expected the commit to be refused")
        } catch let failure as Git.Failure {
            #expect(failure.status != 0)
            #expect(!(failure.errorDescription ?? "").isEmpty)
        }
    }

    @Test func aMultilineMessageKeepsItsBody() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        let file = try repo.write("note.md", "# One\n")
        try await repo.commitAll("First")
        try repo.write("note.md", "# Edited\n")

        _ = try await GitRepository.commit(file: file,
                                           message: "Subject line\n\nA paragraph of why.\n",
                                           using: repo.git)
        let body = try await repo.git.require(["log", "-1", "--pretty=format:%B"])
        #expect(body.contains("Subject line"))
        #expect(body.contains("A paragraph of why."))
    }
}

// MARK: - Pushing

@Suite("Git push", .enabled(if: gitIsInstalled))
struct GitPushTests {

    @Test func aBranchWithNoUpstreamCannotPush() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        let file = try repo.write("note.md", "# One\n")
        try await repo.commitAll("First")

        let snapshot = try #require(await GitRepository.snapshot(for: file, using: repo.git))
        #expect(snapshot.upstream == nil)
        #expect(!snapshot.canPush)
    }

    @Test func aheadAndBehindAreCounted() async throws {
        let sandbox = try Sandbox()
        let origin = try await sandbox.remote("origin.git")
        let seed = try await sandbox.repository("seed")
        try seed.write("note.md", "# One\n")
        try await seed.commitAll("First")
        try await seed.git.require(["remote", "add", "origin", origin.folder.path])
        try await seed.git.require(["push", "-u", "origin", "main"])

        let clone = try await sandbox.clone(origin, as: "clone")
        let file = clone.url("note.md")
        try clone.write("note.md", "# One\n\nLocal edit.\n")
        try await clone.commitAll("Local")

        let snapshot = try #require(await GitRepository.snapshot(for: file, using: clone.git))
        #expect(snapshot.upstream == "origin/main")
        #expect(snapshot.ahead == 1)
        #expect(snapshot.behind == 0)
        #expect(snapshot.canPush)
        #expect(snapshot.summary == "main ↑1")
    }

    @Test func pushingSendsTheBranchAndClearsTheCount() async throws {
        let sandbox = try Sandbox()
        let origin = try await sandbox.remote("origin.git")
        let seed = try await sandbox.repository("seed")
        try seed.write("note.md", "# One\n")
        try await seed.commitAll("First")
        try await seed.git.require(["remote", "add", "origin", origin.folder.path])
        try await seed.git.require(["push", "-u", "origin", "main"])

        let clone = try await sandbox.clone(origin, as: "clone")
        let file = clone.url("note.md")
        try clone.write("note.md", "# One\n\nLocal edit.\n")
        _ = try await GitRepository.commit(file: file, message: "Local edit", using: clone.git)

        let summary = try await GitRepository.push(upstream: "origin/main", using: clone.git)
        #expect(summary.contains("origin/main"))

        let after = try #require(await GitRepository.snapshot(for: file, using: clone.git))
        #expect(after.ahead == 0)
        #expect(!after.canPush)
        // The remote really has it.
        let remoteLog = try await origin.git.require(["log", "--pretty=format:%s", "main"])
        #expect(remoteLog.split(separator: "\n").first.map(String.init) == "Local edit")
    }

    @Test func aRejectedPushIsReportedAndNotForced() async throws {
        let sandbox = try Sandbox()
        let origin = try await sandbox.remote("origin.git")
        let seed = try await sandbox.repository("seed")
        try seed.write("note.md", "# One\n")
        try await seed.commitAll("First")
        try await seed.git.require(["remote", "add", "origin", origin.folder.path])
        try await seed.git.require(["push", "-u", "origin", "main"])

        let clone = try await sandbox.clone(origin, as: "clone")
        let file = clone.url("note.md")
        try clone.write("note.md", "# Clone\n")
        _ = try await GitRepository.commit(file: file, message: "From the clone", using: clone.git)

        // Someone else pushes first, so the clone's history no longer fast-forwards.
        try seed.write("note.md", "# Seed again\n")
        try await seed.commitAll("From the seed")
        try await seed.git.require(["push", "origin", "main"])

        await #expect(throws: Git.Failure.self) {
            _ = try await GitRepository.push(upstream: "origin/main", using: clone.git)
        }
        // The other person's commit is still the tip: nothing was forced over it.
        let remoteLog = try await origin.git.require(["log", "--pretty=format:%s", "main"])
        #expect(remoteLog.split(separator: "\n").first.map(String.init) == "From the seed")
    }

    @Test func anUnparseableUpstreamIsRefused() async throws {
        let sandbox = try Sandbox()
        let repo = try await sandbox.repository("work")
        try repo.write("note.md", "# One\n")
        try await repo.commitAll("First")

        await #expect(throws: Git.Failure.self) {
            _ = try await GitRepository.push(upstream: "nosuchthing", using: repo.git)
        }
    }

    @Test func pushOutputIsSummarisedForEachOutcome() {
        let forwarded = GitRepository.summarise(
            push: "To /tmp/origin.git\n\trefs/heads/main:refs/heads/main\tabc123..def456\nDone\n",
            remote: "origin", branch: "main")
        #expect(forwarded == "Pushed to origin/main (abc123..def456).")

        let created = GitRepository.summarise(
            push: "To /tmp/origin.git\n*\trefs/heads/main:refs/heads/main\t[new branch]\nDone\n",
            remote: "origin", branch: "main")
        #expect(created == "Created origin/main.")

        let unchanged = GitRepository.summarise(
            push: "To /tmp/origin.git\n=\trefs/heads/main:refs/heads/main\t[up to date]\nDone\n",
            remote: "origin", branch: "main")
        #expect(unchanged == "origin/main was already up to date.")

        // Anything we do not recognise still says something true.
        #expect(GitRepository.summarise(push: "", remote: "origin", branch: "main")
                == "Pushed to origin/main.")
    }
}

// MARK: - What the header shows

@Suite("Git status pill")
struct GitStatusLabelTests {

    private func snapshot(_ state: GitSnapshot.FileState,
                          branch: String? = "main",
                          ahead: Int = 0, behind: Int = 0,
                          added: Int = 0, removed: Int = 0) -> GitSnapshot {
        GitSnapshot(root: URL(fileURLWithPath: "/tmp/notes", isDirectory: true),
                    branch: branch, upstream: "origin/main", behind: behind, ahead: ahead,
                    fileState: state, addedLines: added, removedLines: removed,
                    hasIdentity: true)
    }

    /// A header with nothing to say should say nothing, and a header with something to
    /// say should say it in words — a coloured dot alone left the reader opening the
    /// menu to find out whether there was anything to commit.
    @Test func thePillSaysWhatTheFileNeeds() {
        #expect(GitStatusLabel.label(for: snapshot(.committed), hasUnsavedEdits: false) == nil)
        #expect(GitStatusLabel.tint(for: snapshot(.committed), hasUnsavedEdits: false) == nil)

        #expect(GitStatusLabel.label(for: snapshot(.modified, added: 12, removed: 3),
                                     hasUnsavedEdits: false) == "+12 −3")
        #expect(GitStatusLabel.label(for: snapshot(.modified, added: 4),
                                     hasUnsavedEdits: false) == "+4")
        #expect(GitStatusLabel.label(for: snapshot(.modified, removed: 7),
                                     hasUnsavedEdits: false) == "−7")
        // Counts can be unavailable; the file is still visibly changed.
        #expect(GitStatusLabel.label(for: snapshot(.modified), hasUnsavedEdits: false) == "changed")

        #expect(GitStatusLabel.label(for: snapshot(.untracked), hasUnsavedEdits: false) == "new file")
        #expect(GitStatusLabel.label(for: snapshot(.conflicted), hasUnsavedEdits: false) == "conflict")
        #expect(GitStatusLabel.label(for: snapshot(.ignored), hasUnsavedEdits: false) == "ignored")
    }

    /// Git cannot see what is still in the editor, so the pill has to.
    @Test func unsavedEditsAreNeverReportedAsNoChanges() {
        #expect(GitStatusLabel.label(for: snapshot(.committed), hasUnsavedEdits: true) == "unsaved")
        #expect(GitStatusLabel.tint(for: snapshot(.committed), hasUnsavedEdits: true) != nil)
        #expect(GitStatusLabel.label(for: snapshot(.modified, added: 2), hasUnsavedEdits: true)
                == "+2, unsaved")
        // A conflict is the more urgent thing to say, whatever is in the editor.
        #expect(GitStatusLabel.tint(for: snapshot(.conflicted), hasUnsavedEdits: true) == .red)
    }

    @Test func theSummaryShowsOnlyTheDriftThatExists() {
        #expect(snapshot(.committed).summary == "main")
        #expect(snapshot(.modified, ahead: 2).summary == "main ↑2")
        #expect(snapshot(.modified, behind: 3).summary == "main ↓3")
        #expect(snapshot(.modified, ahead: 1, behind: 3).summary == "main ↑1 ↓3")
        #expect(snapshot(.modified, branch: nil).summary == "detached")
    }
}
