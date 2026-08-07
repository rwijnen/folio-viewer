import Foundation
import Testing

@testable import Folio

@MainActor
private final class Scratch {
    let folder: URL
    let url: URL
    let state = AppState()

    init(_ contents: String = "# One\nkeep\n") throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-external-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("note.md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func open() throws -> DocumentTab {
        state.open(at: url)
        return try #require(state.active)
    }

    /// How almost everything writes, Folio included.
    func writeFromElsewhere(_ contents: String) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    func contents() throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func waitFor(_ what: String, timeout: TimeInterval = 8, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if !condition() { Issue.record("timed out waiting for \(what)") }
    }
}

/// Deciding what to do when something else writes the file. The watcher itself is tested
/// separately; these drive the decision directly so they are not timing-dependent.
@Suite("External changes")
@MainActor
struct ExternalChangesTests {

    @Test func aCleanDocumentIsBroughtUpToDate() throws {
        let scratch = try Scratch()
        let tab = try scratch.open()
        scratch.state.reloadsChangedFilesAutomatically = true

        try scratch.writeFromElsewhere("# One\nkeep\nfrom somewhere else\n")
        scratch.state.fileChangedOnDisk(tabID: tab.id)

        #expect(tab.externalChange == nil)
        #expect(tab.textDocument?.rawText == "# One\nkeep\nfrom somewhere else\n")
        #expect(scratch.state.statusMessage?.contains("changed on disk") == true)
    }

    @Test func withAutomaticReloadOffTheReaderIsAsked() throws {
        let scratch = try Scratch()
        let tab = try scratch.open()
        scratch.state.reloadsChangedFilesAutomatically = false

        try scratch.writeFromElsewhere("# Theirs\n")
        scratch.state.fileChangedOnDisk(tabID: tab.id)

        #expect(tab.externalChange == .changed("# Theirs\n"))
        // Nothing moved under them.
        #expect(tab.textDocument?.rawText == "# One\nkeep\n")
    }

    /// The rule that matters: unsaved work is never discarded on Folio's initiative.
    @Test func aDocumentBeingEditedIsNeverReloadedByItself() throws {
        let scratch = try Scratch()
        let tab = try scratch.open()
        scratch.state.reloadsChangedFilesAutomatically = true
        scratch.state.updateDraft("# Mine\n", for: tab)

        try scratch.writeFromElsewhere("# Theirs\n")
        scratch.state.fileChangedOnDisk(tabID: tab.id)

        #expect(tab.externalChange == .changed("# Theirs\n"))
        #expect(tab.isDirty)
        #expect(tab.currentText == "# Mine\n")
    }

    @Test func anIdenticalRewriteIsNotAChange() throws {
        let scratch = try Scratch()
        let tab = try scratch.open()

        // `touch`, or a tool writing the same bytes back. The watcher fires; nothing
        // should come of it.
        try scratch.writeFromElsewhere("# One\nkeep\n")
        scratch.state.fileChangedOnDisk(tabID: tab.id)
        #expect(tab.externalChange == nil)
        #expect(scratch.state.statusMessage == nil)
    }

