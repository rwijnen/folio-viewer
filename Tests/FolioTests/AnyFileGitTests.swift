import Foundation
import Testing

@testable import Folio

@MainActor
private final class Workspace {

    let root: URL
    let git: Git
    let state = AppState()

    static let isolated: [String: String] = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
    ]

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-anyfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git = Git(workingDirectory: root, environment: Workspace.isolated)
        state.gitEnvironment = Workspace.isolated
        state.reloadsChangedFilesAutomatically = false
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func start() async throws {
        try await git.require(["init", "--initial-branch=main"])
        try await git.require(["config", "user.name", "Folio Tests"])
        try await git.require(["config", "user.email", "tests@example.invalid"])
        try write("seed.md", "# Seed\n")
        try await commitAll("First")
    }

    @discardableResult
    func write(_ name: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
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

    func open(_ url: URL) async throws -> DocumentTab {
        state.open(at: url)
        let tab = try #require(state.active)
        await waitFor("git status for \(url.lastPathComponent)") { tab.git != nil }
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

private let sampleDiff = """
diff --git a/x.txt b/x.txt
--- a/x.txt
+++ b/x.txt
@@ -1 +1 @@
-old
+new
"""

private var gitIsInstalled: Bool {
    FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
}

/// Git used to be offered for Markdown only, so a new `.diff` or `.swift` could not be
/// committed from inside Folio at all. These pin the wider rule.
@Suite("Git for any open file", .enabled(if: gitIsInstalled))
@MainActor
struct AnyFileGitTests {

    private let never: @MainActor (String) -> Bool = { _ in
        Issue.record("should not have asked to overwrite")
        return false
    }

    @Test func aNewDiffFileCanBeCommitted() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let patch = try workspace.write("change.diff", sampleDiff)

        let tab = try await workspace.open(patch)
        #expect(tab.content == .diff)
        #expect(workspace.state.supportsVersionControl(tab))
        #expect(tab.git?.fileState == .untracked)
        #expect(workspace.state.canCommit(tab))

        let committed = await workspace.state.commit(tab, message: "Add the patch",
                                                     thenPush: false, confirmingOverwrite: never)
        #expect(committed)
        #expect(try await workspace.log() == ["Add the patch", "First"])
        let recorded = try await workspace.git.require(["show", "--name-only",
                                                        "--pretty=format:", "HEAD"])
        #expect(recorded.trimmingCharacters(in: .whitespacesAndNewlines) == "change.diff")
    }

    @Test func aPlainSourceFileCanBeCommittedToo() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let source = try workspace.write("Tool.swift", "let x = 1\n")

        let tab = try await workspace.open(source)
        #expect(tab.content == .source)
        #expect(workspace.state.canCommit(tab))
        #expect(await workspace.state.commit(tab, message: "Add the tool", thenPush: false,
                                             confirmingOverwrite: never))
        #expect(try await workspace.log().first == "Add the tool")
    }

    @Test func anEditedDiffFileIsSeenAsModified() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let patch = try workspace.write("change.diff", sampleDiff)
        try await workspace.commitAll("Add the patch")
        try workspace.write("change.diff", sampleDiff + "\n+another line\n")

        let tab = try await workspace.open(patch)
        #expect(tab.git?.fileState == .modified)
        #expect(workspace.state.canCommit(tab))
    }

    /// A diff tab holds no editable text, so the comparison has to read the file rather
    /// than the buffer — otherwise every line looks deleted.
    @Test func uncommittedChangesReadTheFileWhenThereIsNoEditor() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let source = try workspace.write("Tool.swift", "let committed = 1\n")
        try await workspace.commitAll("Add the tool")
        try workspace.write("Tool.swift", "let working = 2\n")

        let tab = try await workspace.open(source)
        #expect(workspace.state.hasWorkingChanges(tab))
        workspace.state.showWorkingChanges(for: tab)
        await workspace.waitFor("the comparison") { tab.loadedFile != nil }

        let loaded = try #require(tab.loadedFile)
        #expect(loaded.document.leftLines == ["let committed = 1"])
        #expect(loaded.document.rightLines == ["let working = 2"])
    }

    @Test func aCleanDiffFileHasNothingToCommit() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let patch = try workspace.write("change.diff", sampleDiff)
        try await workspace.commitAll("Add the patch")

        let tab = try await workspace.open(patch)
        #expect(tab.git?.fileState == .committed)
        #expect(!workspace.state.canCommit(tab))
    }

    /// The repository-wide view is built in memory. Its path is a folder, so there is
    /// nothing there to commit.
    @Test func theRepositoryViewItselfIsNotCommittable() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let seed = workspace.root.appendingPathComponent("seed.md")
        try workspace.write("seed.md", "# Edited\n")

        _ = try await workspace.open(seed)
        workspace.state.showRepositoryChanges()
        let tab = try #require(workspace.state.active)
        await workspace.waitFor("the files") { !tab.files.isEmpty }

        #expect(tab.isEphemeral)
        #expect(!workspace.state.supportsVersionControl(tab))
        #expect(!workspace.state.canCommit(tab))
    }

    @Test func historySaysWhyItIsNotThereForADiff() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let patch = try workspace.write("change.diff", sampleDiff)

        let tab = try await workspace.open(patch)
        workspace.state.setSidebarMode(.history, for: tab)
        #expect(tab.sidebarMode == .outline)
        #expect(workspace.state.statusMessage?.contains("not beside a diff") == true)
    }

    /// A source file was never editable either, so it gets history now as well.
    @Test func aSourceFileGetsHistory() async throws {
        let workspace = try Workspace()
        try await workspace.start()
        let source = try workspace.write("Tool.swift", "let x = 1\n")
        try await workspace.commitAll("Add the tool")

        let tab = try await workspace.open(source)
        workspace.state.setSidebarMode(.history, for: tab)
        await workspace.waitFor("the log") { tab.historyState == .loaded }
        #expect(tab.history.map(\.subject) == ["Add the tool"])
    }
}
