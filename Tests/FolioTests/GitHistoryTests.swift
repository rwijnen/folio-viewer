import Foundation
import Testing

@testable import Folio

// MARK: - Harness

/// A repository whose history these tests arrange commit by commit.
private final class HistoryRepo {

    let root: URL
    let folder: URL
    let git: Git

    static let isolated: [String: String] = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
    ]

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-history-\(UUID().uuidString)")
        folder = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        git = Git(workingDirectory: folder, environment: HistoryRepo.isolated)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func start() async throws {
        try await git.require(["init", "--initial-branch=main"])
        try await git.require(["config", "user.name", "Folio Tests"])
        try await git.require(["config", "user.email", "tests@example.invalid"])
    }

    func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    @discardableResult
    func commit(_ name: String, _ contents: String, message: String) async throws -> URL {
        let url = self.url(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try await git.require(["add", "--", name])
        try await git.require(["commit", "--message", message])
        return url
    }

    func rename(_ from: String, to: String, message: String) async throws {
        try await git.require(["mv", from, to])
        try await git.require(["commit", "--message", message])
    }

    func delete(_ name: String, message: String) async throws {
        try await git.require(["rm", "--", name])
        try await git.require(["commit", "--message", message])
    }
}

private var gitIsInstalled: Bool {
    FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
}

// MARK: - Reading the log

@Suite("Git history", .enabled(if: gitIsInstalled))
struct GitHistoryTests {

    @Test func theLogIsNewestFirstAndCarriesWhatTheListShows() async throws {
        let repo = try HistoryRepo()
        try await repo.start()
        let file = try await repo.commit("note.md", "# One\n", message: "Add the note")
        try await repo.commit("note.md", "# One\n\nTwo.\n", message: "Add a paragraph")

        let commits = try await GitHistory.commits(for: file, using: repo.git)
        #expect(commits.count == 2)
        #expect(commits.map(\.subject) == ["Add a paragraph", "Add the note"])
        #expect(commits.allSatisfy { $0.author == "Folio Tests" })
        #expect(commits.allSatisfy { $0.path == "note.md" })
        #expect(commits.allSatisfy { $0.shortHash.count >= 7 })
        #expect(commits.allSatisfy { $0.hash.count == 40 })
        // Newest first means the first entry is not older than the second.
        #expect(commits[0].date >= commits[1].date)
    }

    @Test func onlyCommitsTouchingThisFileAreListed() async throws {
        let repo = try HistoryRepo()
        try await repo.start()
        let file = try await repo.commit("note.md", "# One\n", message: "Add the note")
        try await repo.commit("other.md", "# Other\n", message: "Something unrelated")
        try await repo.commit("note.md", "# One\n\nTwo.\n", message: "Extend the note")

        let commits = try await GitHistory.commits(for: file, using: repo.git)
        #expect(commits.map(\.subject) == ["Extend the note", "Add the note"])
    }

    /// Prose files get renamed, and a history that stops at the rename is not a history.
    @Test func historyFollowsARename() async throws {
        let repo = try HistoryRepo()
        try await repo.start()
        try await repo.commit("draft.md", "# Draft\n", message: "Start a draft")
        try await repo.commit("draft.md", "# Draft\n\nMore.\n", message: "Extend the draft")
        try await repo.rename("draft.md", to: "final.md", message: "Rename to final")

        let commits = try await GitHistory.commits(for: repo.url("final.md"), using: repo.git)
        #expect(commits.map(\.subject) == ["Rename to final", "Extend the draft", "Start a draft"])
        // Each commit carries the name the file had then, which is what `git show` needs.
        #expect(commits.map(\.path) == ["final.md", "draft.md", "draft.md"])
    }

    @Test func aLimitIsRespected() async throws {
        let repo = try HistoryRepo()
        try await repo.start()
        for index in 1...6 {
            try await repo.commit("note.md", "# One\n\(index)\n", message: "Change \(index)")
        }
        let commits = try await GitHistory.commits(for: repo.url("note.md"), limit: 3,
                                                   using: repo.git)
        #expect(commits.count == 3)
        #expect(commits.first?.subject == "Change 6")
    }

    @Test func awkwardSubjectsSurviveParsing() async throws {
        let repo = try HistoryRepo()
        try await repo.start()
        // Tabs, quotes and a pipe would all break a naive separator.
        let awkward = "Fix \"quoting\" | tab\there, and a — dash"
        let file = try await repo.commit("note.md", "# One\n", message: awkward)

        let commits = try await GitHistory.commits(for: file, using: repo.git)
        #expect(commits.first?.subject == awkward)
    }

    @Test func anEmptyLogParsesToNothing() {
        #expect(GitHistory.parseLog("").isEmpty)
        #expect(GitHistory.parseLog("\n\n").isEmpty)
    }
}

