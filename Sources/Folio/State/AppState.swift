import AppKit
import Observation
import SwiftUI

/// Window-wide state: which documents are open, which one is showing, and the
/// preferences and find bar they share.
///
/// Everything that belongs to a single document lives on `DocumentTab`. The
/// forwarding accessors below keep the views written against "the current document"
/// while the state itself is per tab.
@MainActor
@Observable
final class AppState {

    static let shared = AppState()

    // MARK: - Open documents

    private(set) var tabs: [DocumentTab] = []
    private(set) var activeTabID: UUID?

    var active: DocumentTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    // MARK: - Window-wide state

    var statusMessage: String?
    var errorMessage: String?
    /// Line wrapping is a window-wide preference, not a per-document one.
    var wrapLines = true
    /// Whether a document with no unsaved edits is brought up to date on its own when
    /// something else writes the file. On by default: a stale document that looks
    /// current is the worse of the two failures.
    ///
    /// Starts from the stored preference and is written back only by the real app —
    /// the same guard the session uses, so a test run cannot disturb real settings.
    var reloadsChangedFilesAutomatically = Preferences.automaticReload {
        didSet {
            guard sessionRestoreEnabled else { return }
            Preferences.automaticReload = reloadsChangedFilesAutomatically
        }
    }
    var showOutline = true
    /// Mirrors the window's appearance so rendered pages can match it.
    var isDarkAppearance = false {
        didSet {
            guard isDarkAppearance != oldValue else { return }
            // Every rendered page carries the theme, so they all need rebuilding.
            for tab in tabs { tab.pageVersion += 1 }
        }
    }

    // MARK: - Version control (the sheet is window-wide; status lives per document)

    /// Layered onto every git command Folio runs. Empty in the app; the tests use it to
    /// seal git off from the developer's own configuration, so a global hook or a signing
    /// key cannot change what a test sees.
    @ObservationIgnored var gitEnvironment: [String: String] = [:]

    var isCommitSheetPresented = false
    var commitMessage = ""
    var commitShouldPush = false

    // MARK: - Find (one bar, shared; results live per document)

    var isFindPresented = false
    var searchQuery = ""
    var searchCaseSensitive = false
    /// Bumped by ⌘F so the find field takes focus even when the bar is already showing.
    private(set) var findFocusRequest = 0

    /// Used only when nothing is open, so views never deal with an optional renderer.
    @ObservationIgnored private let fallbackRenderer = LineRenderer()
    /// Monotonic counter behind the least-recently-shown ordering.
    @ObservationIgnored private var showCounter = 0
    /// Off for the shared instance only while restoring, and off entirely in tests so a
    /// test run never disturbs the real session.
    @ObservationIgnored var sessionRestoreEnabled = false
    @ObservationIgnored private var isRestoring = false

    // MARK: - Forwarding to the active document

    var content: DocumentContent { active?.content ?? .none }
    var textDocument: TextDocument? { active?.textDocument }
    var files: [FileEntry] { active?.files ?? [] }
    var baseFolder: URL? { active?.baseFolder }
    var loadState: FileLoadState { active?.loadState ?? .empty }
    var diagramReport: String? { active?.diagramReport }
    var renderer: LineRenderer { active?.renderer ?? fallbackRenderer }
    var selectedEntry: FileEntry? { active?.selectedEntry }
    var loadedFile: LoadedFile? { active?.loadedFile }
    var totalAdditions: Int { active?.totalAdditions ?? 0 }
    var totalDeletions: Int { active?.totalDeletions ?? 0 }
    var displayItems: [DisplayItem] { active?.displayItems ?? [] }
    var matches: [SearchMatch] { active?.matches ?? [] }
    var currentMatchIndex: Int { active?.currentMatchIndex ?? 0 }
    var currentMatch: SearchMatch? { active?.currentMatch }
    var scrollRequest: Int { active?.scrollRequest ?? 0 }
    var renderedMatchCount: Int { active?.renderedMatchCount ?? 0 }
    var renderedMatchIndex: Int { active?.renderedMatchIndex ?? -1 }
    var renderedFocusRequest: Int { active?.renderedFocusRequest ?? 0 }
    var renderedFocusTarget: Int { active?.renderedFocusTarget ?? 0 }
    var pendingAnchor: String? { active?.pendingAnchor }
    var anchorRequest: Int { active?.anchorRequest ?? 0 }
    var sourceScrollLine: Int? { active?.sourceScrollLine }
    var sourceScrollRequest: Int { active?.sourceScrollRequest ?? 0 }
    var documentTitle: String { active?.name ?? "Folio" }
    var renderedPage: String? { active?.renderedPage(isDark: isDarkAppearance) }
    var renderedPageToken: String { active?.renderedPageToken ?? "none" }

