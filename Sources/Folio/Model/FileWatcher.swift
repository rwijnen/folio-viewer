import Foundation

/// Watches one file and reports when something else writes to it.
///
/// The case this exists for: a model writes a document while it is open in Folio. Without
/// it, the reader sees stale text until they happen to press ⌘R, and the first sign that
/// anything happened is the overwrite warning when they try to save.
///
/// `onChange` is called on a private queue, coalesced, and says only that *something*
/// happened — it makes no claim that the content differs. Deciding that is the caller's
/// job, and it does it by comparing the text, the same way saving does.
final class FileWatcher {

    /// Events arriving closer together than this become one. A write is rarely one
    /// syscall, and a tool that rewrites a file in pieces would otherwise report each.
    private static let coalesce: DispatchTimeInterval = .milliseconds(120)
    /// How long to keep trying to re-open a path that has gone. An atomic replace leaves
    /// a gap of microseconds; these delays are generous enough to cover a slow one and
    /// short enough that a genuinely deleted file is given up on quickly.
    private static let rearmDelays: [DispatchTimeInterval] =
        [.milliseconds(20), .milliseconds(60), .milliseconds(200), .milliseconds(600)]

    private let url: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "folio.file-watcher")

    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var rearmAttempt = 0
    private var isCancelled = false

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
        queue.async { [self] in arm() }
    }

    deinit { source?.cancel() }

    func cancel() {
        queue.async { [self] in
            isCancelled = true
            pending?.cancel()
            pending = nil
            teardown()
        }
    }

    // MARK: - The source

    private func arm() {
        guard !isCancelled, source == nil else { return }
        // O_EVTONLY asks only to be told about the file, which is why this does not
        // count against the process's open-file limit the way a read handle would.
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleRearm()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke, .attrib],
            queue: queue)
        source.setEventHandler { [weak self] in
            self?.handle(source.data)
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        rearmAttempt = 0
        source.resume()
    }

    private func handle(_ events: DispatchSource.FileSystemEvent) {
        guard !isCancelled else { return }
        // An atomic save does not write into the file; it writes a new one alongside and
        // renames it over the top. The descriptor then refers to an unlinked inode that
        // will never change again, so watching it further is watching nothing. Folio's
        // own saves work exactly this way, and so do most editors' and most tools'.
        if !events.intersection([.delete, .rename, .revoke]).isEmpty {
            teardown()
            scheduleRearm()
        }
        notify()
    }

    private func scheduleRearm() {
        guard !isCancelled, rearmAttempt < Self.rearmDelays.count else { return }
        let delay = Self.rearmDelays[rearmAttempt]
        rearmAttempt += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.arm() }
    }

    private func teardown() {
        source?.cancel()
        source = nil
    }

    private func notify() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.onChange()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + Self.coalesce, execute: work)
    }
}
