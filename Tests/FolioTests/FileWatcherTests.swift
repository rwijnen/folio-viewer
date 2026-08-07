import Foundation
import Testing

@testable import Folio

/// Counts callbacks from the watcher's queue.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class Scratch {
    let folder: URL
    let url: URL

    init(_ contents: String = "one\n") throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("note.md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// The way almost everything writes: a temp file renamed over the top. This replaces
    /// the inode, which is the case the watcher has to survive.
    func writeAtomically(_ contents: String) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    /// Writing into the existing file, without replacing it.
    func writeInPlace(_ contents: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(contents.utf8))
    }
}

private func waitFor(_ what: String, timeout: TimeInterval = 5,
                     _ condition: @escaping () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline, !condition() {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    if !condition() { Issue.record("timed out waiting for \(what)") }
}

@Suite("File watcher", .serialized)
struct FileWatcherTests {

    @Test func anInPlaceWriteIsReported() async throws {
        let scratch = try Scratch()
        let counter = Counter()
        let watcher = FileWatcher(url: scratch.url) { counter.bump() }
        defer { watcher.cancel() }
        // Give the source a moment to arm before touching the file.
        try await Task.sleep(nanoseconds: 150_000_000)

        try scratch.writeInPlace("two\n")
        await waitFor("the in-place write") { counter.count >= 1 }
    }

    /// The one that matters. Folio's own saves, most editors' and most tools' replace the
    /// file rather than writing into it, so a watcher that only holds a descriptor sees
    /// one event and then never hears anything again.
    @Test func anAtomicReplaceIsReportedAndTheWatcherSurvivesIt() async throws {
        let scratch = try Scratch()
        let counter = Counter()
        let watcher = FileWatcher(url: scratch.url) { counter.bump() }
        defer { watcher.cancel() }
        try await Task.sleep(nanoseconds: 150_000_000)

        try scratch.writeAtomically("two\n")
        await waitFor("the first replace") { counter.count >= 1 }
        let afterFirst = counter.count

        // A second replace must be seen too — this is what fails when the watcher does
        // not re-open the path after the inode is swapped out from under it.
        try await Task.sleep(nanoseconds: 700_000_000)
        try scratch.writeAtomically("three\n")
        await waitFor("the second replace") { counter.count > afterFirst }

        try await Task.sleep(nanoseconds: 700_000_000)
        let afterSecond = counter.count
        try scratch.writeAtomically("four\n")
        await waitFor("the third replace") { counter.count > afterSecond }
    }

    @Test func deletionIsReported() async throws {
        let scratch = try Scratch()
        let counter = Counter()
        let watcher = FileWatcher(url: scratch.url) { counter.bump() }
        defer { watcher.cancel() }
        try await Task.sleep(nanoseconds: 150_000_000)

        try FileManager.default.removeItem(at: scratch.url)
        await waitFor("the deletion") { counter.count >= 1 }
    }

    /// A file written in several pieces should read as one change, not several.
    @Test func aBurstOfWritesBecomesOneReport() async throws {
        let scratch = try Scratch()
        let counter = Counter()
        let watcher = FileWatcher(url: scratch.url) { counter.bump() }
        defer { watcher.cancel() }
        try await Task.sleep(nanoseconds: 150_000_000)

        for index in 1...8 {
            try scratch.writeInPlace("chunk \(index)\n")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await waitFor("the coalesced report") { counter.count >= 1 }
        try await Task.sleep(nanoseconds: 400_000_000)
        // Eight writes 10 ms apart, well inside the coalescing window.
        #expect(counter.count <= 2)
    }

    @Test func nothingIsReportedAfterCancelling() async throws {
        let scratch = try Scratch()
        let counter = Counter()
        let watcher = FileWatcher(url: scratch.url) { counter.bump() }
        try await Task.sleep(nanoseconds: 150_000_000)
        watcher.cancel()
        try await Task.sleep(nanoseconds: 150_000_000)

        let before = counter.count
        try scratch.writeAtomically("after cancelling\n")
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(counter.count == before)
    }

    @Test func watchingAFileThatDoesNotExistYetDoesNotCrash() async throws {
        let scratch = try Scratch()
        let missing = scratch.folder.appendingPathComponent("absent.md")
        let counter = Counter()
        let watcher = FileWatcher(url: missing) { counter.bump() }
        defer { watcher.cancel() }
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(counter.count == 0)
    }
}
