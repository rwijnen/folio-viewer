import Foundation

/// Sequences the two things that can happen at launch: restoring the previous session,
/// and opening whatever Finder was asked to open.
///
/// macOS delivers `application(_:open:)` *before* `applicationDidFinishLaunching` when
/// the app is launched by opening a document. Acting on it immediately races the session
/// restore, which skips itself when tabs already exist; deferring it to the next
/// main-actor hop instead lets the restored session draw and be replaced a frame later,
/// which looks like the app restarting.
///
/// So files that arrive early wait here, and launch happens in one pass: restore, then
/// open what was waiting, then draw.
@MainActor
final class LaunchQueue {

    private var pending: [URL] = []
    private(set) var hasLaunched = false

    /// What to open right now for a request. Empty while the app is still starting, in
    /// which case the URLs are held until `launchFinished()`.
    func open(_ urls: [URL]) -> [URL] {
        guard hasLaunched else {
            pending.append(contentsOf: urls)
            return []
        }
        return urls
    }

    /// Call once the session has been restored. Returns everything that was waiting, in
    /// the order it arrived.
    @discardableResult
    func launchFinished() -> [URL] {
        hasLaunched = true
        let waiting = pending
        pending = []
        return waiting
    }
}