// MARK: - One commit's change

@Suite("Git history change", .enabled(if: gitIsInstalled))
struct GitHistoryChangeTests {

    @Test func aModificationCarriesTheContentItWasMadeAgainst() async throws {
        let repo = try HistoryRepo()
        try await repo.start()
        let file = try await repo.commit("note.md", "# One\nkeep\n", message: "Add the note")
        try await repo.commit("note.md", "# One\nkeep\nadded\n", message: "Add a line")

        let commits = try await GitHistory.commits(for: file, using: repo.git)
        let change = try await GitHistory.change(at: commits[0], using: repo.git)

        #expect(!change.isNew)
        #expect(change.parentLines == ["# One", "keep"])
        #expect(change.diff.additions == 1)
        #expect(change.diff.deletions == 0)
    }

    @Test func theCommitThatAddedTheFileHasNoParentContent() async throws {
        let repo = try HistoryRepo()
        try await repo.start()
        try await repo.commit("seed.md", "# Seed\n", message: "First")
        let file = try await repo.commit("note.md", "# One\n", message: "Add the note")

        let commits = try await GitHistory.commits(for: file, using: repo.git)
        let change = try await GitHistory.change(at: try #require(commits.last), using: repo.git)
        #expect(change.isNew)
        #expect(change.parentLines.isEmpty)
    }

    /// A root commit has no `^` to ask about, which must read as "new" and not as an error.
    @Test func theVeryFirstCommitInARepositoryWorks() async throws {
        let repo = try HistoryRepo()
        try await repo.start()
        let file = try await repo.commit("note.md", "# One\n", message: "The very first")

        let commits = try await GitHistory.commits(for: file, using: repo.git)
        #expect(commits.count == 1)
        let change = try await GitHistory.change(at: commits[0], using: repo.git)
        #expect(change.isNew)
        #expect(change.parentLines.isEmpty)
    }

    @Test func acrossARenameTheParentIsFoundUnderTheOldName() async throws {
        let repo = try HistoryRepo()
        try await repo.start()
        try await repo.commit("draft.md", "# Draft\nbody\n", message: "Start a draft")
        try await repo.rename("draft.md", to: "final.md", message: "Rename to final")
        // A change after the rename, so the diff is a real one.
        try await repo.commit("final.md", "# Draft\nbody\nmore\n", message: "Extend it")

        let commits = try await GitHistory.commits(for: repo.url("final.md"), using: repo.git)
        let change = try await GitHistory.change(at: commits[0], using: repo.git)
        #expect(change.parentLines == ["# Draft", "body"])
    }

    @Test func theFileCanBeReadWholeAtAnyCommit() async throws {
        let repo = try HistoryRepo()
        try await repo.start()
        let file = try await repo.commit("note.md", "# First\n", message: "One")
        try await repo.commit("note.md", "# Second\n", message: "Two")

        let commits = try await GitHistory.commits(for: file, using: repo.git)
        #expect(try await GitHistory.contents(of: commits[1], using: repo.git) == "# First")
        #expect(try await GitHistory.contents(of: commits[0], using: repo.git) == "# Second")
    }
}

// MARK: - Feeding the split view

@Suite("Git history in the split view", .enabled(if: gitIsInstalled))
struct GitHistoryPreparationTests {

    @Test func aChangeBecomesASideBySideDocument() async throws {
        let repo = try HistoryRepo()
        try await repo.start()
        let file = try await repo.commit("note.md", "# One\nkeep\nold\n", message: "Add")
        try await repo.commit("note.md", "# One\nkeep\nnew\n", message: "Replace a line")

        let commits = try await GitHistory.commits(for: file, using: repo.git)
        let change = try await GitHistory.change(at: commits[0], using: repo.git)
        let state = await DiffPreparation.prepare(change: change)

        guard case let .loaded(loaded) = state else {
            Issue.record("expected a prepared document, got \(state)")
            return
        }
        // Left is the parent, right is the commit — the whole point of the view.
        #expect(loaded.document.leftLines.contains("old"))
        #expect(loaded.document.rightLines.contains("new"))
        #expect(!loaded.document.leftLines.contains("new"))
        #expect(loaded.notice == nil)
        #expect(loaded.degradedReason == nil)
    }

    @Test func theAddingCommitShowsTheWholeFileAsNew() async throws {
        let repo = try HistoryRepo()
        try await repo.start()
        let file = try await repo.commit("note.md", "# One\ntwo\n", message: "Add the note")

        let commits = try await GitHistory.commits(for: file, using: repo.git)
        let change = try await GitHistory.change(at: commits[0], using: repo.git)
        let state = await DiffPreparation.prepare(change: change)

        guard case let .loaded(loaded) = state else {
            Issue.record("expected a prepared document, got \(state)")
            return
        }
        #expect(loaded.document.rightLines == ["# One", "two"])
        #expect(loaded.notice == "This commit added the file.")
    }

