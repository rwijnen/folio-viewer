import Foundation
import Testing

@testable import Folio

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let samples = repositoryRoot.appendingPathComponent("Samples")

private func makeMarkdown() throws -> (folder: URL, url: URL) {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("folio-find-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("note.md")
    try "# Heading\n\nA needle in the text.\n".write(to: url, atomically: true, encoding: .utf8)
    return (folder, url)
}

/// ⌘F is a menu command, and a wrong `.disabled` predicate kills a keyboard shortcut
/// silently. These pin down what the menu asks.
@Suite("Find availability", .serialized)
@MainActor
struct FindAvailabilityTests {

    @Test func findIsUnavailableWithNothingOpen() {
        let state = AppState()
        #expect(!state.canFind)
        state.presentFind()
        #expect(!state.isFindPresented)
    }

    @Test func findIsAvailableForMarkdown() throws {
        let state = AppState()
        let (folder, url) = try makeMarkdown()
        defer { try? FileManager.default.removeItem(at: folder) }

        state.open(at: url)
        // The regression: `loadedFile` only ever holds a diff, so asking it here left
        // ⌘F disabled for every Markdown document.
        #expect(state.loadedFile == nil)
        #expect(state.textDocument != nil)
        #expect(state.canFind)

        state.presentFind()
        #expect(state.isFindPresented)
    }

    @Test func findIsAvailableForMarkdownSourceAndForPlainText() throws {
        let state = AppState()
        let (folder, url) = try makeMarkdown()
        defer { try? FileManager.default.removeItem(at: folder) }
        state.open(at: url)
        state.setReadingMode(.source)
        #expect(state.canFind)

        let plain = folder.appendingPathComponent("notes.log")
        try "just text\n".write(to: plain, atomically: true, encoding: .utf8)
        state.open(at: plain)
        #expect(state.content == .source)
        #expect(state.canFind)
    }

    @Test func findIsAvailableForDiffs() {
        let state = AppState()
        state.open(at: samples.appendingPathComponent("example.diff"))
        #expect(state.canFind)
    }

    @Test func pressingFindAgainAsksTheFieldForFocus() throws {
        let state = AppState()
        let (folder, url) = try makeMarkdown()
        defer { try? FileManager.default.removeItem(at: folder) }
        state.open(at: url)

        state.presentFind()
        let first = state.findFocusRequest
        // Already open: ⌘F should still put the caret back in the field.
        state.presentFind()
        #expect(state.findFocusRequest > first)
        #expect(state.isFindPresented)
    }

    @Test func dismissingClearsTheQueryAndTheHighlights() throws {
        let state = AppState()
        let (folder, url) = try makeMarkdown()
        defer { try? FileManager.default.removeItem(at: folder) }
        state.open(at: url)
        state.setReadingMode(.source)

        state.presentFind()
        state.searchQuery = "needle"
        state.recomputeMatches()
        #expect(!state.matches.isEmpty)

        state.dismissFind()
        #expect(!state.isFindPresented)
        #expect(state.searchQuery.isEmpty)
        #expect(state.matches.isEmpty)
    }

    @Test func steppingIsOfferedForBothKindsOfMatch() throws {
        let state = AppState()
        let (folder, url) = try makeMarkdown()
        defer { try? FileManager.default.removeItem(at: folder) }
        state.open(at: url)

        #expect(!state.canStepMatches)

        // Source mode counts matches natively.
        state.setReadingMode(.source)
        state.searchQuery = "needle"
        state.recomputeMatches()
        #expect(state.canStepMatches)

        // Rendered mode keeps its count in the page, which used to leave ⌘G disabled.
        state.setReadingMode(.rendered)
        #expect(state.matches.isEmpty)
        state.handleWebMessage(["type": "matches", "count": 3], for: state.active?.id)
        #expect(state.renderedMatchCount == 3)
        #expect(state.canStepMatches)
    }
}

/// The menus no longer carry `.disabled(...)`, because a disabled item swallows its
/// keyboard shortcut. Every action must therefore refuse politely on its own.
@Suite("Menu actions guard themselves", .serialized)
@MainActor
struct MenuActionGuardTests {

    private func scratchFile(_ name: String, _ contents: String) throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func everyActionIsSafeWithNothingOpen() {
        let state = AppState()
        // None of these should trap, and none should leave the app in a strange state.
        state.presentFind()
        state.advanceMatch(by: 1)
        state.advanceMatch(by: -1)
        state.dismissFind()
        state.reloadTextDocument()
        state.closeActiveTab()
        state.closeOtherTabs()
        state.selectAdjacentTab(offset: 1)
        state.selectAdjacentFile(offset: 1)
        state.setReadingMode(.source)
        state.expandAllFolds()
        state.collapseAllFolds()

        #expect(state.tabs.isEmpty)
        #expect(!state.isFindPresented)
        #expect(state.errorMessage == nil)
    }

    @Test func readingModeOnlyAppliesToMarkdown() throws {
        let state = AppState()
        let url = try scratchFile("notes.log", "plain text\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        state.open(at: url)
        #expect(state.content == .source)
        #expect(state.readingMode == .source)
        // ⌘1 on a plain text file must not pretend it can render it.
        state.setReadingMode(.rendered)
        #expect(state.readingMode == .source)
    }

    @Test func baseFolderIsADiffOnlyConcern() throws {
        let state = AppState()
        let url = try scratchFile("note.md", "# Title\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        state.open(at: url)
        // Nothing to do for Markdown; the important part is that it does not present a
        // file panel, which would block a test run.
        state.presentBaseFolderPanel()
        #expect(state.baseFolder == nil)
    }

    @Test func steppingMatchesWithNoneFoundDoesNothing() throws {
        let state = AppState()
        let url = try scratchFile("note.md", "# Title\n\nsome words\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        state.open(at: url)
        state.setReadingMode(.source)
        state.searchQuery = "absent"
        state.recomputeMatches()
        #expect(state.matches.isEmpty)

        state.advanceMatch(by: 1)
        #expect(state.currentMatchIndex == 0)
        #expect(state.renderedMatchIndex == -1)
    }
}
