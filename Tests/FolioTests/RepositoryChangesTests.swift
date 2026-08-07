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
            .appendingPathComponent("folio-repochanges-\(UUID().uuidString)")
        folder = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        git = Git(workingDirectory: folder, environment: Workspace.isolated)
        state.gitEnvironment = Workspace.isolated
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
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
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

    func waitFor(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) async {
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

// MARK: - Collecting the diff

@Suite("Working tree", .enabled(if: gitIsInstalled))
struct GitWorkingTreeTests {

    @Test func trackedAndUntrackedChangesArrivePFTogether() async throws {
        let workspace = try await MainActor.run { try Workspace() }
        try await workspace.start()
        try await MainActor.run {
            try workspace.write("tracked.md", "one\ntwo\n")
            try workspace.write("kept.md", "unchanged\n")
        }
        try await workspace.commitAll("First")
        try await MainActor.run {
            try workspace.write("tracked.md", "one\nchanged\n")
            try workspace.write("fresh.md", "brand new\n")
        }

        let changes = try await GitWorkingTree.uncommittedChanges(in: workspace.folder,
                                                                 using: workspace.git)
        let parsed = DiffParser.parse(text: changes.diffText)
        let paths = parsed.files.map(\.displayPath).sorted()
        // The edited file and the new one; the untouched one is absent.
        #expect(paths == ["fresh.md", "tracked.md"])
        #expect(parsed.files.first { $0.displayPath == "fresh.md" }?.kind == .added)
    }

    @Test func stagedWorkIsIncludedBecauseACommitWouldRecordIt() async throws {
        let workspace = try await MainActor.run { try Workspace() }
        try await workspace.start()
        try await MainActor.run { try workspace.write("note.md", "one\n") }
        try await workspace.commitAll("First")
        try await MainActor.run { try workspace.write("note.md", "one\nstaged\n") }
        try await workspace.git.require(["add", "--", "note.md"])
        try await MainActor.run { try workspace.write("note.md", "one\nstaged\nand more\n") }

        let changes = try await GitWorkingTree.uncommittedChanges(in: workspace.folder,
                                                                 using: workspace.git)
        #expect(changes.diffText.contains("+staged"))
        #expect(changes.diffText.contains("+and more"))
    }

    @Test func ignoredFilesAreLeftOut() async throws {
        let workspace = try await MainActor.run { try Workspace() }
        try await workspace.start()
        try await MainActor.run { try workspace.write(".gitignore", "drafts/\n") }
        try await workspace.commitAll("First")
        try await MainActor.run { try workspace.write("drafts/secret.md", "hidden\n") }

        let changes = try await GitWorkingTree.uncommittedChanges(in: workspace.folder,
                                                                 using: workspace.git)
        #expect(!changes.diffText.contains("secret.md"))
    }

    @Test func aCleanRepositoryProducesNothing() async throws {
        let workspace = try await MainActor.run { try Workspace() }
        try await workspace.start()
        try await MainActor.run { try workspace.write("note.md", "one\n") }
        try await workspace.commitAll("First")

        let changes = try await GitWorkingTree.uncommittedChanges(in: workspace.folder,
                                                                 using: workspace.git)
        #expect(changes.isEmpty)
        #expect(changes.omittedUntracked == 0)
    }

    @Test func newFilesInsideNewFoldersAreListedIndividually() async throws {
        let workspace = try await MainActor.run { try Workspace() }
        try await workspace.start()
        try await MainActor.run { try workspace.write("seed.md", "one\n") }
        try await workspace.commitAll("First")
        // Without --untracked-files=all, git reports the folder and the diff cannot use it.
        try await MainActor.run {
            try workspace.write("notes/a.md", "alpha\n")
            try workspace.write("notes/b.md", "beta\n")
        }

        let changes = try await GitWorkingTree.uncommittedChanges(in: workspace.folder,
                                                                 using: workspace.git)
        let paths = DiffParser.parse(text: changes.diffText).files.map(\.displayPath).sorted()
        #expect(paths == ["notes/a.md", "notes/b.md"])
    }
}

// MARK: - The tab

@Suite("Repository changes", .enabled(if: gitIsInstalled))
@MainActor
struct RepositoryChangesTests {

    @Test func theViewOpensWithEveryChangedFile() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let note = try workspace.write("note.md", "one\ntwo\n")
        try workspace.write("other.md", "alpha\n")
        try await workspace.commitAll("First")
        try workspace.write("note.md", "one\nedited\n")
        try workspace.write("other.md", "alpha\nedited too\n")
        try workspace.write("fresh.md", "brand new\n")

        _ = try await workspace.open(note)
        workspace.state.showRepositoryChanges()
        let tab = try #require(workspace.state.active)
        await workspace.waitFor("the files") { !tab.files.isEmpty }

        #expect(tab.isEphemeral)
        #expect(tab.content == .diff)
        #expect(tab.name.contains("uncommitted"))
        #expect(Set(tab.files.map(\.diff.displayPath))
                == ["note.md", "other.md", "fresh.md"])
    }

    /// The left side must be the committed version. On disk is already the new one, and
    /// reading it there would show every file as unchanged.
    @Test func theLeftSideComesFromTheLastCommit() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let note = try workspace.write("note.md", "one\ncommitted\n")
        try await workspace.commitAll("First")
        try workspace.write("note.md", "one\nworking\n")

        _ = try await workspace.open(note)
        workspace.state.showRepositoryChanges()
        let tab = try #require(workspace.state.active)
        await workspace.waitFor("the prepared file") { tab.loadedFile != nil }

        let loaded = try #require(tab.loadedFile)
        #expect(loaded.document.leftLines.contains("committed"))
        #expect(loaded.document.rightLines.contains("working"))
        // Not reconstructed by reversing a patch — the committed text was read directly.
        #expect(!loaded.leftIsReconstructed)
        #expect(loaded.notice == nil)
        #expect(loaded.degradedReason == nil)
    }

    @Test func aNewFileShowsAsWhollyAdded() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let seed = try workspace.write("seed.md", "one\n")
        try await workspace.commitAll("First")
        try workspace.write("fresh.md", "brand new\nsecond line\n")

        _ = try await workspace.open(seed)
        workspace.state.showRepositoryChanges()
        let tab = try #require(workspace.state.active)
        await workspace.waitFor("the files") { !tab.files.isEmpty }
        let fresh = try #require(tab.files.first { $0.diff.displayPath == "fresh.md" })
        workspace.state.selectFile(fresh.id)
        await workspace.waitFor("the prepared file") { tab.loadedFile != nil }

        let loaded = try #require(tab.loadedFile)
        #expect(loaded.document.leftLines.isEmpty)
        #expect(loaded.document.rightLines == ["brand new", "second line"])
    }

    @Test func askingTwiceRefreshesRatherThanStacking() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let note = try workspace.write("note.md", "one\n")
        try await workspace.commitAll("First")
        try workspace.write("note.md", "two\n")

        _ = try await workspace.open(note)
        workspace.state.showRepositoryChanges()
        let tab = try #require(workspace.state.active)
        await workspace.waitFor("the files") { !tab.files.isEmpty }
        #expect(workspace.state.tabs.count == 2)

        // A second file changes, and the view is asked for again.
        try workspace.write("second.md", "new\n")
        workspace.state.showRepositoryChanges()
        await workspace.waitFor("the refreshed list") { tab.files.count == 2 }
        #expect(workspace.state.tabs.count == 2)
    }

    @Test func aCleanRepositorySaysSoRatherThanOpeningAnEmptyView() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let note = try workspace.write("note.md", "one\n")
        try await workspace.commitAll("First")

        _ = try await workspace.open(note)
        workspace.state.showRepositoryChanges()
        let tab = try #require(workspace.state.active)
        await workspace.waitFor("the empty result") {
            workspace.state.statusMessage?.contains("no uncommitted changes") == true
        }
        #expect(tab.files.isEmpty)
    }

    @Test func aDocumentOutsideARepositoryOffersNothing() async throws {
        let workspace = try Workspace()
        let note = try workspace.write("note.md", "one\n")
        workspace.state.open(at: note)

        workspace.state.showRepositoryChanges()
        #expect(workspace.state.statusMessage?.contains("not in a git repository") == true)
        #expect(workspace.state.tabs.count == 1)
    }

    /// It holds no file, so there is nothing to reopen it from.
    @Test func theViewIsLeftOutOfTheSavedSession() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let note = try workspace.write("note.md", "one\n")
        try await workspace.commitAll("First")
        try workspace.write("note.md", "two\n")

        _ = try await workspace.open(note)
        workspace.state.showRepositoryChanges()
        let tab = try #require(workspace.state.active)
        await workspace.waitFor("the files") { !tab.files.isEmpty }

        let session = workspace.state.session
        #expect(session.entries.count == 1)
        #expect(session.entries.first?.path.hasSuffix("note.md") == true)
    }
}
