import Foundation
import Testing

@testable import Folio

// MARK: - Harness

/// A repository with one Markdown document in it, plus an `AppState` pointed at it.
///
/// git runs sealed off from the developer's own configuration for the same reason as in
/// `GitTests`: a global signing key or hook would otherwise decide whether these pass.
@MainActor
private final class Workspace {

    let root: URL
    let folder: URL
    let git: Git
    let state = AppState()

    init(named name: String = "work") throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-gitapp-\(UUID().uuidString)")
        folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        git = Git(workingDirectory: folder, environment: Workspace.isolated)
        state.gitEnvironment = Workspace.isolated
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    static let isolated: [String: String] = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
    ]

    func initialise(identity: Bool = true) async throws {
        try await git.require(["init", "--initial-branch=main"])
        if identity {
            try await git.require(["config", "user.name", "Folio Tests"])
            try await git.require(["config", "user.email", "tests@example.invalid"])
        }
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

    func log() async throws -> [String] {
        let text = try await git.require(["log", "--pretty=format:%s"])
        return text.isEmpty ? [] : text.split(separator: "\n").map(String.init)
    }

    /// Opens a document and waits for the background status refresh to land.
    func open(_ url: URL) async throws -> DocumentTab {
        state.open(at: url)
        let tab = try #require(state.active)
        _ = await waitForGitStatus(tab)
        return tab
    }

    /// The refresh runs in a detached task, so tests have to wait for it. Returns nil if
    /// it never arrives, which is how "this file is not in a repository" reads too.
    @discardableResult
    func waitForGitStatus(_ tab: DocumentTab, timeout: TimeInterval = 15) async -> GitSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = tab.git { return snapshot }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return tab.git
    }

    /// Waits for git to stop working, after a commit or a push.
    func waitUntilIdle(_ tab: DocumentTab, timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, tab.gitActivity != nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private var gitIsInstalled: Bool {
    FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
}

// MARK: - Status in the interface

@Suite("Git in the app", .enabled(if: gitIsInstalled))
@MainActor
struct GitIntegrationTests {

    private let never: @MainActor (String) -> Bool = { _ in
        Issue.record("should not have asked to overwrite")
        return false
    }

    @Test func openingADocumentInARepositoryReadsItsStatus() async throws {
        let workspace = try Workspace()
        try await workspace.initialise()
        let file = try workspace.write("note.md", "# One\n")
        try await workspace.commitAll("First")

        let tab = try await workspace.open(file)
        let snapshot = try #require(tab.git)
        #expect(snapshot.branch == "main")
        #expect(snapshot.fileState == .committed)
        #expect(!workspace.state.canCommitActiveDocument)
        #expect(!workspace.state.canPushActiveDocument)
    }

    @Test func aDocumentOutsideARepositoryOffersNothing() async throws {
        let workspace = try Workspace()
        // No `git init` at all.
        let file = try workspace.write("note.md", "# One\n")

        let tab = try await workspace.open(file)
        #expect(tab.git == nil)
        #expect(!workspace.state.canCommitActiveDocument)

        // The sheet must not open with nothing behind it.
        workspace.state.presentCommitSheet()
        #expect(!workspace.state.isCommitSheetPresented)
    }

    @Test func typingMakesTheDocumentCommittable() async throws {
        let workspace = try Workspace()
        try await workspace.initialise()
        let file = try workspace.write("note.md", "# One\n")
        try await workspace.commitAll("First")

        let tab = try await workspace.open(file)
        #expect(!workspace.state.canCommitActiveDocument)
        // Unsaved edits count: the save runs first and turns them into a change.
        workspace.state.updateDraft("# One\n\nEdited.\n", for: tab)
        #expect(workspace.state.canCommitActiveDocument)
    }

    /// An unsaved edit makes a clean file committable, but it must not talk git into a
    /// commit that cannot work.
    @Test func anUnsavedEditCannotOverrideARealBlocker() async throws {
        let workspace = try Workspace()
        try await workspace.initialise()
        try workspace.write(".gitignore", "drafts.md\n")
        try await workspace.commitAll("First")
        let ignored = try workspace.write("drafts.md", "# Draft\n")

        let tab = try await workspace.open(ignored)
        #expect(tab.git?.fileState == .ignored)
        workspace.state.updateDraft("# Draft, edited\n", for: tab)
        #expect(tab.isDirty)
        #expect(!workspace.state.canCommitActiveDocument)
    }

    @Test func theMessageDoesNotCarryOverToTheNextCommit() async throws {
        let workspace = try Workspace()
        try await workspace.initialise()
        let file = try workspace.write("note.md", "# One\n")
        try await workspace.commitAll("First")

        let tab = try await workspace.open(file)
        workspace.state.updateDraft("# Edited\n", for: tab)
        workspace.state.presentCommitSheet()
        #expect(workspace.state.commitMessage == "Update note.md")

        _ = await workspace.state.commit(tab, message: "A very specific message",
                                         thenPush: false, confirmingOverwrite: never)
        // The next sheet must not open holding the last change's message.
        #expect(workspace.state.commitMessage.isEmpty)
        workspace.state.updateDraft("# Edited again\n", for: tab)
        workspace.state.presentCommitSheet()
        #expect(workspace.state.commitMessage == "Update note.md")
    }

    @Test func theSuggestedMessageMatchesWhatWillHappen() async throws {
        let workspace = try Workspace()
        try await workspace.initialise()
        try workspace.write("seed.md", "# Seed\n")
        try await workspace.commitAll("First")
        let fresh = try workspace.write("fresh.md", "# New\n")

        let tab = try await workspace.open(fresh)
        #expect(tab.git?.fileState == .untracked)
        #expect(workspace.state.suggestedCommitMessage(for: tab) == "Add fresh.md")

        try await workspace.commitAll("Add it by hand")
        workspace.state.refreshGitStatus(for: tab)
        tab.git = nil
        await workspace.waitForGitStatus(tab)
        #expect(workspace.state.suggestedCommitMessage(for: tab) == "Update fresh.md")
    }
}

// MARK: - Committing from the app

@Suite("Git commit from the app", .enabled(if: gitIsInstalled))
@MainActor
struct GitCommitFromAppTests {

    private let never: @MainActor (String) -> Bool = { _ in
        Issue.record("should not have asked to overwrite")
        return false
    }

    @Test func committingSavesTheEditorFirst() async throws {
        let workspace = try Workspace()
        try await workspace.initialise()
        let file = try workspace.write("note.md", "# One\n")
        try await workspace.commitAll("First")

        let tab = try await workspace.open(file)
        workspace.state.updateDraft("# One\n\nEdited in Folio.\n", for: tab)
        #expect(tab.isDirty)

        let committed = await workspace.state.commit(tab, message: "Edit from Folio",
                                                     thenPush: false, confirmingOverwrite: never)
        #expect(committed)
        #expect(!tab.isDirty)
        // Both the file and the commit hold the edited text — not the version that was
        // on disk when the commit was asked for.
        #expect(try String(contentsOf: file, encoding: .utf8) == "# One\n\nEdited in Folio.\n")
        let recorded = try await workspace.git.require(["show", "HEAD:note.md"])
        #expect(recorded.contains("Edited in Folio."))
        #expect(try await workspace.log() == ["Edit from Folio", "First"])
    }

    @Test func cancellingTheOverwritePromptCancelsTheCommitToo() async throws {
        let workspace = try Workspace()
        try await workspace.initialise()
        let file = try workspace.write("note.md", "# One\n")
        try await workspace.commitAll("First")

        let tab = try await workspace.open(file)
        workspace.state.updateDraft("# Mine\n", for: tab)
        // Someone else changes the file underneath, so saving will ask.
        try workspace.write("note.md", "# Theirs\n")

        let committed = await workspace.state.commit(tab, message: "Should not happen",
                                                     thenPush: false,
                                                     confirmingOverwrite: { _ in false })
        #expect(!committed)
        #expect(try await workspace.log() == ["First"])
        // Their version is still on disk and the edit is still in the editor.
        #expect(try String(contentsOf: file, encoding: .utf8) == "# Theirs\n")
        #expect(tab.isDirty)
    }

    @Test func aFailedCommitIsReportedAndChangesNothing() async throws {
        let workspace = try Workspace()
        try await workspace.initialise(identity: false)
        try await workspace.git.require(["config", "user.useConfigOnly", "true"])
        let file = try workspace.write("note.md", "# One\n")

        let tab = try await workspace.open(file)
        let committed = await workspace.state.commit(tab, message: "No identity",
                                                     thenPush: false, confirmingOverwrite: never)
        #expect(!committed)
        #expect(workspace.state.errorMessage?.contains("note.md") == true)
        #expect(tab.gitActivity == nil)
    }

    @Test func committingLeavesOtherWorkAlone() async throws {
        let workspace = try Workspace()
        try await workspace.initialise()
        let mine = try workspace.write("mine.md", "# Mine\n")
        try workspace.write("theirs.md", "# Theirs\n")
        try await workspace.commitAll("First")
        try workspace.write("theirs.md", "# Theirs, edited elsewhere\n")

        let tab = try await workspace.open(mine)
        workspace.state.updateDraft("# Mine, edited\n", for: tab)
        _ = await workspace.state.commit(tab, message: "Only mine", thenPush: false,
                                         confirmingOverwrite: never)

        let touched = try await workspace.git.require(["show", "--name-only",
                                                       "--pretty=format:", "HEAD"])
        #expect(touched.trimmingCharacters(in: .whitespacesAndNewlines) == "mine.md")
        let theirs = await GitRepository.fileState(of: workspace.folder
            .appendingPathComponent("theirs.md"), using: workspace.git)
        #expect(theirs == .modified)
    }

    @Test func askingToPushWithNoRemoteStillCommits() async throws {
        let workspace = try Workspace()
        try await workspace.initialise()
        let file = try workspace.write("note.md", "# One\n")
        try await workspace.commitAll("First")

        let tab = try await workspace.open(file)
        workspace.state.updateDraft("# Edited\n", for: tab)
        let committed = await workspace.state.commit(tab, message: "Local only",
                                                     thenPush: true, confirmingOverwrite: never)
        #expect(committed)
        #expect(try await workspace.log() == ["Local only", "First"])
        #expect(workspace.state.statusMessage?.contains("nothing was pushed") == true)
        #expect(workspace.state.errorMessage == nil)
    }

    @Test func theStatusPillCatchesUpAfterACommit() async throws {
        let workspace = try Workspace()
        try await workspace.initialise()
        let file = try workspace.write("note.md", "# One\n")
        try await workspace.commitAll("First")

        let tab = try await workspace.open(file)
        workspace.state.updateDraft("# Edited\n", for: tab)
        _ = await workspace.state.commit(tab, message: "Edited", thenPush: false,
                                         confirmingOverwrite: never)
        #expect(tab.git?.fileState == .committed)
        #expect(!workspace.state.canCommitActiveDocument)
    }
}

// MARK: - Pushing from the app

@Suite("Git push from the app", .enabled(if: gitIsInstalled))
@MainActor
struct GitPushFromAppTests {

    private let never: @MainActor (String) -> Bool = { _ in
        Issue.record("should not have asked to overwrite")
        return false
    }

    /// Sets up `work` as a clone of a bare repository next to it, so a push is a real
    /// push with no network involved.
    private func workspaceWithRemote() async throws -> (Workspace, Git) {
        let workspace = try Workspace()
        let remote = workspace.root.appendingPathComponent("origin.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let remoteGit = Git(workingDirectory: remote, environment: Workspace.isolated)
        try await remoteGit.require(["init", "--bare", "--initial-branch=main"])

        try await workspace.initialise()
        try workspace.write("note.md", "# One\n")
        try await workspace.commitAll("First")
        try await workspace.git.require(["remote", "add", "origin", remote.path])
        try await workspace.git.require(["push", "-u", "origin", "main"])
        return (workspace, remoteGit)
    }

    @Test func commitAndPushSendsItToTheRemote() async throws {
        let (workspace, remote) = try await workspaceWithRemote()
        let file = workspace.folder.appendingPathComponent("note.md")

        let tab = try await workspace.open(file)
        #expect(tab.git?.upstream == "origin/main")

        workspace.state.updateDraft("# One\n\nEdited in Folio.\n", for: tab)
        let done = await workspace.state.commit(tab, message: "Edit and send",
                                                thenPush: true, confirmingOverwrite: never)
        #expect(done)
        await workspace.waitUntilIdle(tab)

        let remoteLog = try await remote.require(["log", "--pretty=format:%s", "main"])
        #expect(remoteLog.split(separator: "\n").first.map(String.init) == "Edit and send")
        #expect(workspace.state.errorMessage == nil)
    }

    @Test func aRejectedPushKeepsTheCommitAndSaysSo() async throws {
        let (workspace, remote) = try await workspaceWithRemote()
        let file = workspace.folder.appendingPathComponent("note.md")

        // Someone else moves the remote on, so our push cannot fast-forward.
        let other = workspace.root.appendingPathComponent("other")
        let otherGit = Git(workingDirectory: other, environment: Workspace.isolated)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await Git(workingDirectory: workspace.root, environment: Workspace.isolated)
            .require(["clone", remote.workingDirectory.path, other.path])
        try await otherGit.require(["config", "user.name", "Someone Else"])
        try await otherGit.require(["config", "user.email", "else@example.invalid"])
        try "# Theirs\n".write(to: other.appendingPathComponent("note.md"),
                               atomically: true, encoding: .utf8)
        try await otherGit.require(["commit", "--all", "--message", "From someone else"])
        try await otherGit.require(["push", "origin", "main"])

        let tab = try await workspace.open(file)
        workspace.state.updateDraft("# Mine\n", for: tab)
        let done = await workspace.state.commit(tab, message: "Mine", thenPush: true,
                                                confirmingOverwrite: never)
        #expect(!done)
        await workspace.waitUntilIdle(tab)

        // The commit survived; only the push failed, and the message says both.
        #expect(try await workspace.log().first == "Mine")
        let reported = try #require(workspace.state.errorMessage)
        #expect(reported.contains("Committed"))
        #expect(reported.contains("push failed"))
        // Nothing was forced over the other person's work.
        let remoteLog = try await remote.require(["log", "--pretty=format:%s", "main"])
        #expect(remoteLog.split(separator: "\n").first.map(String.init) == "From someone else")
    }

    @Test func pushingOnItsOwnClearsTheAheadCount() async throws {
        let (workspace, remote) = try await workspaceWithRemote()
        let file = workspace.folder.appendingPathComponent("note.md")
        try workspace.write("note.md", "# Committed elsewhere\n")
        try await workspace.commitAll("Made in a terminal")

        let tab = try await workspace.open(file)
        #expect(tab.git?.ahead == 1)
        #expect(workspace.state.canPushActiveDocument)

        workspace.state.pushActiveDocument()
        await workspace.waitUntilIdle(tab)
        // The refresh after a push is a background task of its own.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, tab.git?.ahead != 0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(tab.git?.ahead == 0)
        #expect(!workspace.state.canPushActiveDocument)
        let remoteLog = try await remote.require(["log", "--pretty=format:%s", "main"])
        #expect(remoteLog.split(separator: "\n").first.map(String.init) == "Made in a terminal")
    }
}
