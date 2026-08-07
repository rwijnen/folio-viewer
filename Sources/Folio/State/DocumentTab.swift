import Foundation
import Observation

/// One row of the file sidebar: the parsed diff entry plus where its original lives.
struct FileEntry: Identifiable {
    var id: UUID { diff.id }
    var diff: FileDiff
    var resolvedOriginal: URL?
    /// Set by the user through "Locate Original…" and preferred over path resolution.
    var manualOriginal: URL?

    var originalURL: URL? { manualOriginal ?? resolvedOriginal }
}

/// Fully prepared content for the currently selected file of a diff.
struct LoadedFile {
    var document: SideBySideDocument
    var leftSpans: [[SyntaxSpan]]
    var rightSpans: [[SyntaxSpan]]
    var languageName: String
    var originalURL: URL?
    /// Why we are showing diff-only content, if we are.
    var degradedReason: String?
    /// Something the user should know that is not a problem (reversed patch, etc.).
    var notice: String?
    /// True when the left panel was rebuilt from the diff rather than read from disk.
    var leftIsReconstructed = false
}

enum FileLoadState {
    case empty
    case loading
    case loaded(LoadedFile)
    case failed(String)
}

struct SearchMatch: Equatable {
    var rowIndex: Int
    var isLeft: Bool
    var range: Range<Int>
}

/// What kind of thing a tab holds.
enum DocumentContent: Equatable {
    case none
    /// A unified diff: the split view with a file sidebar.
    case diff
    /// A Markdown document: rendered or source.
    case markdown
    /// Any other text file: source only.
    case source
}

/// What the detail pane is showing for a document.
enum PaneContent: Equatable {
    /// The document itself — rendered, source, or the editor.
    case document
    /// One commit out of its history, side by side.
    case commit(GitCommitSummary)
    /// What something else wrote to the file, against what this tab holds.
    case externalChange
    /// Everything not yet committed: the last commit against what you have now.
    case workingChanges
}

/// Something else changed the file while it was open here.
enum ExternalChange: Equatable {
    /// The text now on disk, which differs from what this tab was built from.
    case changed(String)
    /// The file is no longer there.
    case removed
}

/// What the document sidebar is listing.
enum SidebarMode: String, CaseIterable, Identifiable {
    case outline
    case history

    var id: String { rawValue }
    var label: String { self == .outline ? "Outline" : "History" }
    var symbol: String { self == .outline ? "list.bullet.indent" : "clock.arrow.circlepath" }
}

enum HistoryState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// Rendered or raw, for Markdown documents.
enum ReadingMode: String, CaseIterable, Identifiable {
    case rendered
    case source

    var id: String { rawValue }
    var label: String { self == .rendered ? "Rendered" : "Source" }
    var symbol: String { self == .rendered ? "doc.richtext" : "chevron.left.forwardslash.chevron.right" }
}

/// A Markdown or plain-text document, prepared for both display modes.
struct TextDocument {
    var url: URL
    /// Exactly what is in the file — tabs intact — which is what the editor edits and
    /// what gets written back. `lines` below is the tab-expanded view of it.
    var rawText: String = ""
    var encoding: String.Encoding = .utf8
    /// Display lines for source mode (tabs expanded).
    var lines: [String]
    var spans: [[SyntaxSpan]]
    var languageName: String
    var isMarkdown: Bool
    /// Converted markdown body, wrapped into a full page on demand.
    var bodyHTML: String = ""
    var outline: [OutlineItem] = []
    var diagramCount: Int = 0
    var maxColumns: Int = 0
    /// Bumped whenever the body changes, so the web view knows to reload.
    var contentVersion: Int = 0

    var name: String { url.lastPathComponent }
    var folder: URL { url.deletingLastPathComponent() }
}

enum DisplayItem: Identifiable {
    case row(Int)
    case fold(Fold)

    var id: String {
        switch self {
        case let .row(index): return "r\(index)"
        case let .fold(fold): return "f\(fold.id)"
        }
    }
}

/// Everything belonging to one open document.
///
/// Folio keeps several of these and shows one at a time, so folds, reading mode,
/// scroll position, search results and the render cache all have to live per document
/// rather than on `AppState` — switching tabs must not disturb the others.
@MainActor
@Observable
final class DocumentTab: Identifiable {

