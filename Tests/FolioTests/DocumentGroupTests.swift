import Foundation
import Testing

@testable import Folio

@Suite("Group names")
struct DocumentGroupNameTests {

    @Test func aDocumentIsNamedAfterTheFolderItIsIn() {
        #expect(DocumentGroup.automatic(for: URL(fileURLWithPath: "/Users/r/notes/one.md"))
                == "notes")
        #expect(DocumentGroup.automatic(for: URL(fileURLWithPath: "/Users/r/Work/Acme/plan.md"))
                == "Acme")
    }

    /// The repository-wide view's URL is a folder, not a file in one. Without this it
    /// would group under the repository's parent, away from every document it is about.
    @Test func aFolderGroupsUnderItsOwnName() {
        let repo = URL(fileURLWithPath: "/Users/r/Work/acme-docs", isDirectory: true)
        #expect(DocumentGroup.automatic(for: repo, isFolder: true) == "acme-docs")
        #expect(DocumentGroup.automatic(for: repo, isFolder: false) == "Work")
    }

    /// Rare, but it must produce *something* clickable rather than an empty menu row.
    @Test func aFileAtTheRootOfAVolumeStillHasAName() {
        #expect(DocumentGroup.automatic(for: URL(fileURLWithPath: "/one.md")) == "/")
        #expect(!DocumentGroup.automatic(for: URL(fileURLWithPath: "/one.md")).isEmpty)
    }

    @Test func groupsAreListedAlphabeticallyAndOnce() {
        #expect(DocumentGroup.listed(from: ["notes", "acme", "notes", "Beta"])
                == ["acme", "Beta", "notes"])
        #expect(DocumentGroup.listed(from: []).isEmpty)
    }

    /// An empty name is how "put it back on automatic" is spelled.
    @Test func aBlankNameIsNoName() {
        #expect(DocumentGroup.sanitised("  Acme  ") == "Acme")
        #expect(DocumentGroup.sanitised("   ") == nil)
        #expect(DocumentGroup.sanitised("") == nil)
        #expect(DocumentGroup.sanitised("\n\t") == nil)
    }
}

@MainActor
private final class Scratch {
    let root: URL
    let state = AppState()

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-groups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Opens a document in a named folder, which is what decides its group.
    @discardableResult
    func open(_ folder: String, _ name: String) throws -> DocumentTab {
        let directory = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        state.open(at: url)
        return state.active!
    }
}

@Suite("Grouped tabs")
@MainActor
struct GroupedTabTests {

    @Test func documentsGroupByTheirFolder() throws {
        let scratch = try Scratch()
        try scratch.open("acme", "one.md")
        try scratch.open("acme", "two.md")
        try scratch.open("beta", "three.md")

        #expect(scratch.state.groups == ["acme", "beta"])
        #expect(scratch.state.documentCount(inGroup: "acme") == 2)
        #expect(scratch.state.documentCount(inGroup: "beta") == 1)
        // Nothing is filtered until a group is chosen.
        #expect(scratch.state.visibleTabs.count == 3)
    }

    @Test func choosingAGroupHidesTheRestWithoutClosingThem() throws {
        let scratch = try Scratch()
        try scratch.open("acme", "one.md")
        let beta = try scratch.open("beta", "three.md")
        scratch.state.updateDraft("# edited\n", for: beta)

        scratch.state.selectGroup("acme")
        #expect(scratch.state.visibleTabs.map(\.name) == ["one.md"])
        // Still open, still dirty, still remembered.
        #expect(scratch.state.tabs.count == 2)
        #expect(beta.isDirty)

        scratch.state.selectGroup(nil)
        #expect(scratch.state.visibleTabs.count == 2)
    }

    /// A window showing a document the tab bar says is not open would be nonsense.
    @Test func theFrontTabIsAlwaysOneYouCanSee() throws {
        let scratch = try Scratch()
        let acme = try scratch.open("acme", "one.md")
        _ = try scratch.open("beta", "three.md")
        #expect(scratch.state.activeTabID != acme.id)

        scratch.state.selectGroup("acme")
        #expect(scratch.state.active?.id == acme.id)
    }

