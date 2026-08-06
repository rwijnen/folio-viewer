import Foundation

/// What was open last time, so relaunching puts it back.
///
/// Only the reader's *place* is remembered — paths, which document was in front, the
/// reading mode and the scroll position. Nothing about the documents themselves is
/// stored, and files that have since been moved or deleted are dropped silently on the
/// way back in.
struct Session: Codable, Equatable {

    struct Entry: Codable, Equatable {
        var path: String
        /// "rendered" or "source"; ignored for anything that is not Markdown.
        var readingMode: String
        /// Which file of a diff was selected, by position.
        var selectedFileIndex: Int?
        /// Scroll offset of whatever view this document was showing.
        var scrollOffset: Double
        /// Scroll offset inside the rendered page.
        var webScrollOffset: Double
        /// Headings folded away in the outline. Absent in sessions written before
        /// the outline could fold.
        var collapsedOutline: [String]?
    }

    var entries: [Entry] = []
    /// Position of the document that was in front.
    var activeIndex: Int?

    /// A guard against a runaway session file putting a hundred tabs on screen at launch.
    static let maximumEntries = 25

    var trimmed: Session {
        guard entries.count > Self.maximumEntries else { return self }
        var copy = self
        copy.entries = Array(entries.prefix(Self.maximumEntries))
        if let active = activeIndex, active >= Self.maximumEntries { copy.activeIndex = 0 }
        return copy
    }

    /// Drops entries whose file is no longer there, keeping `activeIndex` pointing at the
    /// same document.
    func existingOnly(using fileExists: (String) -> Bool = {
        FileManager.default.fileExists(atPath: $0)
    }) -> Session {
        var result = Session()
        var newActive: Int?
        for (index, entry) in entries.enumerated() where fileExists(entry.path) {
            if index == activeIndex { newActive = result.entries.count }
            result.entries.append(entry)
        }
        // The document that was in front has gone: fall back to the last one.
        result.activeIndex = newActive ?? (result.entries.isEmpty ? nil : result.entries.count - 1)
        return result
    }
}

extension Preferences {

    private static var sessionKey: String { "session" }

    static func loadSession() -> Session {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(Session.self, from: data) else {
            return Session()
        }
        return session
    }

    static func saveSession(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session.trimmed) else { return }
        UserDefaults.standard.set(data, forKey: sessionKey)
    }

    static func clearSession() {
        UserDefaults.standard.removeObject(forKey: sessionKey)
    }
}

extension AppState {

    /// Snapshot of what is open, in tab order.
    var session: Session {
        var result = Session()
        for tab in tabs {
            if let pending = tab.pendingRestore {
                result.entries.append(pending)
                continue
            }
            result.entries.append(Session.Entry(
                path: tab.url.standardizedFileURL.path,
                readingMode: tab.readingMode.rawValue,
                selectedFileIndex: tab.selectedFileID.flatMap { id in
                    tab.files.firstIndex { $0.id == id }
                },
                scrollOffset: Double(tab.scrollOffsets.offset(for: tab.scrollKey)),
                webScrollOffset: Double(tab.webScrollOffset),
                collapsedOutline: tab.collapsedOutline.isEmpty
                    ? nil : tab.collapsedOutline.sorted()
            ))
        }
        result.activeIndex = activeTabID.flatMap { id in tabs.firstIndex { $0.id == id } }
        return result
    }

    /// Records the session. Cheap, so it runs on every change that alters it; scroll
    /// positions are only captured here, which is why quitting saves once more.
    func saveSession() {
        guard sessionRestoreEnabled else { return }
        Preferences.saveSession(session)
    }

    /// Puts back what was open last time. Does nothing if a document is already open,
    /// so a file opened from Finder at launch is never overwritten.
    @discardableResult
    func restoreSession() -> Int {
        guard sessionRestoreEnabled, tabs.isEmpty else { return 0 }
        let stored = Preferences.loadSession().trimmed.existingOnly()
        guard !stored.entries.isEmpty else { return 0 }

        // Placeholders only: reading and converting every document here would stall
        // the launch (measured at ~43 ms each). A tab fills itself in when it is first
        // shown, which for all but one of them is never, or much later.
        let restored = stored.entries.map { entry -> DocumentTab in
            let url = URL(fileURLWithPath: entry.path)
            let tab = DocumentTab(url: url, content: Self.inferredContent(for: url))
            tab.pendingRestore = entry
            return tab
        }
        adoptRestored(restored, activeIndex: stored.activeIndex)
        if let tab = active { prepareIfNeeded(tab) }
        saveSession()
        return tabs.count
    }

    /// What a document is, from its name alone — enough to label a tab before its
    /// contents have been read. An unfamiliar extension is settled when it is prepared.
    static func inferredContent(for url: URL) -> DocumentContent {
        let ext = url.pathExtension.lowercased()
        if diffExtensions.contains(ext) { return .diff }
        if markdownExtensions.contains(ext) { return .markdown }
        return .source
    }

    /// Reads a restored tab's document the first time it is needed.
    func prepareIfNeeded(_ tab: DocumentTab) {
        guard let entry = tab.pendingRestore else { return }
        tab.pendingRestore = nil
        do {
            switch Self.inferredContent(for: tab.url) {
            case .diff:
                try loadDiff(into: tab)
            case .markdown:
                tab.textDocument = try Self.makeTextDocument(at: tab.url, asMarkdown: true)
                tab.content = .markdown
                tab.readingMode = .rendered
            default:
                // Unknown extension: the same sniff `open(at:)` does.
                if let text = try? TextNormalizer.readText(at: tab.url),
                   !DiffParser.parse(text: text).files.isEmpty {
                    try loadDiff(into: tab)
                } else {
                    tab.textDocument = try Self.makeTextDocument(at: tab.url, asMarkdown: false)
                    tab.content = .source
                    tab.readingMode = .source
                }
            }
            tab.visibleAnchor = tab.textDocument?.outline.first?.id ?? ""
            apply(entry, to: tab)
            if tab.content == .diff { reloadSelectedFile(for: tab) }
        } catch let error as DiffOpenError {
            errorMessage = error.message
            closeTab(tab.id)
        } catch {
            errorMessage = "Could not read \(tab.url.lastPathComponent): "
                + "\(error.localizedDescription)"
            closeTab(tab.id)
        }
    }

    private func apply(_ entry: Session.Entry, to tab: DocumentTab) {
        if tab.isMarkdown, let mode = ReadingMode(rawValue: entry.readingMode) {
            tab.readingMode = mode
        }
        if let index = entry.selectedFileIndex, tab.files.indices.contains(index) {
            tab.selectedFileID = tab.files[index].id
        }
        // Recorded against the key this tab will actually use — a diff's key contains a
        // file id that is only minted now, which is why it is applied here rather than
        // stored verbatim.
        if entry.scrollOffset > 1 {
            tab.scrollOffsets.record(CGFloat(entry.scrollOffset), for: tab.scrollKey)
        }
        tab.webScrollOffset = CGFloat(entry.webScrollOffset)
        if let collapsed = entry.collapsedOutline {
            tab.collapsedOutline = Set(collapsed)
        }
    }
}