    @Test func aDeletingCommitShowsWhatWasThere() async throws {
        let repo = try HistoryRepo()
        try await repo.start()
        try await repo.commit("note.md", "# One\ngoing\n", message: "Add the note")
        try await repo.delete("note.md", message: "Remove the note")

        let commits = try await GitHistory.commits(for: repo.url("note.md"), using: repo.git)
        let change = try await GitHistory.change(at: commits[0], using: repo.git)
        let state = await DiffPreparation.prepare(change: change)

        guard case let .loaded(loaded) = state else {
            Issue.record("expected a prepared document, got \(state)")
            return
        }
        #expect(loaded.document.leftLines == ["# One", "going"])
        #expect(loaded.notice == "This commit deleted the file.")
    }
}

// MARK: - How a date is written

@Suite("Commit dates")
struct CommitDateTests {

    @Test func recentCommitsAreRelativeAndOldOnesAreDated() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let aYearAgo = now.addingTimeInterval(-365 * 24 * 60 * 60)

        let recent = CommitDate.when(threeDaysAgo, now: now)
        #expect(recent.contains("3"))
        #expect(!recent.contains("-"))

        // Past the window it becomes a date rather than an unreadable "52w ago".
        let old = CommitDate.when(aYearAgo, now: now)
        #expect(old.contains("-"))
        #expect(old == CommitDate.exact(aYearAgo))
    }

    @Test func theBoundaryIsAMonth() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let justInside = now.addingTimeInterval(-CommitDate.relativeWindow + 60)
        let justOutside = now.addingTimeInterval(-CommitDate.relativeWindow - 60)
        #expect(CommitDate.when(justInside, now: now) != CommitDate.exact(justInside))
        #expect(CommitDate.when(justOutside, now: now) == CommitDate.exact(justOutside))
    }
}

// MARK: - Who wrote it

@Suite("Co-authored commits", .enabled(if: gitIsInstalled))
struct CoAuthoredCommitTests {

    /// The distinction that matters in an assistant workflow: a commit the model made
    /// carries the trailer, and one made by hand does not.
    @Test func trailersAreReadOffTheLog() async throws {
        let repo = try HistoryRepo()
        try await repo.start()
        let file = try await repo.commit("note.md", "a\n", message: "Mine, by hand")
        try await repo.commit("note.md", "b\n",
                              message: "By the model\n\n"
                                  + "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>")
        try await repo.commit("note.md", "c\n",
                              message: "Two helpers\n\n"
                                  + "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>\n"
                                  + "Co-Authored-By: Someone Else <else@example.com>")

        let commits = try await GitHistory.commits(for: file, using: repo.git)
        #expect(commits.map(\.subject) == ["Two helpers", "By the model", "Mine, by hand"])
        #expect(commits[0].coAuthors.count == 2)
        #expect(commits[1].coAuthors == ["Claude Opus 5 <noreply@anthropic.com>"])
        #expect(commits[2].coAuthors.isEmpty)
        #expect(commits[2].isCoAuthored == false)
        // Everything else still parses with the extra field in the format.
        #expect(commits.allSatisfy { $0.path == "note.md" })
        #expect(commits.allSatisfy { $0.hash.count == 40 })
    }

    @Test func theBadgeShowsTheNameWithoutTheAddress() {
        func summary(_ coAuthors: [String]) -> GitCommitSummary {
            GitCommitSummary(hash: "h", shortHash: "h", author: "a", date: Date(),
                             subject: "s", path: "p", coAuthors: coAuthors)
        }
        #expect(summary(["Claude Opus 5 <noreply@anthropic.com>"]).coAuthorName
                == "Claude Opus 5")
        // A trailer with no address, and one with no name, both still say something.
        #expect(summary(["Someone"]).coAuthorName == "Someone")
        #expect(summary(["<only@example.com>"]).coAuthorName == "<only@example.com>")
        #expect(summary([]).coAuthorName == nil)
    }

    @Test func theFilterSplitsTheLogInTwo() {
        func summary(_ subject: String, _ coAuthors: [String]) -> GitCommitSummary {
            GitCommitSummary(hash: subject, shortHash: "h", author: "a", date: Date(),
                             subject: subject, path: "p", coAuthors: coAuthors)
        }
        let log = [summary("assisted", ["Claude <c@example.com>"]), summary("by hand", [])]

        #expect(log.filter(HistoryFilter.all.includes).count == 2)
        #expect(log.filter(HistoryFilter.coAuthored.includes).map(\.subject) == ["assisted"])
        #expect(log.filter(HistoryFilter.solo.includes).map(\.subject) == ["by hand"])
    }
}
