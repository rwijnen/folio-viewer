import AppKit
import SwiftUI

/// The Markdown source editor.
///
/// A real `NSTextView` rather than SwiftUI's `TextEditor`, because editing prose needs
/// the things AppKit already has: undo, find, selection behaviour, a ruler for line
/// numbers, and attributes applied to live text for syntax colouring.
struct MarkdownEditorView: NSViewRepresentable {

    @Environment(AppState.self) private var state
    let tab: DocumentTab
    /// Bumped when the text should be replaced from outside — a save, a revert, a
    /// reload from disk — as opposed to the reader typing.
    let version: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab, state: state)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true
        textView.font = Coordinator.editorFont
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        context.coordinator.ruler = ruler
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        textView.string = tab.currentText
        context.coordinator.applyHighlighting()
        context.coordinator.restoreScrollOffset()
        context.coordinator.observeScrolling()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.tab = tab
        coordinator.state = state
        guard let textView = coordinator.textView else { return }

        if coordinator.appliedVersion != version {
            coordinator.appliedVersion = version
            let text = tab.currentText
            if textView.string != text {
                let selected = textView.selectedRange()
                textView.string = text
                textView.setSelectedRange(NSRange(location: min(selected.location, text.utf16.count),
                                                  length: 0))
                coordinator.applyHighlighting()
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        static let editorFont = NSFont.monospacedSystemFont(ofSize: Theme.fontSize, weight: .regular)

        var tab: DocumentTab
        var state: AppState
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        weak var ruler: LineNumberRuler?
        var appliedVersion = 0
        private var highlightWorkItem: DispatchWorkItem?
        private var scrollObservation: NSObjectProtocol?
        private var isRestoringScroll = false

        init(tab: DocumentTab, state: AppState) {
            self.tab = tab
            self.state = state
            self.appliedVersion = tab.editorVersion
        }

        deinit {
            if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
        }

        // MARK: Typing

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            state.updateDraft(textView.string, for: tab)
            ruler?.needsDisplay = true
            scheduleHighlighting()
        }

        /// Colouring the whole document on every keystroke is wasteful, so it settles
        /// briefly first. The delay is short enough not to be noticed while typing.
        private func scheduleHighlighting() {
            highlightWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.applyHighlighting() }
            }
            highlightWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }

        func applyHighlighting() {
            guard let textView, let storage = textView.textStorage else { return }
            let text = textView.string
            let lines = TextNormalizer.splitLines(text)
            guard lines.count <= SyntaxHighlighter.maxLines else { return }
            let spans = MarkdownSyntax.spans(for: lines)

            storage.beginEditing()
            let whole = NSRange(location: 0, length: storage.length)
            storage.setAttributes([.font: Self.editorFont,
                                   .foregroundColor: NSColor(Theme.codeText)], range: whole)
            var lineStart = 0
            let characters = Array(text)
            for (index, line) in lines.enumerated() {
                let lineLength = line.count
                if spans.indices.contains(index) {
                    for span in spans[index] {
                        let from = lineStart + max(0, span.range.lowerBound)
                        let to = lineStart + min(lineLength, span.range.upperBound)
                        guard from < to, to <= characters.count else { continue }
                        // Character offsets to UTF-16, which is what NSTextStorage wants.
                        let prefix = String(characters[0..<from]).utf16.count
                        let length = String(characters[from..<to]).utf16.count
                        guard prefix + length <= storage.length else { continue }
                        storage.addAttribute(.foregroundColor,
                                             value: NSColor(Theme.color(for: span.kind)),
                                             range: NSRange(location: prefix, length: length))
                    }
                }
                lineStart += lineLength + 1   // the newline
            }
            storage.endEditing()
        }

        // MARK: Scrolling

        func observeScrolling() {
            guard let clipView = scrollView?.contentView else { return }
            clipView.postsBoundsChangedNotifications = true
            scrollObservation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isRestoringScroll, let clip = self.scrollView?.contentView
                    else { return }
                    self.tab.scrollOffsets.record(clip.bounds.origin.y, for: "markdown-source")
                }
            }
        }

        func restoreScrollOffset() {
            let target = tab.scrollOffsets.offset(for: "markdown-source")
            guard target > 1, let scrollView else { return }
            isRestoringScroll = true
            scrollView.layoutSubtreeIfNeeded()
            let reachable = max((scrollView.documentView?.bounds.height ?? 0)
                                - scrollView.contentView.bounds.height, 0)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: min(target, reachable)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isRestoringScroll = false
        }
    }
}

/// Line numbers down the left of the editor.
final class LineNumberRuler: NSRulerView {

    private weak var editor: NSTextView?

    init(textView: NSTextView) {
        editor = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Theme.gutterWidth
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor,
              let layoutManager = editor.layoutManager,
              let container = editor.textContainer else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: Theme.fontSize - 1, weight: .regular),
            .foregroundColor: NSColor(Theme.gutterText),
        ]
        let visible = editor.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                          actualGlyphRange: nil)
        let text = editor.string as NSString

        // Count the newlines before the first visible line once, then walk forward.
        var lineNumber = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: characterRange.location),
                                 options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            lineNumber += 1
        }

        var index = characterRange.location
        while index < NSMaxRange(characterRange) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange,
                                                  actualCharacterRange: nil)
            var fragment = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            fragment.origin.y += editor.textContainerInset.height - visible.origin.y

            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6,
                                   y: fragment.origin.y),
                       withAttributes: attributes)

            lineNumber += 1
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
    }
}
