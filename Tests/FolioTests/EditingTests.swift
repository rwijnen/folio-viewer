import Foundation
import Testing

@testable import Folio

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let samples = repositoryRoot.appendingPathComponent("Samples")

private struct Scratch {
    let folder: URL
    let url: URL

    init(_ contents: String, named name: String = "note.md") throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }
    func contents() throws -> String { try String(contentsOf: url, encoding: .utf8) }
}

/// Folio writes to exactly one file, only when asked. These pin that down.
@Suite("Editing", .serialized)
@MainActor
struct EditingTests {

    private let never: @MainActor (String) -> Bool = { _ in
        Issue.record("should not have asked to overwrite")
        return false
    }

    @Test func typingMarksTheDocumentAsEdited() throws {
        let file = try Scratch("# Title\n\nOriginal.\n")
        defer { file.remove() }
        let state = AppState()
        state.open(at: file.url)
        let tab = try #require(state.active)

        #expect(!tab.isDirty)
        #expect(tab.isEditable)
        state.updateDraft("# Title\n\nEdited.\n", for: tab)
        #expect(tab.isDirty)
        #expect(state.canSave)

        // Typing must not touch the file.
        #expect(try file.contents() == "# Title\n\nOriginal.\n")
    }

    @Test func typingTheSameTextBackIsNotAChange() throws {
        let file = try Scratch("# Title\n")
        defer { file.remove() }
        let state = AppState()
        state.open(at: file.url)
        let tab = try #require(state.active)

        state.updateDraft("# Changed\n", for: tab)
        #expect(tab.isDirty)
        state.updateDraft("# Title\n", for: tab)
        #expect(!tab.isDirty)
    }

    @Test func savingWritesTheFileAndClearsTheMarker() throws {
        let file = try Scratch("# Title\n\nOriginal.\n")
        defer { file.remove() }
        let state = AppState()
        state.open(at: file.url)
        let tab = try #require(state.active)

        state.updateDraft("# Title\n\nEdited by hand.\n", for: tab)
        #expect(state.save(tab, confirmingOverwrite: never))

        #expect(try file.contents() == "# Title\n\nEdited by hand.\n")
        #expect(!tab.isDirty)
        #expect(tab.draftText == nil)
        #expect(state.statusMessage?.contains("Saved") == true)
    }

    @Test func savingRefreshesTheOutlineAndThePreview() throws {
        let file = try Scratch("# One\n\nBody.\n")
        defer { file.remove() }
        let state = AppState()
        state.open(at: file.url)
        let tab = try #require(state.active)
        #expect(tab.textDocument?.outline.count == 1)

        state.updateDraft("# One\n\n## Two\n\n### Three\n\nBody.\n", for: tab)
        #expect(state.save(tab, confirmingOverwrite: never))

        #expect(tab.textDocument?.outline.map(\.title) == ["One", "Two", "Three"])
        #expect(tab.textDocument?.bodyHTML.contains("Three") == true)
        #expect(tab.outlineLayout.rows.map(\.depth) == [0, 1, 2])
    }

    @Test func thePreviewShowsUnsavedEditsWhenYouSwitchToIt() throws {
        let file = try Scratch("# Title\n\nOriginal.\n")
        defer { file.remove() }
        let state = AppState()
        state.open(at: file.url)
        let tab = try #require(state.active)
        state.setReadingMode(.source)

        state.updateDraft("# Title\n\nA brand new sentence.\n", for: tab)
        state.setReadingMode(.rendered)

        #expect(tab.textDocument?.bodyHTML.contains("A brand new sentence") == true)
        // Still unsaved: the file has not been touched.
        #expect(tab.isDirty)
        #expect(try file.contents() == "# Title\n\nOriginal.\n")
    }

    @Test func revertingGoesBackToWhatIsOnDisk() throws {
        let file = try Scratch("# Title\n\nOriginal.\n")
        defer { file.remove() }
        let state = AppState()
        state.open(at: file.url)
        let tab = try #require(state.active)

        state.updateDraft("# Ruined\n", for: tab)
        let version = tab.editorVersion
        state.revertDraft(for: tab)

        #expect(!tab.isDirty)
        #expect(tab.currentText == "# Title\n\nOriginal.\n")
        // The editor is told to take its text from the document again.
        #expect(tab.editorVersion > version)
    }

    @Test func aFileChangedUnderneathIsNoticed() throws {
        let file = try Scratch("# Title\n")
        defer { file.remove() }
        let state = AppState()
        state.open(at: file.url)
        let tab = try #require(state.active)
        #expect(!state.fileChangedOnDisk(for: tab))

        state.updateDraft("# Mine\n", for: tab)
        // Someone else writes the file while we were editing.
        Thread.sleep(forTimeInterval: 1.2)
        try "# Theirs\n".write(to: file.url, atomically: true, encoding: .utf8)
        #expect(state.fileChangedOnDisk(for: tab))

        // Declining leaves their version alone.
        #expect(!state.save(tab, confirmingOverwrite: { _ in false }))
        #expect(try file.contents() == "# Theirs\n")
        #expect(tab.isDirty)

        // Agreeing writes ours.
        #expect(state.save(tab, confirmingOverwrite: { _ in true }))
        #expect(try file.contents() == "# Mine\n")
    }

    @Test func onlyMarkdownIsEditable() throws {
        let plain = try Scratch("just text\n", named: "notes.log")
        defer { plain.remove() }
        let state = AppState()
        state.open(at: plain.url)
        let tab = try #require(state.active)

        #expect(tab.content == .source)
        #expect(!tab.isEditable)
        state.updateDraft("something else\n", for: tab)
        #expect(!tab.isDirty)
        #expect(try plain.contents() == "just text\n")
    }

