import Foundation
import Testing

@testable import Folio

@Suite("Group names")
struct DocumentGroupNameTests {

    @Test func groupsAreListedAlphabeticallyAndOnce() {
        #expect(DocumentGroup.listed(from: ["notes", "acme", "notes", "Beta"])
                == ["acme", "Beta", "notes"])
        #expect(DocumentGroup.listed(from: []).isEmpty)
    }

    /// Documents that have not been filed contribute no group.
    @Test func unfiledDocumentsAreNotAGroup() {
        #expect(DocumentGroup.listed(from: [nil, "acme", nil]) == ["acme"])
        #expect(DocumentGroup.listed(from: [nil, nil]).isEmpty)
    }

    /// An empty name is how "take it out of its group" is spelled.
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

    @Test func documentsStartInNoGroup() throws {
        let scratch = try Scratch()
        try scratch.open("acme", "one.md")
        try scratch.open("beta", "three.md")

        // Nothing is inferred — not from the folder, not from anything.
        #expect(scratch.state.groups.isEmpty)
        #expect(scratch.state.ungroupedCount == 2)
        #expect(scratch.state.visibleTabs.count == 2)
    }

    @Test func filingADocumentCreatesTheGroup() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        let two = try scratch.open("acme", "two.md")
        try scratch.open("beta", "three.md")

        scratch.state.assign(one, to: "Acme rollout")
        scratch.state.assign(two, to: "Acme rollout")

        #expect(scratch.state.groups == ["Acme rollout"])
        #expect(scratch.state.documentCount(inGroup: "Acme rollout") == 2)
        #expect(scratch.state.ungroupedCount == 1)
    }

    /// Documents from different folders belong together when the reader says they do —
    /// which is the whole reason the folder is not used.
    @Test func aGroupCanSpanFolders() throws {
        let scratch = try Scratch()
        let guide = try scratch.open("guides", "install.md")
        let adr = try scratch.open("adr", "0001.md")
        scratch.state.assign(guide, to: "Docs")
        scratch.state.assign(adr, to: "Docs")

        scratch.state.selectGroup("Docs")
        #expect(scratch.state.visibleTabs.count == 2)
        #expect(scratch.state.groups == ["Docs"])
    }

    @Test func choosingAGroupHidesTheRestWithoutClosingThem() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        let beta = try scratch.open("beta", "three.md")
        scratch.state.assign(one, to: "Acme")
        scratch.state.updateDraft("# edited\n", for: beta)

        scratch.state.selectGroup("Acme")
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
        scratch.state.assign(acme, to: "Acme")
        #expect(scratch.state.activeTabID != acme.id)

        scratch.state.selectGroup("Acme")
        #expect(scratch.state.active?.id == acme.id)
    }

    /// Opening a document while a project is selected used to drop the filter: the new
    /// tab was in no group, coming forward revealed "no group", and the reader lost the
    /// view they were working in — every time they opened a file from Finder.
    @Test func aDocumentOpenedWhileAGroupIsSelectedJoinsIt() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        scratch.state.assign(one, to: "Acme")
        scratch.state.selectGroup("Acme")

        let fresh = try scratch.open("beta", "three.md")
        #expect(fresh.group == "Acme")
        #expect(scratch.state.selectedGroup == "Acme")
        #expect(scratch.state.visibleTabs.contains { $0.id == fresh.id })
        // The folder it came from has nothing to do with it; the open filter does.
        #expect(scratch.state.visibleTabs.count == 2)
    }

    /// With everything showing there is no project to join, so nothing is invented.
    @Test func aDocumentOpenedWithNoGroupSelectedStaysUnfiled() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        scratch.state.assign(one, to: "Acme")
        scratch.state.selectGroup(nil)

        let fresh = try scratch.open("beta", "three.md")
        #expect(fresh.group == nil)
        #expect(scratch.state.selectedGroup == nil)
    }

    /// Reopening a document that is already open is not a new document: it comes
    /// forward as it is, and the filter follows it rather than refiling it.
    @Test func reopeningADocumentDoesNotRefileIt() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        let two = try scratch.open("beta", "two.md")
        scratch.state.assign(one, to: "Acme")
        scratch.state.assign(two, to: "Beta")
        scratch.state.selectGroup("Acme")

        scratch.state.open(at: two.url)
        #expect(two.group == "Beta")
        #expect(scratch.state.selectedGroup == "Beta")
    }

    /// Taking a document out of a group by hand must stick, even with a group selected.
    @Test func takingADocumentOutOfAGroupIsNotUndone() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        scratch.state.assign(one, to: "Acme")
        scratch.state.selectGroup("Acme")

        scratch.state.assign(one, to: nil)
        #expect(one.group == nil)
    }

    @Test func steppingBetweenTabsStaysInsideTheGroup() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        let two = try scratch.open("acme", "two.md")
        try scratch.open("beta", "three.md")
        scratch.state.assign(one, to: "Acme")
        scratch.state.assign(two, to: "Acme")

        scratch.state.selectGroup("Acme")
        scratch.state.selectAdjacentTab(offset: 1)
        #expect([one.id, two.id].contains(scratch.state.activeTabID!))
        scratch.state.selectAdjacentTab(offset: 1)
        #expect([one.id, two.id].contains(scratch.state.activeTabID!))
    }

    @Test func closingOtherTabsSparesTheOnesYouCannotSee() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        let two = try scratch.open("acme", "two.md")
        try scratch.open("beta", "three.md")
        scratch.state.assign(one, to: "Acme")
        scratch.state.assign(two, to: "Acme")

        scratch.state.selectGroup("Acme")
        scratch.state.activate(two.id)
        scratch.state.closeOtherTabs()

        #expect(scratch.state.visibleTabs.map(\.name) == ["two.md"])
        #expect(Set(scratch.state.tabs.map(\.name)) == ["two.md", "three.md"])
    }

    @Test func theFilterIsDroppedWhenItsLastDocumentCloses() throws {
        let scratch = try Scratch()
        try scratch.open("acme", "one.md")
        let beta = try scratch.open("beta", "three.md")
        scratch.state.assign(beta, to: "Beta")
        scratch.state.selectGroup("Beta")

        scratch.state.closeTab(beta.id)
        #expect(scratch.state.selectedGroup == nil)
        #expect(scratch.state.visibleTabs.map(\.name) == ["one.md"])
    }

    /// The group goes with the last document in it; nothing is left behind to tidy up.
    @Test func aGroupStopsExistingWhenNothingIsInIt() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        scratch.state.assign(one, to: "Acme")
        #expect(scratch.state.groups == ["Acme"])

        scratch.state.assign(one, to: nil)
        #expect(scratch.state.groups.isEmpty)
        #expect(one.group == nil)
    }

    // MARK: - Filing by hand

    @Test func aDocumentCanBeMovedBetweenGroups() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        scratch.state.assign(one, to: "Acme")
        scratch.state.assign(one, to: "Roadmap")
        #expect(one.group == "Roadmap")
        #expect(scratch.state.groups == ["Roadmap"])
    }

    @Test func aBlankNameTakesItOutOfItsGroup() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        scratch.state.assign(one, to: "Acme")
        scratch.state.assign(one, to: "   ")
        #expect(one.group == nil)
    }

    @Test func movingTheFrontDocumentTakesTheFilterWithIt() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        scratch.state.assign(one, to: "Acme")
        scratch.state.selectGroup("Acme")

        scratch.state.assign(one, to: "Roadmap")
        #expect(scratch.state.selectedGroup == "Roadmap")
        #expect(scratch.state.visibleTabs.map(\.id) == [one.id])
    }

    @Test func cancellingTheNameDialogChangesNothing() throws {
        let scratch = try Scratch()
        let one = try scratch.open("acme", "one.md")
        scratch.state.assignToNewGroup(one, askingForName: { _ in nil })
        #expect(one.group == nil)
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
