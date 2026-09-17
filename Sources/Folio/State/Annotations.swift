import AppKit
import Foundation

/// Leaving notes and change requests against a document, and handing them to an assistant.
///
/// Nothing here writes to the document. An annotation records what was selected and which
/// lines it sits on; the file stays exactly as its author left it, which is the point when
/// the thing you are marking up is someone else's draft.
extension AppState {

    var annotations: [Annotation] { active?.annotations ?? [] }

    /// Whether there is a passage selected to annotate.
    func hasSelection(_ tab: DocumentTab) -> Bool {
        guard let selection = tab.pendingSelection else { return false }
        return !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Called by the rendered page as the selection changes.
    func selectionChanged(text: String, lineHint: Int?, for tabID: UUID? = nil) {
        let target = tabID.flatMap { id in tabs.first { $0.id == id } } ?? active
        guard let tab = target else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.pendingSelection = trimmed.isEmpty
            ? nil : PendingSelection(text: trimmed, lineHint: lineHint)
    }

    // MARK: - Writing one

    /// Opens the sheet for a new annotation against whatever is selected.
    func beginAnnotation(_ kind: Annotation.Kind, for requested: DocumentTab? = nil) {
        guard let tab = requested ?? active, hasSelection(tab) else {
            statusMessage = "Select the passage you want to annotate first."
            return
        }
        annotationDraft = AnnotationDraft(kind: kind,
                                          quote: tab.pendingSelection?.text ?? "",
                                          comment: "")
    }

    /// Records the annotation the sheet was filled in with.
    @discardableResult
    func commitAnnotationDraft(for requested: DocumentTab? = nil) -> Bool {
        guard let tab = requested ?? active, let draft = annotationDraft else { return false }
        let comment = draft.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty else { return false }

        let lines = TextNormalizer.splitLines(tab.currentText)
        // The selection is the truth; its line follows from it. The page's hint only
        // decides between repeats of the same wording.
        let range = AnnotationLocator.locate(selection: draft.quote, in: lines,
                                             hint: tab.pendingSelection?.lineHint)
            ?? (tab.pendingSelection?.lineHint).map { $0...$0 }
            ?? 0...0

        tab.annotations.append(Annotation(kind: draft.kind,
                                          quote: draft.quote,
                                          startLine: range.lowerBound,
                                          endLine: range.upperBound,
                                          comment: comment))
        annotationDraft = nil
        tab.sidebarMode = .notes
        tab.pageVersion += 1          // the page repaints with the passage marked
        saveSession()
        return true
    }

    func cancelAnnotationDraft() { annotationDraft = nil }

    func removeAnnotation(_ annotation: Annotation, for requested: DocumentTab? = nil) {
        guard let tab = requested ?? active else { return }
        tab.annotations.removeAll { $0.id == annotation.id }
        tab.pageVersion += 1
        saveSession()
    }

    func removeAllAnnotations(for requested: DocumentTab? = nil) {
        guard let tab = requested ?? active, !tab.annotations.isEmpty else { return }
        tab.annotations = []
        tab.pageVersion += 1
        saveSession()
        statusMessage = "Cleared every note and change request."
    }

    // MARK: - Handing them over

    /// The report, built against the document as it stands right now.
    func annotationReport(for requested: DocumentTab? = nil) -> String {
        guard let tab = requested ?? active, !tab.annotations.isEmpty else { return "" }
        return AnnotationReport.text(for: tab.annotations,
                                     file: tab.url,
                                     sourceLines: TextNormalizer.splitLines(tab.currentText),
                                     relativeTo: tab.git?.root)
    }

    func copyAnnotationReport(for requested: DocumentTab? = nil) {
        guard let tab = requested ?? active else { return }
        let report = annotationReport(for: tab)
        guard !report.isEmpty else {
            statusMessage = "Nothing to copy — no notes on \(tab.name) yet."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        statusMessage = "Copied \(AnnotationReport.summary(of: tab.annotations)) "
            + "Paste it to your assistant."
    }
}

/// The annotation being written, before it is recorded.
struct AnnotationDraft: Equatable {
    var kind: Annotation.Kind
    var quote: String
    var comment: String
}