    let id = UUID()
    /// The file this tab was opened from.
    var url: URL
    var content: DocumentContent

    // MARK: Diff documents

    var files: [FileEntry] = []
    var preamble: [String] = []
    var baseFolder: URL?
    var selectedFileID: UUID?
    var loadState: FileLoadState = .empty
    var expandedFolds: Set<Int> = []

    // MARK: Text documents

    var textDocument: TextDocument?
    var readingMode: ReadingMode = .rendered
    /// Bumped when the rendered page must be rebuilt (content or appearance change).
    var pageVersion = 0
    var diagramReport: String?
    /// Heading currently at the top of the rendered page.
    var visibleAnchor: String = ""
    /// Headings whose contents are folded away in the outline sidebar.
    var collapsedOutline: Set<String> = []

    // MARK: Editing

    /// The edited text, once it differs from what was read. nil means untouched.
    var draftText: String?
    /// Bumped when the editor should take its text from the document again — after a
    /// save, a revert or a reload — rather than from what the reader has typed.
    var editorVersion = 0
    /// True while there is something to save.
    var isDirty: Bool { draftText != nil && draftText != textDocument?.rawText }
    /// Only Markdown is editable for now; diffs are a view of two other files, and
    /// other source files are left alone deliberately.
    var isEditable: Bool { content == .markdown }
    /// What the editor should show, and what a save would write.
    var currentText: String { draftText ?? textDocument?.rawText ?? "" }

    // MARK: History

    /// Which list the document sidebar is showing.
    var sidebarMode: SidebarMode = .outline
    var history: [GitCommitSummary] = []
    var historyState: HistoryState = .idle
    /// What the detail pane is showing. A comparison replaces the document rather than
    /// opening a tab, so the sidebar stays beside it to move through.
    var pane: PaneContent = .document
    /// The commit being shown, for the many places that only care about that case.
    var viewingCommit: GitCommitSummary? {
        if case let .commit(commit) = pane { return commit }
        return nil
    }
    var isShowingComparison: Bool { pane != .document }

    /// Set when something else wrote the file while this tab had it open.
    var externalChange: ExternalChange?
    @ObservationIgnored var watcher: FileWatcher?
    @ObservationIgnored var historyTask: Task<Void, Never>?
    @ObservationIgnored var commitTask: Task<Void, Never>?

    // MARK: Version control

    /// What git said about this document at the last refresh. nil when it is not in a
    /// repository, or has not been looked at yet.
    var git: GitSnapshot?
    /// What git is doing right now — "Committing…" — or nil when it is doing nothing.
    var gitActivity: String?
    /// Bumped on every refresh so a slow answer cannot overwrite a newer one.
    @ObservationIgnored var gitRefreshToken = 0

    // MARK: Search, per document

    var matches: [SearchMatch] = []
    var currentMatchIndex = 0
    /// Bumped whenever the view should scroll to the current match.
    var scrollRequest = 0
    var renderedMatchCount = 0
    var renderedMatchIndex = -1
    var renderedFocusRequest = 0
    var renderedFocusTarget = 0
    var pendingAnchor: String?
    var anchorRequest = 0
    var sourceScrollLine: Int?
    var sourceScrollRequest = 0

    /// Attributed-line cache for the diff and source views.
    let renderer = LineRenderer()
    /// Where each of this document's scroll views was left.
    @ObservationIgnored let scrollOffsets = ScrollOffsetStore()
    /// Last scroll offset reported by the rendered page, replayed after a reload.
    @ObservationIgnored var webScrollOffset: CGFloat = 0
    /// The live web view for this document, created on first display.
    @ObservationIgnored private(set) var page: MarkdownPageController?
    /// Bumped every time this tab is shown, so the least recently used pages can go.
    @ObservationIgnored var lastShownAt: Int = 0
    /// Set on a tab restored from a saved session whose file has not been read yet.
    /// Holds what to apply once it is.
    @ObservationIgnored var pendingRestore: Session.Entry?
    var isPending: Bool { pendingRestore != nil }
    /// The wrapped page is ~3.5 MB with mermaid inlined, so build it only when it changes.
    @ObservationIgnored var pageCache: (version: Int, html: String)?
    @ObservationIgnored private var cachedOutlineLayout: OutlineLayout?
    @ObservationIgnored private var cachedOutlineCount = -1
    @ObservationIgnored private var cachedOutlineFirst: String?
    @ObservationIgnored var loadTask: Task<Void, Never>?

