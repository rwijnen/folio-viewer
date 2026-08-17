import Foundation
import Testing

@testable import Folio

/// Opening a file from Finder used to look like the app restarting: macOS delivers the
/// open request before launching finishes, so the previous session drew and was then
/// replaced. These pin the ordering that fixed it.
@Suite("Launch sequencing")
@MainActor
struct LaunchQueueTests {

    private let a = URL(fileURLWithPath: "/tmp/notes/a.md")
    private let b = URL(fileURLWithPath: "/tmp/notes/b.md")
    private let c = URL(fileURLWithPath: "/tmp/notes/c.md")

    @Test func filesArrivingBeforeLaunchFinishesWait() {
        let queue = LaunchQueue()
        #expect(!queue.hasLaunched)
        // Nothing to open yet — the session has not been restored.
        #expect(queue.open([a]).isEmpty)
        #expect(queue.open([b, c]).isEmpty)

        // And then all of them, in the order they arrived.
        #expect(queue.launchFinished() == [a, b, c])
        #expect(queue.hasLaunched)
    }

    @Test func filesArrivingAfterwardsOpenStraightAway() {
        let queue = LaunchQueue()
        queue.launchFinished()
        #expect(queue.open([a]) == [a])
        #expect(queue.open([b, c]) == [b, c])
    }

    @Test func nothingIsDeliveredTwice() {
        let queue = LaunchQueue()
        #expect(queue.open([a]).isEmpty)
        #expect(queue.launchFinished() == [a])
        // A second launch would be a bug, but it must not replay the file either.
        #expect(queue.launchFinished().isEmpty)
    }

    @Test func aLaunchWithNoDocumentHasNothingWaiting() {
        let queue = LaunchQueue()
        #expect(queue.launchFinished().isEmpty)
    }
}

/// The other half of the same bug: only the first of several selected files was opened.
@Suite("Opening several files")
@MainActor
struct MultipleOpenTests {

    @Test func everySelectedFileGetsATab() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-multi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let urls = try ["one.md", "two.md", "three.md"].map { name -> URL in
            let url = folder.appendingPathComponent(name)
            try "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let state = AppState()
        let queue = LaunchQueue()
        for url in queue.open(urls) { state.open(at: url) }
        #expect(state.tabs.isEmpty, "still launching, so nothing should be open yet")

        for url in queue.launchFinished() { state.open(at: url) }
        #expect(state.tabs.map(\.name) == ["one.md", "two.md", "three.md"])
        // The last one asked for is the one you are looking at.
        #expect(state.active?.name == "three.md")
    }
}

/// Folio handles the open-documents Apple Event itself, because SwiftUI's handler closes
/// and re-presents the window before the event reaches the delegate. Reading the event is
/// the part that could fail silently — nothing would open, with no error anywhere.
@Suite("Open-documents event")
struct OpenDocumentsEventTests {

    private func openEvent(_ direct: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                           eventID: AEEventID(kAEOpenDocuments),
                                           targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(direct, forKeyword: keyDirectObject)
        return event
    }

    @Test func oneFileArrivesAsADescriptorOfItsOwn() throws {
        let url = URL(fileURLWithPath: "/tmp/notes/one.md")
        let urls = AppDelegate.filesRequested(by: openEvent(NSAppleEventDescriptor(fileURL: url)))
        #expect(urls.map(\.path) == ["/tmp/notes/one.md"])
    }

    @Test func severalFilesArriveAsAList() throws {
        let paths = ["/tmp/notes/one.md", "/tmp/notes/two.md", "/tmp/notes/three.md"]
        let list = NSAppleEventDescriptor.list()
        for (offset, path) in paths.enumerated() {
            list.insert(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: path)),
                        at: offset + 1)
        }
        #expect(AppDelegate.filesRequested(by: openEvent(list)).map(\.path) == paths)
    }

    /// Names with spaces and other characters that have to survive percent-encoding.
    @Test func awkwardNamesSurvive() throws {
        let path = "/tmp/notes/my \"weekly\" review & notes.md"
        let urls = AppDelegate.filesRequested(
            by: openEvent(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: path))))
        #expect(urls.map(\.path) == [path])
    }

    @Test func anEventWithNothingInItOpensNothing() {
        let empty = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                           eventID: AEEventID(kAEOpenDocuments),
                                           targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        #expect(AppDelegate.filesRequested(by: empty).isEmpty)
        #expect(AppDelegate.filesRequested(by: openEvent(NSAppleEventDescriptor.list())).isEmpty)
    }
}
