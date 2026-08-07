import AppKit
import Foundation

/// Editing and saving Markdown.
///
/// Folio is a viewer that gained one writing path, and it is kept deliberately narrow:
/// only Markdown, only its source mode, only ever the file you are editing, and only
/// when you ask. Nothing is auto-saved, and nothing is written on quit without saying so.
extension AppState {

    // MARK: - Typing

    /// Called by the editor as the text changes. Cheap on purpose — the expensive
    /// re-parse waits until the preview is needed or the file is saved.
    func updateDraft(_ text: String, for tab: DocumentTab) {
        guard tab.isEditable else { return }
        tab.draftText = text
    }

    /// Throws away unsaved edits and shows the file as it is on disk.
    func revertDraft(for tab: DocumentTab? = nil) {
        guard let tab = tab ?? active, tab.isDirty else { return }
        tab.draftText = nil
        tab.editorVersion += 1
        refreshDocument(for: tab)
        statusMessage = "Reverted \(tab.name) to the version on disk."
    }

    /// Re-parses the edited text so the preview, the outline and the source colouring
    /// catch up. Does not touch the file.
    func refreshDocument(for tab: DocumentTab) {
        guard let existing = tab.textDocument else { return }
        var document = AppState.makeTextDocument(from: tab.currentText,
                                             at: tab.url,
                                             asMarkdown: existing.isMarkdown,
                                             encoding: existing.encoding,
                                             modificationDate: existing.modificationDate)
        document.rawText = existing.rawText   // the saved text stays the baseline
        document.contentVersion = existing.contentVersion + 1
        tab.textDocument = document
        tab.pageCache = nil
        tab.pageVersion += 1
        tab.renderer.reset()
        // Headings may have come and gone; drop folds that no longer point anywhere.
        let known = Set(document.outline.map(\.id))
        tab.collapsedOutline.formIntersection(known)
    }

    // MARK: - Saving

    var canSave: Bool { active?.isDirty == true }

    /// Whether the file changed underneath us since it was read.
    func fileChangedOnDisk(for tab: DocumentTab) -> Bool {
        guard let recorded = tab.textDocument?.modificationDate,
              let current = AppState.modificationDate(of: tab.url) else { return false }
        // A second of slack: some tools rewrite with a coarse timestamp.
        return abs(current.timeIntervalSince(recorded)) > 1
    }

    /// Writes the edited text back to its file.
    @discardableResult
    func saveActiveDocument(confirmingOverwrite: @MainActor (String) -> Bool = AppState.askToOverwrite)
        -> Bool {
        guard let tab = active else { return false }
        return save(tab, confirmingOverwrite: confirmingOverwrite)
    }

    @discardableResult
    func save(_ tab: DocumentTab,
              confirmingOverwrite: @MainActor (String) -> Bool = AppState.askToOverwrite) -> Bool {
        guard tab.isEditable, tab.isDirty, let document = tab.textDocument else { return false }

        if fileChangedOnDisk(for: tab) {
            let message = "\(tab.name) has changed on disk since you opened it. "
                + "Saving will replace those changes with yours."
            guard confirmingOverwrite(message) else {
                statusMessage = "\(tab.name) was not saved."
                return false
            }
        }

        let text = tab.currentText
        do {
            try TextNormalizer.write(text, to: tab.url, encoding: document.encoding)
        } catch {
            errorMessage = "Could not save \(tab.name): \(error.localizedDescription)"
            return false
        }

        // What is on disk is the new baseline, so the document is no longer dirty.
        var saved = AppState.makeTextDocument(from: text, at: tab.url,
                                          asMarkdown: document.isMarkdown,
                                          encoding: document.encoding,
                                          modificationDate: AppState.modificationDate(of: tab.url))
        saved.contentVersion = document.contentVersion + 1
        tab.textDocument = saved
        tab.draftText = nil
        tab.pageCache = nil
        tab.pageVersion += 1
        tab.renderer.reset()
        tab.collapsedOutline.formIntersection(Set(saved.outline.map(\.id)))
        statusMessage = "Saved \(tab.name)."
        return true
    }

    /// Saves everything with unsaved changes, and says how many.
    @discardableResult
    func saveAllDocuments(confirmingOverwrite: @MainActor (String) -> Bool = AppState.askToOverwrite) -> Int {
        var saved = 0
        for tab in tabs where tab.isDirty {
            if save(tab, confirmingOverwrite: confirmingOverwrite) { saved += 1 }
        }
        if saved > 0 { statusMessage = "Saved \(saved) document\(saved == 1 ? "" : "s")." }
        return saved
    }

    var dirtyTabs: [DocumentTab] { tabs.filter(\.isDirty) }

    // MARK: - Prompts

    /// What to do about unsaved changes when something is about to close.
    enum UnsavedDecision {
        case save
        case discard
        case cancel
    }

    static func askToOverwrite(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Overwrite the newer file?"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func askToDiscard(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard your changes to \(name)?"
        alert.informativeText = "Reloading replaces what you have typed with the file on disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard and Reload")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func askAboutUnsaved(_ what: String) -> UnsavedDecision {
        let alert = NSAlert()
        alert.messageText = "Save changes to \(what)?"
        alert.informativeText = "Your changes will be lost if you do not save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    @discardableResult
    func closeActiveTabAskingToSave() -> Bool {
        guard let activeTabID else { return false }
        return closeTabAskingToSave(activeTabID)
    }

    /// Quitting with unsaved documents: save them, drop them, or stay.
    func confirmQuitWithUnsavedChanges(
        decide: @MainActor (String) -> UnsavedDecision = AppState.askAboutUnsaved
    ) -> NSApplication.TerminateReply {
        let unsaved = dirtyTabs
        guard !unsaved.isEmpty else { return .terminateNow }
        let what = unsaved.count == 1
            ? unsaved[0].name
            : "\(unsaved.count) documents"
        switch decide(what) {
        case .cancel:
            return .terminateCancel
        case .discard:
            return .terminateNow
        case .save:
            for tab in unsaved where !save(tab) { return .terminateCancel }
            return .terminateNow
        }
    }

    /// Closing a tab that has unsaved edits asks first. Returns false when the reader
    /// cancelled, so the caller leaves the tab alone.
    @discardableResult
    func closeTabAskingToSave(_ id: UUID,
                              decide: @MainActor (String) -> UnsavedDecision = AppState.askAboutUnsaved,
                              confirmingOverwrite: @MainActor (String) -> Bool = AppState.askToOverwrite)
        -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }) else { return false }
        if tab.isDirty {
            switch decide(tab.name) {
            case .cancel:
                return false
            case .save:
                guard save(tab, confirmingOverwrite: confirmingOverwrite) else { return false }
            case .discard:
                break
            }
        }
        closeTab(id)
        return true
    }
}
