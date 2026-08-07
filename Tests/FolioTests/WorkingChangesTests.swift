import Foundation
import Testing

@testable import Folio

@MainActor
private final class Workspace {

    let root: URL
    let folder: URL
    let git: Git
    let state = AppState()

    static let isolated: [String: String] = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
    ]

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-working-\(UUID().uuidString)")
        folder = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        git = Git(workingDirectory: folder, environment: Workspace.isolated)
        state.gitEnvironment = Workspace.isolated
        // These tests write the file themselves; the watcher would race them.
        state.reloadsChangedFilesAutomatically = false
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func start() async throws {
        try await git.require(["init", "--initial-branch=main"])
        try await git.require(["config", "user.name", "Folio Tests"])
        try await git.require(["config", "user.email", "tests@example.invalid"])
    }

    @discardableResult
    func write(_ name: String, _ contents: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func commitAll(_ message: String) async throws {
        try await git.require(["add", "--all"])
        try await git.require(["commit", "--message", message])
    }

    func open(_ url: URL) async throws -> DocumentTab {
        state.open(at: url)
        let tab = try #require(state.active)
        await waitFor("git status") { tab.git != nil }
        return tab
    }

    func waitFor(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if !condition() { Issue.record("timed out waiting for \(what)") }
    }
}

private var gitIsInstalled: Bool {
    FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
}

@Suite("Uncommitted changes", .enabled(if: gitIsInstalled))
@MainActor
struct WorkingChangesTests {

    @Test func aCleanFileHasNothingToShow() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let file = try workspace.write("note.md", "# One\n")
        try await workspace.commitAll("First")