    @Test func diffsAreNeverWritable() {
        let state = AppState()
        state.open(at: samples.appendingPathComponent("example.diff"))
        #expect(state.active?.isEditable == false)
        #expect(!state.canSave)
        #expect(!state.saveActiveDocument(confirmingOverwrite: never))
    }

    @Test func savingKeepsTheFilesOriginalEncoding() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-latin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("latin.md")
        // Latin-1 that is not valid UTF-8, so the reader has to fall back.
        try "# Café\n".data(using: .isoLatin1)!.write(to: url)

        let state = AppState()
        state.open(at: url)
        let tab = try #require(state.active)
        #expect(tab.textDocument?.encoding == .isoLatin1)

        state.updateDraft("# Café au lait\n", for: tab)
        #expect(state.save(tab, confirmingOverwrite: never))

        let written = try Data(contentsOf: url)
        #expect(String(data: written, encoding: .isoLatin1) == "# Café au lait\n")
        // It was not silently converted.
        #expect(String(data: written, encoding: .utf8) == nil)
    }

    @Test func savingEverythingWritesEveryEditedDocument() throws {
        let first = try Scratch("# One\n", named: "one.md")
        let second = try Scratch("# Two\n", named: "two.md")
        defer { first.remove(); second.remove() }
        let state = AppState()
        state.open(at: first.url)
        state.open(at: second.url)

        state.updateDraft("# One edited\n", for: state.tabs[0])
        state.updateDraft("# Two edited\n", for: state.tabs[1])
        #expect(state.dirtyTabs.count == 2)

        #expect(state.saveAllDocuments(confirmingOverwrite: never) == 2)
        #expect(try first.contents() == "# One edited\n")
        #expect(try second.contents() == "# Two edited\n")
        #expect(state.dirtyTabs.isEmpty)
    }
}

/// Nothing may be lost silently.
@Suite("Unsaved changes", .serialized)
@MainActor
struct UnsavedChangesTests {

    private func editedState() throws -> (AppState, Scratch) {
        let file = try Scratch("# Title\n\nOriginal.\n")
        let state = AppState()
        state.open(at: file.url)
        state.updateDraft("# Title\n\nEdited.\n", for: state.tabs[0])
        return (state, file)
    }

    @Test func closingAnEditedTabCanBeCancelled() throws {
        let (state, file) = try editedState()
        defer { file.remove() }
        let closed = state.closeTabAskingToSave(state.tabs[0].id, decide: { _ in .cancel })
        #expect(!closed)
        #expect(state.tabs.count == 1)
        #expect(state.active?.isDirty == true)
    }

    @Test func closingCanSaveOrDiscard() throws {
        let (saving, savedFile) = try editedState()
        defer { savedFile.remove() }
        #expect(saving.closeTabAskingToSave(saving.tabs[0].id,
                                            decide: { _ in .save },
                                            confirmingOverwrite: { _ in true }))
        #expect(saving.tabs.isEmpty)
        #expect(try savedFile.contents() == "# Title\n\nEdited.\n")

        let (discarding, discardedFile) = try editedState()
        defer { discardedFile.remove() }
        #expect(discarding.closeTabAskingToSave(discarding.tabs[0].id, decide: { _ in .discard }))
        #expect(discarding.tabs.isEmpty)
        #expect(try discardedFile.contents() == "# Title\n\nOriginal.\n")
    }

    @Test func closingAnUntouchedTabAsksNothing() throws {
        let file = try Scratch("# Title\n")
        defer { file.remove() }
        let state = AppState()
        state.open(at: file.url)
        let closed = state.closeTabAskingToSave(state.tabs[0].id, decide: { _ in
            Issue.record("should not have asked about an unedited document")
            return .cancel
        })
        #expect(closed)
        #expect(state.tabs.isEmpty)
    }

    @Test func quittingWithEditsAsksAndCanBeCancelled() throws {
        let (state, file) = try editedState()
        defer { file.remove() }
        #expect(state.confirmQuitWithUnsavedChanges(decide: { _ in .cancel }) == .terminateCancel)
        #expect(state.confirmQuitWithUnsavedChanges(decide: { _ in .discard }) == .terminateNow)
        #expect(try file.contents() == "# Title\n\nOriginal.\n")

        #expect(state.confirmQuitWithUnsavedChanges(decide: { _ in .save }) == .terminateNow)
        #expect(try file.contents() == "# Title\n\nEdited.\n")
    }

    @Test func quittingWithNothingEditedJustQuits() throws {
        let file = try Scratch("# Title\n")
        defer { file.remove() }
        let state = AppState()
        state.open(at: file.url)
        #expect(state.confirmQuitWithUnsavedChanges(decide: { _ in
            Issue.record("should not have asked")
            return .cancel
        }) == .terminateNow)
    }

    @Test func reloadingAsksBeforeThrowingEditsAway() throws {
        let (state, file) = try editedState()
        defer { file.remove() }
        state.reloadTextDocument(confirmingDiscard: { _ in false })
        #expect(state.active?.isDirty == true)
        #expect(state.active?.currentText == "# Title\n\nEdited.\n")

        state.reloadTextDocument(confirmingDiscard: { _ in true })
        #expect(state.active?.isDirty == false)
        #expect(state.active?.currentText == "# Title\n\nOriginal.\n")
    }
}