    @Test func openingElsewhereBringsTheFilterWithIt() throws {
        let scratch = try Scratch()
        try scratch.open("acme", "one.md")
        scratch.state.selectGroup("acme")

        let beta = try scratch.open("beta", "three.md")
        #expect(scratch.state.selectedGroup == "beta")
        #expect(scratch.state.visibleTabs.map(\.id) == [beta.id])
    }

    @Test func steppingBetweenTabsStaysInsideTheGroup() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        let two = try scratch.open("acme", "two.md")
        try scratch.open("beta", "three.md")

        scratch.state.selectGroup("acme")
        scratch.state.selectAdjacentTab(offset: 1)
        #expect([one.id, two.id].contains(scratch.state.activeTabID!))
        scratch.state.selectAdjacentTab(offset: 1)
        #expect([one.id, two.id].contains(scratch.state.activeTabID!))
    }

    @Test func closingOtherTabsSparesTheOnesYouCannotSee() throws {
        let scratch = try Scratch()
        try scratch.open("acme", "one.md")
        let two = try scratch.open("acme", "two.md")
        try scratch.open("beta", "three.md")

        scratch.state.selectGroup("acme")
        scratch.state.activate(two.id)
        scratch.state.closeOtherTabs()

        #expect(scratch.state.visibleTabs.map(\.name) == ["two.md"])
        #expect(Set(scratch.state.tabs.map(\.name)) == ["two.md", "three.md"])
    }

    @Test func theFilterIsDroppedWhenItsLastDocumentCloses() throws {
        let scratch = try Scratch()
        try scratch.open("acme", "one.md")
        let beta = try scratch.open("beta", "three.md")
        scratch.state.selectGroup("beta")

        scratch.state.closeTab(beta.id)
        #expect(scratch.state.selectedGroup == nil)
        #expect(scratch.state.visibleTabs.map(\.name) == ["one.md"])
    }

    // MARK: - Overriding by hand

    @Test func aDocumentCanBeMovedToAnotherGroup() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        try scratch.open("beta", "three.md")

        scratch.state.assign(one, to: "Roadmap")
        #expect(one.group == "Roadmap")
        #expect(scratch.state.groups == ["beta", "Roadmap"])
    }

    @Test func movingItBackUsesTheFolderNameAgain() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        scratch.state.assign(one, to: "Roadmap")
        #expect(one.groupOverride == "Roadmap")

        scratch.state.assign(one, to: nil)
        #expect(one.groupOverride == nil)
        #expect(one.group == "acme")
    }

    @Test func aBlankNameIsTreatedAsGoingBackToAutomatic() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        scratch.state.assign(one, to: "   ")
        #expect(one.group == "acme")
    }

    @Test func movingTheFrontDocumentTakesTheFilterWithIt() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        scratch.state.selectGroup("acme")

        scratch.state.assign(one, to: "Roadmap")
        #expect(scratch.state.selectedGroup == "Roadmap")
        #expect(scratch.state.visibleTabs.map(\.id) == [one.id])
    }

    @Test func cancellingTheNameDialogChangesNothing() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        scratch.state.assignToNewGroup(one, askingForName: { _ in nil })
        #expect(one.group == "acme")
        scratch.state.assignToNewGroup(one, askingForName: { _ in "  Roadmap " })
        #expect(one.group == "Roadmap")
    }

    // MARK: - Remembered

    @Test func groupsAndTheFilterSurviveASession() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        try scratch.open("beta", "three.md")
        scratch.state.assign(one, to: "Roadmap")
        scratch.state.selectGroup("Roadmap")

        let session = scratch.state.session
        #expect(session.selectedGroup == "Roadmap")
        #expect(session.entries.compactMap(\.group) == ["Roadmap"])

        // A session written before groups existed still reads.
        var older = session
        older.selectedGroup = nil
        for index in older.entries.indices { older.entries[index].group = nil }
        let data = try JSONEncoder().encode(older)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        #expect(decoded.selectedGroup == nil)
        #expect(decoded.entries.allSatisfy { $0.group == nil })
    }
}