    /// Folio's own saves trip the watcher too, and must not report themselves.
    @Test func savingDoesNotLookLikeSomeoneElseWriting() throws {
        let scratch = try Scratch()
        let tab = try scratch.open()
        scratch.state.updateDraft("# Saved by me\n", for: tab)
        #expect(scratch.state.save(tab, confirmingOverwrite: { _ in
            Issue.record("should not have asked")
            return false
        }))

        scratch.state.fileChangedOnDisk(tabID: tab.id)
        #expect(tab.externalChange == nil)
    }

    @Test func aDeletedFileIsReportedWithoutLosingTheText() throws {
        let scratch = try Scratch()
        let tab = try scratch.open()

        try FileManager.default.removeItem(at: scratch.url)
        scratch.state.fileChangedOnDisk(tabID: tab.id)

        #expect(tab.externalChange == .removed)
        #expect(tab.textDocument?.rawText == "# One\nkeep\n")
    }

    // MARK: - The three ways out

    @Test func seeingWhatChangedPutsBothVersionsSideBySide() async throws {
        let scratch = try Scratch()
        let tab = try scratch.open()
        scratch.state.updateDraft("# One\nkeep\nmine\n", for: tab)
        try scratch.writeFromElsewhere("# One\nkeep\ntheirs\n")
        scratch.state.fileChangedOnDisk(tabID: tab.id)

        scratch.state.showExternalDifference(for: tab)
        await scratch.waitFor("the comparison") { tab.loadedFile != nil }

        #expect(tab.pane == .externalChange)
        let loaded = try #require(tab.loadedFile)
        // Left is what the reader has, right is what arrived.
        #expect(loaded.document.leftLines.contains("mine"))
        #expect(loaded.document.rightLines.contains("theirs"))
        #expect(tab.selectedEntry != nil)
    }

    @Test func takingTheirsDiscardsTheDraft() throws {
        let scratch = try Scratch()
        let tab = try scratch.open()
        scratch.state.updateDraft("# Mine\n", for: tab)
        try scratch.writeFromElsewhere("# Theirs\n")
        scratch.state.fileChangedOnDisk(tabID: tab.id)

        scratch.state.acceptExternalChange(for: tab)
        #expect(tab.externalChange == nil)
        #expect(!tab.isDirty)
        #expect(tab.textDocument?.rawText == "# Theirs\n")
        #expect(tab.pane == .document)
    }

    @Test func keepingMineLeavesTheFileAloneUntilASaveIsAsked() throws {
        let scratch = try Scratch()
        let tab = try scratch.open()
        scratch.state.updateDraft("# Mine\n", for: tab)
        try scratch.writeFromElsewhere("# Theirs\n")
        scratch.state.fileChangedOnDisk(tabID: tab.id)

        scratch.state.dismissExternalChange(for: tab)
        #expect(tab.externalChange == nil)
        #expect(tab.isDirty)
        // Their version is still the one on disk — dismissing is not saving.
        #expect(try scratch.contents() == "# Theirs\n")

        // And saving still asks, because the file really did change underneath.
        var asked = false
        #expect(scratch.state.save(tab, confirmingOverwrite: { _ in asked = true; return true }))
        #expect(asked)
        #expect(try scratch.contents() == "# Mine\n")
    }

    @Test func searchFollowsTheComparisonWhileItIsShowing() async throws {
        let scratch = try Scratch()
        let tab = try scratch.open()
        scratch.state.updateDraft("# One\nkeep\nmine\n", for: tab)
        try scratch.writeFromElsewhere("# One\nkeep\ntheirs\n")
        scratch.state.fileChangedOnDisk(tabID: tab.id)
        #expect(scratch.state.searchesRenderedPage)

        scratch.state.showExternalDifference(for: tab)
        await scratch.waitFor("the comparison") { tab.loadedFile != nil }
        #expect(!scratch.state.searchesRenderedPage)

        scratch.state.searchQuery = "theirs"
        scratch.state.recomputeMatches()
        #expect(!scratch.state.matches.isEmpty)
    }
}

/// One end-to-end pass through the real watcher, since everything above bypasses it.
@Suite("External changes, end to end", .serialized)
@MainActor
struct ExternalChangesLiveTests {

    @Test func writingTheFileFromOutsideReachesTheDocument() async throws {
        let scratch = try Scratch()
        let tab = try scratch.open()
        scratch.state.reloadsChangedFilesAutomatically = false
        // Opening starts the watcher; give the source a moment to arm.
        try await Task.sleep(nanoseconds: 200_000_000)

        try scratch.writeFromElsewhere("# Written by something else\n")
        await scratch.waitFor("the change to arrive") { tab.externalChange != nil }
        #expect(tab.externalChange == .changed("# Written by something else\n"))
    }

    @Test func closingATabStopsWatchingItsFile() async throws {
        let scratch = try Scratch()
        let tab = try scratch.open()
        try await Task.sleep(nanoseconds: 200_000_000)
        scratch.state.closeTab(tab.id)

        try scratch.writeFromElsewhere("# After closing\n")
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(tab.externalChange == nil)
    }
}
