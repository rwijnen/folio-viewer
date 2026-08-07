import Foundation
import Testing

@testable import Folio

/// A repository with a document in it, opened in an `AppState`.
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
            .appendingPathComponent("folio-histapp-\(UUID().uuidString)")
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
    func commit(_ name: String, _ contents: String, message: String) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try await git.require(["add", "--", name])
        try await git.require(["commit", "--message", message])
        return url
    }

    func open(_ url: URL) async throws -> DocumentTab {
        state.open(at: url)
        let tab = try #require(state.active)
        await waitFor("git status") { tab.git != nil }
        return tab
    }

    /// Background work has to be waited for; Swift Testing's executor runs the pending
    /// task while this sleeps.
    func waitFor(_ what: String, timeout: TimeInterval = 20,
                 _ condition: () -> Bool) async {
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

@Suite("History in the app", .enabled(if: gitIsInstalled))
@MainActor
struct HistoryInAppTests {

    private let never: @MainActor (String) -> Bool = { _ in
        Issue.record("should not have asked to overwrite")
        return false
    }

    /// Sets up a document with three commits behind it and its history loaded.
    private func loaded() async throws -> (Workspace, DocumentTab) {
        let workspace = try Workspace()
        try await workspace.start()
        let file = try await workspace.commit("note.md", "# One\nkeep\n", message: "Add the note")
        try await workspace.commit("note.md", "# One\nkeep\nsecond\n", message: "Second change")
        try await workspace.commit("note.md", "# One\nkeep\nthird\n", message: "Third change")

        let tab = try await workspace.open(file)
        workspace.state.setSidebarMode(.history, for: tab)
        await workspace.waitFor("the log") { tab.historyState == .loaded }
        return (workspace, tab)
    }

    @Test func switchingToHistoryReadsTheLog() async throws {
        let (_, tab) = try await loaded()
        #expect(tab.sidebarMode == .history)
        #expect(tab.history.map(\.subject) == ["Third change", "Second change", "Add the note"])
    }

    @Test func aDocumentOutsideARepositoryHasNoHistoryToOffer() async throws {
        let workspace = try Workspace()
        // No `git init`.
        let file = workspace.folder.appendingPathComponent("note.md")
        try "# One\n".write(to: file, atomically: true, encoding: .utf8)
        workspace.state.open(at: file)
        let tab = try #require(workspace.state.active)

        workspace.state.setSidebarMode(.history, for: tab)
        // The mode may flip, but nothing is read and nothing is claimed to exist.
        #expect(tab.history.isEmpty)
        #expect(tab.historyState == .idle)
    }

    @Test func choosingACommitShowsItSideBySide() async throws {
        let (workspace, tab) = try await loaded()
        let third = tab.history[0]

        workspace.state.showCommit(third, for: tab)
        await workspace.waitFor("the commit diff") { tab.loadedFile != nil }

        #expect(tab.viewingCommit?.hash == third.hash)
        let loaded = try #require(tab.loadedFile)
        #expect(loaded.document.leftLines.contains("second"))
        #expect(loaded.document.rightLines.contains("third"))
        // The split view finds its file the same way an opened patch does.
        #expect(tab.selectedEntry != nil)
    }

    @Test func goingBackRestoresTheDocument() async throws {
        let (workspace, tab) = try await loaded()
        workspace.state.showCommit(tab.history[0], for: tab)
        await workspace.waitFor("the commit diff") { tab.loadedFile != nil }

        workspace.state.closeCommit(for: tab)
        #expect(tab.viewingCommit == nil)
        #expect(tab.loadedFile == nil)
        #expect(tab.files.isEmpty)
        // The document itself was never disturbed.
        #expect(tab.textDocument?.rawText == "# One\nkeep\nthird\n")
    }

    @Test func steppingMovesThroughTheListAndStopsAtTheEnds() async throws {
        let (workspace, tab) = try await loaded()
        workspace.state.showCommit(tab.history[0], for: tab)
        await workspace.waitFor("the first diff") { tab.loadedFile != nil }

        workspace.state.stepThroughHistory(by: 1)
        #expect(tab.viewingCommit?.subject == "Second change")
        workspace.state.stepThroughHistory(by: 1)
        #expect(tab.viewingCommit?.subject == "Add the note")
        // Past the oldest, nothing happens rather than something wrong.
        workspace.state.stepThroughHistory(by: 1)
        #expect(tab.viewingCommit?.subject == "Add the note")

        workspace.state.stepThroughHistory(by: -1)
        #expect(tab.viewingCommit?.subject == "Second change")
    }

    /// ⌘F means the diff while a commit is showing, not the rendered page underneath.
    @Test func findSearchesWhatThePaneIsShowing() async throws {
        let (workspace, tab) = try await loaded()
        #expect(tab.readingMode == .rendered)
        #expect(workspace.state.searchesRenderedPage)

        workspace.state.showCommit(tab.history[0], for: tab)
        await workspace.waitFor("the commit diff") { tab.loadedFile != nil }
        #expect(!workspace.state.searchesRenderedPage)

        workspace.state.searchQuery = "third"
        workspace.state.recomputeMatches()
        #expect(!workspace.state.matches.isEmpty)

        workspace.state.closeCommit(for: tab)
        #expect(workspace.state.searchesRenderedPage)
        #expect(workspace.state.matches.isEmpty)
    }

    @Test func committingAddsToAHistoryAlreadyOnScreen() async throws {
        let (workspace, tab) = try await loaded()
        #expect(tab.history.count == 3)

        workspace.state.updateDraft("# One\nkeep\nfourth\n", for: tab)
        _ = await workspace.state.commit(tab, message: "Fourth change", thenPush: false,
                                         confirmingOverwrite: never)
        await workspace.waitFor("the refreshed log") { tab.history.count == 4 }
        #expect(tab.history.first?.subject == "Fourth change")
    }

    @Test func reloadingFromDiskPutsThePaneBackOnTheDocument() async throws {
        let (workspace, tab) = try await loaded()
        workspace.state.showCommit(tab.history[0], for: tab)
        await workspace.waitFor("the commit diff") { tab.loadedFile != nil }

        workspace.state.reloadTextDocument(for: tab.id)
        #expect(tab.viewingCommit == nil)
    }

    @Test func aCommitThatCannotBeReadIsReportedRatherThanBlank() async throws {
        let (workspace, tab) = try await loaded()
        var broken = tab.history[0]
        broken.hash = "0000000000000000000000000000000000000000"
        broken.shortHash = "0000000"

        workspace.state.showCommit(broken, for: tab)
        await workspace.waitFor("the failure") {
            if case .failed = tab.loadState { return true }
            return false
        }
        guard case let .failed(message) = tab.loadState else {
            Issue.record("expected a failure")
            return
        }
        #expect(!message.isEmpty)
    }
}