    var selectedFileID: UUID? {
        get { active?.selectedFileID }
        set { if let newValue { selectFile(newValue) } }
    }

    var readingMode: ReadingMode {
        get { active?.readingMode ?? .rendered }
        set { setReadingMode(newValue) }
    }

    var expandedFolds: Set<Int> {
        get { active?.expandedFolds ?? [] }
        set { active?.expandedFolds = newValue }
    }

    var visibleAnchor: String {
        get { active?.visibleAnchor ?? "" }
        set { active?.visibleAnchor = newValue }
    }

    func searchRanges(inRow row: Int, isLeft: Bool) -> [Range<Int>] {
        active?.searchRanges(inRow: row, isLeft: isLeft) ?? []
    }

    // MARK: - Opening

    /// Single entry point for every way a file arrives: Finder, ⌘O, drag and drop.
    /// A file that is already open is brought forward instead of opened twice.
    func open(at url: URL) {
        openWithoutSaving(at: url)
        saveSession()
    }

    /// The opening itself. Kept separate so restoring a session does not write the
    /// session back out once per document.
    func openWithoutSaving(at url: URL) {
        errorMessage = nil
        statusMessage = nil
        let standardized = url.standardizedFileURL

        if let existing = tabs.first(where: { $0.url.standardizedFileURL == standardized }) {
            activate(existing.id)
            statusMessage = "\(existing.name) is already open."
            return
        }

        let ext = standardized.pathExtension.lowercased()
        if Self.diffExtensions.contains(ext) {
            openDiff(at: standardized)
        } else if Self.markdownExtensions.contains(ext) {
            openTextDocument(at: standardized, asMarkdown: true)
        } else if let text = try? TextNormalizer.readText(at: standardized),
                  !DiffParser.parse(text: text).files.isEmpty {
            // Unknown extension whose contents parse as a unified diff.
            openDiff(at: standardized)
        } else {
            openTextDocument(at: standardized, asMarkdown: false)
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose diffs, patches or Markdown documents"
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(at: url) }
    }

    // MARK: - Tabs

    func adopt(_ tab: DocumentTab) {
        tabs.append(tab)
        setActive(tab.id)
        noteShown(tab.id)
    }

    /// Installs a restored set of tabs wholesale. Only the session uses this; every
    /// other route goes through `adopt`.
    func adoptRestored(_ restored: [DocumentTab], activeIndex: Int?) {
        tabs = restored
        let index = activeIndex.flatMap { restored.indices.contains($0) ? $0 : nil } ?? 0
        setActive(restored.indices.contains(index) ? restored[index].id : nil)
    }

    /// The single place the front tab changes: a restored tab is only read when it gets
    /// here, so nothing else may assign `activeTabID` directly.
    private func setActive(_ id: UUID?) {
        activeTabID = id
        guard let id, let tab = tabs.first(where: { $0.id == id }) else { return }
        prepareIfNeeded(tab)
        // Here rather than in `activate`, so a tab arriving from a restored session or
        // from a neighbour closing gets its status too.
        refreshGitStatus(for: tab)
    }