    init(url: URL, content: DocumentContent) {
        self.url = url
        self.content = content
    }

    // MARK: - Identity

    var name: String { textDocument?.name ?? url.lastPathComponent }

    var symbol: String {
        switch content {
        case .diff: return "arrow.left.arrow.right.square"
        case .markdown: return "doc.richtext"
        case .source: return "doc.plaintext"
        case .none: return "doc"
        }
    }

    var isMarkdown: Bool { textDocument?.isMarkdown == true }

    // MARK: - Derived

    var selectedEntry: FileEntry? {
        guard let selectedFileID else { return nil }
        return files.first { $0.id == selectedFileID }
    }

    var loadedFile: LoadedFile? {
        if case let .loaded(file) = loadState { return file }
        return nil
    }

    var totalAdditions: Int { files.reduce(0) { $0 + $1.diff.additions } }
    var totalDeletions: Int { files.reduce(0) { $0 + $1.diff.deletions } }

    var currentMatch: SearchMatch? {
        matches.indices.contains(currentMatchIndex) ? matches[currentMatchIndex] : nil
    }

    /// Rows to render, with closed folds collapsed into a single marker.
    var displayItems: [DisplayItem] {
        guard let document = loadedFile?.document else { return [] }
        var items: [DisplayItem] = []
        let closedFolds = document.folds
            .filter { !expandedFolds.contains($0.id) }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        var foldIterator = closedFolds.makeIterator()
        var nextFold = foldIterator.next()
        var index = 0
        while index < document.rows.count {
            if let fold = nextFold, fold.range.lowerBound == index {
                items.append(.fold(fold))
                index = fold.range.upperBound
                nextFold = foldIterator.next()
                continue
            }
            items.append(.row(index))
            index += 1
        }
        return items
    }

    /// Full HTML for the rendered Markdown view; nil unless this tab holds Markdown.
    func renderedPage(isDark: Bool) -> String? {
        guard let document = textDocument, document.isMarkdown else { return nil }
        if let cache = pageCache, cache.version == pageVersion { return cache.html }
        let html = HTMLPage.wrap(body: document.bodyHTML,
                                 title: document.name,
                                 isDark: isDark,
                                 mermaidScript: WebResources.mermaid,
                                 diagramCount: document.diagramCount)
        pageCache = (pageVersion, html)
        return html
    }

    /// Changes exactly when the web view needs to reload.
    var renderedPageToken: String {
        guard let document = textDocument else { return "none" }
        return "\(id.uuidString)|\(document.url.path)|\(document.contentVersion)|\(pageVersion)"
    }

    /// The outline as a tree. Rebuilt only when the document changes, since the sidebar
    /// asks for it on every redraw.
    var outlineLayout: OutlineLayout {
        let outline = textDocument?.outline ?? []
        if let cached = cachedOutlineLayout, cachedOutlineCount == outline.count,
           cachedOutlineFirst == outline.first?.id {
            return cached
        }
        let layout = OutlineLayout(outline)
        cachedOutlineLayout = layout
        cachedOutlineCount = outline.count
        cachedOutlineFirst = outline.first?.id
        return layout
    }

    /// The controller for the rendered page, created the first time it is needed.
    func pageController(state: AppState) -> MarkdownPageController {
        if let page { return page }
        let controller = MarkdownPageController(tab: self, state: state)
        page = controller
        state.pageBecameLive(self)
        return controller
    }

    /// Drops the live web view. The page keeps reporting its scroll offset as the
    /// reader scrolls, so a later reload can put them back where they were.
    func releasePage() {
        page?.teardown()
        page = nil
    }

    /// Scroll-memory key for whatever this tab is currently showing.
    var scrollKey: String {
        switch content {
        case .diff:
            return "diff:\(selectedFileID?.uuidString ?? "none")"
        case .markdown:
            return readingMode == .source ? "markdown-source" : "markdown-rendered"
        case .source:
            return "source"
        case .none:
            return "none"
        }
    }

    func searchRanges(inRow row: Int, isLeft: Bool) -> [Range<Int>] {
        guard !matches.isEmpty else { return [] }
        return matches.filter { $0.rowIndex == row && $0.isLeft == isLeft }.map(\.range)
    }
}
