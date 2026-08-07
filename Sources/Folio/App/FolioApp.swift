import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct FolioApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared

    var body: some Scene {
        // A single Window, not a WindowGroup: Folio shows one document at a time, and
        // a WindowGroup mints an extra window every time Finder asks it to open a file.
        Window("Folio", id: "folio-main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 900, minHeight: 520)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { state.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Save") { state.saveActiveDocument() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save All") { state.saveAllDocuments() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Revert to Saved") { state.revertDraft() }
                Divider()
                Button("Reload from Disk") { state.reloadTextDocument() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Close Tab") { state.closeActiveTabAskingToSave() }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Close Other Tabs") { state.closeOtherTabs() }
            }
            CommandGroup(after: .newItem) {
                Button("Choose Base Folder…") { state.presentBaseFolderPanel() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            // Deliberately no `.disabled(...)` anywhere in these menus. A disabled item
            // swallows its keyboard shortcut, and the predicates do not re-evaluate
            // reliably inside `commands` — measured: with a document open, every guarded
            // item stayed disabled while unguarded ones worked. Each action guards itself
            // instead, so the shortcut always fires and the app decides what it means.
            CommandGroup(after: .textEditing) {
                Button("Find in Document") { state.presentFind() }
                    .keyboardShortcut("f", modifiers: .command)

                Button("Find Next") { state.advanceMatch(by: 1) }
                    .keyboardShortcut("g", modifiers: .command)

                Button("Find Previous") { state.advanceMatch(by: -1) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])

                Button("Hide Find Bar") { state.dismissFind() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            CommandMenu("Repository") {
                Button("Commit…") { state.presentCommitSheet() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Button("Push") { state.pushActiveDocument() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Divider()
                Button("Show History") { state.setSidebarMode(.history) }
                Button("Newer Commit") { state.stepThroughHistory(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Older Commit") { state.stepThroughHistory(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Back to the Document") { state.closeCommit() }
                Divider()
                Button("Refresh Status") { state.refreshGitStatus() }
            }
            CommandMenu("Document") {
                Button("Next Tab") { state.selectAdjacentTab(offset: 1) }
                    .keyboardShortcut("\t", modifiers: .control)
                Button("Previous Tab") { state.selectAdjacentTab(offset: -1) }
                    .keyboardShortcut("\t", modifiers: [.control, .shift])
                Divider()
                Button("Rendered") { state.setReadingMode(.rendered) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Source") { state.setReadingMode(.source) }
                    .keyboardShortcut("2", modifiers: .command)
                Divider()
                Button("Next File") { state.selectAdjacentFile(offset: 1) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Previous File") { state.selectAdjacentFile(offset: -1) }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
                Button(state.reloadsChangedFilesAutomatically
                       ? "Ask Before Reloading Changed Files"
                       : "Reload Changed Files Automatically") {
                    state.reloadsChangedFilesAutomatically.toggle()
                }
                Divider()
                Button(state.wrapLines ? "Scroll Long Lines" : "Wrap Long Lines") {
                    state.wrapLines.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Expand All Context") { state.expandAllFolds() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Collapse All Context") { state.collapseAllFolds() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("Set Folio as Default for Diffs") {
                    FileAssociation.setAsDefaultHandler(extensions: FileAssociation.diffExtensions)
                }
                Button("Set Folio as Default for Markdown") {
                    FileAssociation.setAsDefaultHandler(extensions: FileAssociation.markdownExtensions)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `build.sh --set-default` runs the app with this flag: Launch Services'
        // modern API only works from inside a registered app bundle, so the install
        // step borrows the app for a moment and then quits.
        if MenuDiagnostics.runIfRequested() { return }

        if CommandLine.arguments.contains(FileAssociation.setDefaultFlag) {
            FileAssociation.setAsDefaultHandler(logging: true) { succeeded in
                exit(succeeded ? 0 : 1)
            }
            return
        }

        // Put back what was open last time. A file opened from Finder arrives after
        // this and simply joins the restored tabs, or brings its own forward.
        AppState.shared.sessionRestoreEnabled = true
        AppState.shared.restoreSession()
    }

    /// Quitting with unsaved edits asks rather than losing them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.shared.confirmQuitWithUnsavedChanges()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Scroll positions move constantly and are only captured when the session is
        // written, so take one final snapshot.
        AppState.shared.saveSession()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in
            // Dispatcher, not openDiff: this is how Finder-opened Markdown arrives too.
            AppState.shared.open(at: url)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Registers Folio as the handler for the file types it can show.
///
/// `NSWorkspace.setDefaultApplication` only ever calls back from inside a registered
/// app bundle, which is why this lives in the app rather than in the install script.
/// Several of these extensions have no system content type — `.mdown`, `.mkd`, `.mdx`
/// resolve to dynamic `dyn.…` identifiers — so each extension is claimed individually
/// rather than relying on one shared UTI.
enum FileAssociation {

    static let setDefaultFlag = "--set-default-handler"
    static let diffExtensions = ["diff", "patch", "rej"]
    static let markdownExtensions = ["md", "markdown", "mdown", "mkd", "mdx", "mdc"]
    static var allExtensions: [String] { diffExtensions + markdownExtensions }

    @MainActor
    static func setAsDefaultHandler(extensions: [String]? = nil,
                                    logging: Bool = false,
                                    completion: ((Bool) -> Void)? = nil) {
        let extensions = extensions ?? allExtensions
        let appURL = Bundle.main.bundleURL
        var types: [UTType] = []
        for extensionName in extensions {
            if let type = UTType(filenameExtension: extensionName), !types.contains(type) {
                types.append(type)
            }
        }
        guard !types.isEmpty else {
            report("No content types are registered for these files — try relaunching the app.",
                   logging: logging)
            completion?(false)
            return
        }

        var pending = types.count
        var problems: [String] = []
        for type in types {
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
                Task { @MainActor in
                    if let error {
                        problems.append("\(type.identifier): \(error.localizedDescription)")
                        if logging { print("  ✗ \(type.identifier): \(error.localizedDescription)") }
                    } else if logging {
                        print("  ✓ \(type.identifier)")
                    }
                    pending -= 1
                    if pending == 0 {
                        finish(extensions: extensions, problems: problems,
                               logging: logging, completion: completion)
                    }
                }
            }
        }

        // Launch Services sometimes applies the change without ever calling back, so
        // stop waiting after a few seconds — the probe below is the real verdict.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard pending > 0 else { return }
            pending = 0
            problems.append("Launch Services did not respond.")
            finish(extensions: extensions, problems: problems,
                   logging: logging, completion: completion)
        }
    }

    @MainActor
    private static func finish(extensions: [String], problems: [String], logging: Bool,
                               completion: ((Bool) -> Void)?) {
        var stuck: [String] = []
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("folio-verify", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        for extensionName in extensions {
            let probe = scratch.appendingPathComponent("probe.\(extensionName)")
            try? Data().write(to: probe)
            // Launch Services writes the binding asynchronously and this process holds a
            // cached answer for a moment, so ask a few times before believing a "no".
            var handler: URL?
            var isUs = false
            for attempt in 0..<6 {
                handler = NSWorkspace.shared.urlForApplication(toOpen: probe)
                isUs = handler?.standardizedFileURL.path == Bundle.main.bundleURL.path
                if isUs { break }
                if attempt < 5 { Thread.sleep(forTimeInterval: 0.35) }
            }
            if logging {
                print("  \(isUs ? "✓" : "✗") .\(extensionName) opens with \(handler?.lastPathComponent ?? "nothing")")
            }
            if !isUs { stuck.append(".\(extensionName)") }
        }
        try? FileManager.default.removeItem(at: scratch)

        if stuck.isEmpty {
            report("Folio now opens "
                   + extensions.map { ".\($0)" }.joined(separator: ", ") + " files.",
                   logging: logging)
        } else {
            report("Could not take over \(stuck.joined(separator: ", ")) — another app owns "
                   + "\(stuck.count == 1 ? "it" : "them"). Set it in Finder: select the file, ⌘I, "
                   + "Open with → Folio → Change All…", logging: logging)
        }
        completion?(stuck.isEmpty)
    }

    @MainActor
    private static func report(_ message: String, logging: Bool) {
        if logging {
            print("  " + message)
        } else {
            AppState.shared.statusMessage = message
        }
    }
}