    /// Moves a tab to a new position, for dragging in the tab bar.
    func moveTab(_ id: UUID, to destination: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let target = max(0, min(destination, tabs.count - 1))
        guard source != target else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: target)
        saveSession()
    }

    func activate(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }), activeTabID != id else { return }
        setActive(id)
        noteShown(id)
        // The find bar is shared, so re-run it against the newly active document.
        if !searchQuery.isEmpty { recomputeMatches() }
        saveSession()
    }

    /// Live web views are expensive — each is a separate WebContent process holding a
    /// parsed copy of mermaid — so only the most recently used handful stay loaded. The
    /// rest are torn down and reload at their saved scroll offset when shown again.
    static let maximumLivePages = 5

    private func noteShown(_ id: UUID) {
        showCounter += 1
        tabs.first { $0.id == id }?.lastShownAt = showCounter
        trimLivePages()
    }

    /// Called when a document's web view is created, which is the moment the cap can
    /// be exceeded — trimming only on activation left one page too many loaded.
    func pageBecameLive(_ tab: DocumentTab) {
        if tab.lastShownAt == 0 {
            showCounter += 1
            tab.lastShownAt = showCounter
        }
        trimLivePages()
    }

    private func trimLivePages() {
        let live = tabs.filter { $0.page != nil }.sorted { $0.lastShownAt > $1.lastShownAt }
        guard live.count > Self.maximumLivePages else { return }
        for tab in live.dropFirst(Self.maximumLivePages) where tab.id != activeTabID {
            tab.releasePage()
        }
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].loadTask?.cancel()
        tabs[index].releasePage()
        stopWatching(tabs[index])
        let wasActive = activeTabID == id
        tabs.remove(at: index)
        guard wasActive else { return }
        if tabs.isEmpty {
            setActive(nil)
        } else {
            // The neighbour that comes forward may never have been read.
            setActive(tabs[min(index, tabs.count - 1)].id)
            if !searchQuery.isEmpty { recomputeMatches() }
        }
        saveSession()
    }

    func closeActiveTab() {
        guard let activeTabID else { return }
        closeTab(activeTabID)
    }

    func closeOtherTabs() {
        guard let activeTabID else { return }
        for tab in tabs where tab.id != activeTabID {
            tab.loadTask?.cancel()
            tab.releasePage()
            stopWatching(tab)
        }
        tabs = tabs.filter { $0.id == activeTabID }
        saveSession()
    }

    func selectAdjacentTab(offset: Int) {
        guard tabs.count > 1, let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        let next = (index + offset + tabs.count) % tabs.count
        activate(tabs[next].id)
    }

    func reset() {
        for tab in tabs {
            tab.loadTask?.cancel()
            tab.releasePage()
            stopWatching(tab)
        }
        tabs = []
        setActive(nil)
    }

    // MARK: - Diffs

    func openDiff(at url: URL) {
        let tab = DocumentTab(url: url, content: .diff)
        do {
            try loadDiff(into: tab)
            adopt(tab)
            reloadSelectedFile(for: tab)
        } catch let error as DiffOpenError {
            errorMessage = error.message
        } catch {
            errorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    struct DiffOpenError: Error { var message: String }

    /// Parses the diff and works out where its originals live, into a tab that may
    /// already be on screen.
    func loadDiff(into tab: DocumentTab) throws {
        let url = tab.url
        let text = try TextNormalizer.readText(at: url)
        let parsed = DiffParser.parse(text: text)
        guard !parsed.files.isEmpty else {
            throw DiffOpenError(message: "No diff content found in \(url.lastPathComponent). "
                + "Expected a unified diff (`git diff` or `diff -u`).")
        }

        tab.content = .diff
        tab.preamble = parsed.preamble

        let remembered = Preferences.baseFolder(forDiffAt: url)
        let inferred = remembered ?? PathResolver.inferBaseFolder(diffURL: url, files: parsed.files)
        tab.baseFolder = inferred
        tab.files = parsed.files.map { diff in
            FileEntry(diff: diff,
                      resolvedOriginal: PathResolver.resolve(
                        path: diff.rawOldPath ?? diff.rawNewPath ?? "", base: inferred))
        }
        if inferred == nil {
            statusMessage = "Couldn't find the original files. Choose the folder the diff was made in."
        } else if let inferred {
            Preferences.setBaseFolder(inferred, forDiffAt: url)
        }
        tab.selectedFileID = tab.files.first?.id
    }

    func presentBaseFolderPanel() {
        guard let tab = active, tab.content == .diff else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder the diff paths are relative to"
        panel.prompt = "Use Folder"
        panel.directoryURL = tab.baseFolder ?? tab.url.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            setBaseFolder(url)
        }
    }

    func setBaseFolder(_ url: URL) {
        guard let tab = active else { return }
        tab.baseFolder = url
        Preferences.setBaseFolder(url, forDiffAt: tab.url)
        tab.files = tab.files.map { entry in
            var updated = entry
            updated.resolvedOriginal = PathResolver.resolve(
                path: entry.diff.rawOldPath ?? entry.diff.rawNewPath ?? "", base: url)
            return updated
        }
        let missing = tab.files.filter { $0.originalURL == nil && $0.diff.kind != .added }.count
        statusMessage = missing == 0
            ? nil
            : "\(missing) of \(tab.files.count) original file\(tab.files.count == 1 ? "" : "s") "
              + "still not found in this folder."
        reloadSelectedFile()
    }

    func presentLocateOriginalPanel(for entryID: UUID) {
        guard let tab = active, let index = tab.files.firstIndex(where: { $0.id == entryID }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the original version of \(tab.files[index].diff.displayName)"
        panel.prompt = "Use File"
        panel.directoryURL = tab.baseFolder
        if panel.runModal() == .OK, let url = panel.url {
            tab.files[index].manualOriginal = url
            if tab.files[index].id == tab.selectedFileID { reloadSelectedFile() }
        }
    }

    // MARK: - Diff file selection

    func selectFile(_ id: UUID) {
        guard let tab = active, tab.selectedFileID != id else { return }
        tab.selectedFileID = id
        reloadSelectedFile()
        saveSession()
    }

    func selectAdjacentFile(offset: Int) {
        guard let tab = active, let selected = tab.selectedFileID,
              let index = tab.files.firstIndex(where: { $0.id == selected }) else { return }
        let next = index + offset
        guard tab.files.indices.contains(next) else { return }
        selectFile(tab.files[next].id)
    }

    func reloadSelectedFile(for requested: DocumentTab? = nil) {
        guard let tab = requested ?? active else { return }
        tab.loadTask?.cancel()
        tab.renderer.reset()
        tab.expandedFolds.removeAll()
        tab.matches = []
        tab.currentMatchIndex = 0
        guard let entry = tab.selectedEntry else {
            tab.loadState = .empty
            return
        }
        tab.loadState = .loading
        let query = searchQuery
        tab.loadTask = Task { [weak self, weak tab] in
            let result = await DiffPreparation.prepare(entry: entry)
            guard !Task.isCancelled, let tab else { return }
            tab.loadState = result
            if !query.isEmpty { self?.recomputeMatches() }
        }
    }

    // MARK: - Folds

    func toggleFold(_ fold: Fold) {
        guard let tab = active else { return }
        if tab.expandedFolds.contains(fold.id) {
            tab.expandedFolds.remove(fold.id)
        } else {
            tab.expandedFolds.insert(fold.id)
        }
    }

    func expandAllFolds() {
        guard let tab = active, let document = tab.loadedFile?.document else { return }
        tab.expandedFolds = Set(document.folds.map(\.id))
    }

    func collapseAllFolds() {
        active?.expandedFolds.removeAll()
    }

    // MARK: - Search

    /// Whether there is anything for ⌘F to search.
    ///
    /// Deliberately a question about what is *open*, not about what has finished
    /// loading. Asking `loadedFile` — which only ever holds a diff — disabled ⌘F for
    /// every Markdown document, and asking about load state would disable it for the
    /// seconds a large diff takes to prepare.
    var canFind: Bool {
        guard let tab = active else { return false }
        return tab.content != .none
    }

    /// Whether ⌘G has somewhere to go. The rendered page counts its own matches in
    /// JavaScript, so `matches` stays empty there.
    var canStepMatches: Bool {
        !matches.isEmpty || renderedMatchCount > 0
    }

    /// Shows the find bar and puts the caret in it, whether or not it was already open.
    func presentFind() {
        guard canFind else { return }
        isFindPresented = true
        findFocusRequest += 1
    }

    func dismissFind() {
        isFindPresented = false
        searchQuery = ""
        recomputeMatches()
    }

    /// True when ⌘F should be handled by JavaScript inside the rendered page.
    var searchesRenderedPage: Bool {
        guard let tab = active, !tab.isShowingComparison else { return false }
        return tab.content == .markdown && tab.readingMode == .rendered
    }

    func recomputeMatches() {
        guard let tab = active else { return }
        if searchesRenderedPage { return }
        // A document showing a comparison is a diff for search's purposes.
        if !tab.isShowingComparison, tab.content == .markdown || tab.content == .source {
            recomputeTextMatches()
            return
        }
        guard let document = tab.loadedFile?.document, !searchQuery.isEmpty else {
            setMatches([])
            return
        }
        let needle = Array(searchCaseSensitive ? searchQuery : searchQuery.lowercased())
        var found: [SearchMatch] = []
        for row in document.rows {
            if let left = row.left {
                for range in Self.occurrences(of: needle, in: left.text,
                                              caseSensitive: searchCaseSensitive) {
                    found.append(SearchMatch(rowIndex: row.id, isLeft: true, range: range))
                }
            }
            if let right = row.right {
                for range in Self.occurrences(of: needle, in: right.text,
                                              caseSensitive: searchCaseSensitive) {
                    found.append(SearchMatch(rowIndex: row.id, isLeft: false, range: range))
                }
            }
        }
        setMatches(found)
    }

    func setMatches(_ found: [SearchMatch]) {
        guard let tab = active else { return }
        tab.matches = found
        tab.currentMatchIndex = 0
        if !found.isEmpty { focusCurrentMatch() }
    }

    func advanceMatch(by offset: Int) {
        if searchesRenderedPage {
            focusRenderedMatch(offset: offset)
            return
        }
        guard let tab = active, !tab.matches.isEmpty else { return }
        tab.currentMatchIndex =
            (tab.currentMatchIndex + offset + tab.matches.count) % tab.matches.count
        focusCurrentMatch()
    }

    private func focusCurrentMatch() {
        guard let tab = active, let match = tab.currentMatch else { return }
        if let document = tab.loadedFile?.document {
            for fold in document.folds where fold.range.contains(match.rowIndex) {
                tab.expandedFolds.insert(fold.id)
            }
        }
        tab.scrollRequest += 1
    }

    nonisolated static func occurrences(of needle: [Character], in text: String,
                                        caseSensitive: Bool) -> [Range<Int>] {
        guard !needle.isEmpty else { return [] }
        let haystack = Array(caseSensitive ? text : text.lowercased())
        guard haystack.count >= needle.count else { return [] }
        var results: [Range<Int>] = []
        var index = 0
        let limit = haystack.count - needle.count
        outer: while index <= limit {
            for offset in 0..<needle.count where haystack[index + offset] != needle[offset] {
                index += 1
                continue outer
            }
            results.append(index..<(index + needle.count))
            index += needle.count
        }
        return results
    }
}

/// Small wrapper around UserDefaults for remembering where a diff's originals live.
enum Preferences {

    private static let baseFolderKey = "baseFolders"
    private static let automaticReloadKey = "reloadChangedFilesAutomatically"

    /// Whether a document with no unsaved edits is brought up to date on its own when
    /// something else writes the file. Defaults to on — a stale document that looks
    /// current is the worse of the two failures.
    static var automaticReload: Bool {
        get {
            UserDefaults.standard.object(forKey: automaticReloadKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: automaticReloadKey) }
    }

    static func baseFolder(forDiffAt url: URL) -> URL? {
        let map = UserDefaults.standard.dictionary(forKey: baseFolderKey) as? [String: String] ?? [:]
        guard let path = map[url.standardizedFileURL.path] else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func setBaseFolder(_ folder: URL, forDiffAt url: URL) {
        var map = UserDefaults.standard.dictionary(forKey: baseFolderKey) as? [String: String] ?? [:]
        map[url.standardizedFileURL.path] = folder.standardizedFileURL.path
        // Keep the map from growing forever.
        if map.count > 200 { map = [url.standardizedFileURL.path: folder.standardizedFileURL.path] }
        UserDefaults.standard.set(map, forKey: baseFolderKey)
    }
}