        let tab = try await workspace.open(file)
        #expect(!workspace.state.hasWorkingChanges(tab))
        workspace.state.showWorkingChanges(for: tab)
        #expect(tab.pane == .document)
        #expect(workspace.state.statusMessage?.contains("no uncommitted changes") == true)
    }

    @Test func anEditedFileShowsTheLastCommitAgainstWhatYouHave() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let file = try workspace.write("note.md", "# One\nkeep\ncommitted\n")
        try await workspace.commitAll("First")
        try workspace.write("note.md", "# One\nkeep\nworking copy\n")

        let tab = try await workspace.open(file)
        #expect(workspace.state.hasWorkingChanges(tab))
        workspace.state.showWorkingChanges(for: tab)
        await workspace.waitFor("the comparison") { tab.loadedFile != nil }

        #expect(tab.pane == .workingChanges)
        let loaded = try #require(tab.loadedFile)
        #expect(loaded.document.leftLines.contains("committed"))
        #expect(loaded.document.rightLines.contains("working copy"))
    }

    /// What this view counts must be what a commit would record. The pill on #6 counts
    /// the same thing from `git diff --numstat HEAD`, so the two should agree once that
    /// branch lands; this pins Folio's own side of it.
    @Test func theChangeCountsAreWhatACommitWouldRecord() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let file = try workspace.write("note.md", "one\ntwo\nthree\nfour\n")
        try await workspace.commitAll("First")
        try workspace.write("note.md", "one\nalpha\nbeta\nfour\n")

        let tab = try await workspace.open(file)
        let numstat = try await workspace.git.require(
            ["diff", "--numstat", "HEAD", "--", "note.md"])
        #expect(numstat.hasPrefix("2\t2\t"))

        workspace.state.showWorkingChanges(for: tab)
        await workspace.waitFor("the comparison") { tab.loadedFile != nil }
        let diff = try #require(tab.selectedEntry?.diff)
        #expect(diff.additions == 2)
        #expect(diff.deletions == 2)
    }

    /// A commit saves first, so the view must show the draft, not the file.
    @Test func unsavedEditsAreIncludedBecauseACommitWouldSaveThemFirst() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let file = try workspace.write("note.md", "# One\ncommitted\n")
        try await workspace.commitAll("First")

        let tab = try await workspace.open(file)
        #expect(!workspace.state.hasWorkingChanges(tab))
        workspace.state.updateDraft("# One\nstill in the editor\n", for: tab)
        #expect(workspace.state.hasWorkingChanges(tab))

        workspace.state.showWorkingChanges(for: tab)
        await workspace.waitFor("the comparison") { tab.loadedFile != nil }
        let loaded = try #require(tab.loadedFile)
        #expect(loaded.document.rightLines.contains("still in the editor"))
        #expect(loaded.document.leftLines.contains("committed"))
    }

    @Test func anUntrackedFileIsAllNew() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        try workspace.write("seed.md", "# Seed\n")
        try await workspace.commitAll("First")
        let fresh = try workspace.write("fresh.md", "# New\nall of it\n")

        let tab = try await workspace.open(fresh)
        #expect(tab.git?.fileState == .untracked)
        workspace.state.showWorkingChanges(for: tab)
        await workspace.waitFor("the comparison") { tab.loadedFile != nil }

        let loaded = try #require(tab.loadedFile)
        #expect(loaded.document.leftLines.isEmpty)
        #expect(loaded.document.rightLines == ["# New", "all of it"])
    }

    @Test func aRepositoryWithNoCommitsYetStillWorks() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        // Nothing committed at all, so `HEAD` does not resolve.
        let file = try workspace.write("note.md", "# The very first\n")

        let tab = try await workspace.open(file)
        workspace.state.showWorkingChanges(for: tab)
        await workspace.waitFor("the comparison") { tab.loadedFile != nil }
        let loaded = try #require(tab.loadedFile)
        #expect(loaded.document.leftLines.isEmpty)
        #expect(loaded.document.rightLines == ["# The very first"])
    }

    @Test func goingBackRestoresTheDocument() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let file = try workspace.write("note.md", "# One\n")
        try await workspace.commitAll("First")
        try workspace.write("note.md", "# Two\n")

        let tab = try await workspace.open(file)
        workspace.state.showWorkingChanges(for: tab)
        await workspace.waitFor("the comparison") { tab.loadedFile != nil }

        workspace.state.closeCommit(for: tab)
        #expect(tab.pane == .document)
        #expect(tab.loadedFile == nil)
    }

    @Test func committingFromTheViewLeavesNothingToShow() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let file = try workspace.write("note.md", "# One\n")
        try await workspace.commitAll("First")
        try workspace.write("note.md", "# Two\n")

        let tab = try await workspace.open(file)
        workspace.state.showWorkingChanges(for: tab)
        await workspace.waitFor("the comparison") { tab.loadedFile != nil }

        _ = await workspace.state.commit(tab, message: "Record it", thenPush: false,
                                         confirmingOverwrite: { _ in true })
        #expect(!workspace.state.hasWorkingChanges(tab))
    }

    @Test func aFileOutsideARepositoryOffersNothing() async throws {
        let workspace = try Workspace()
        // No `git init`.
        let file = try workspace.write("note.md", "# One\n")
        workspace.state.open(at: file)
        let tab = try #require(workspace.state.active)

        #expect(!workspace.state.hasWorkingChanges(tab))
        workspace.state.showWorkingChanges(for: tab)
        #expect(tab.pane == .document)
    }

    @Test func searchFollowsTheComparison() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let file = try workspace.write("note.md", "# One\ncommitted\n")
        try await workspace.commitAll("First")
        try workspace.write("note.md", "# One\nworking\n")

        let tab = try await workspace.open(file)
        #expect(workspace.state.searchesRenderedPage)
        workspace.state.showWorkingChanges(for: tab)
        await workspace.waitFor("the comparison") { tab.loadedFile != nil }
        #expect(!workspace.state.searchesRenderedPage)

        workspace.state.searchQuery = "working"
        workspace.state.recomputeMatches()
        #expect(!workspace.state.matches.isEmpty)
    }
}
