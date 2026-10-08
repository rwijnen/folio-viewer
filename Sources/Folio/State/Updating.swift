import AppKit
import Foundation

/// Checking for, downloading and installing a newer Folio.
///
/// Folio goes online for this only when the reader asked: from Folio ▸ Check for
/// Updates…, or at launch once they have said yes to that — the question is put once,
/// and until it is answered nothing is fetched. An update is installed only after the
/// reader chooses to, and only once the download matches its published checksum, is
/// Folio at the version promised, and passes `codesign --verify`.
extension AppState {

    /// Fetches a URL. Replaced in tests; the real one never sends cookies or credentials.
    typealias UpdateFetcher = @Sendable (URL) async throws -> Data

    nonisolated static let liveFetcher: UpdateFetcher = { url in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        if url.host == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// The version this copy reports.
    static var runningVersion: Updates.Version {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(Updates.Version.init) ?? Updates.Version("0.0.0")!
    }

    // MARK: - Launch

    /// Called once the session is restored. Asks the one-time question, or checks
    /// quietly if the reader already said yes.
    func updatesAtLaunch() {
        switch Updates.launchAction(checksAtLaunch: checksForUpdatesAtLaunch) {
        case .nothing:
            return
        case .check:
            Task { await checkForUpdates(manual: false) }
        case .ask:
            // After the window is up, so the question does not stand in front of an
            // empty screen on the first launch.
            Task {
                try? await Task.sleep(for: .seconds(1))
                let yes = AppState.askToCheckAtLaunch()
                checksForUpdatesAtLaunch = yes
                if yes { await checkForUpdates(manual: false) }
            }
        }
    }

    static func askToCheckAtLaunch() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Check for updates when Folio starts?"
        alert.informativeText = """
            Folio can look for a newer version each time it starts. That means one \
            request to GitHub (api.github.com) for the latest release of Folio — nothing \
            about you or your documents is sent. If you say no, Folio stays offline, and \
            you can still check by hand from Folio ▸ Check for Updates….

            You can change this later in the Folio menu.
            """
        alert.addButton(withTitle: "Check Automatically")
        alert.addButton(withTitle: "Don't Check")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Checking

    /// Looks for a newer release. A manual check reports every outcome, including
    /// "you're up to date" and failures; a launch check speaks only when there is
    /// something to install, so an offline start is not interrupted.
    func checkForUpdates(manual: Bool, fetch: UpdateFetcher = AppState.liveFetcher) async {
        guard updateActivity == nil else { return }
        updateActivity = "Checking for updates…"
        defer { if updateActivity == "Checking for updates…" { updateActivity = nil } }

        let available: Updates.Available?
        do {
            let release = try Updates.decodeRelease(try await fetch(Updates.latestReleaseURL))
            available = try Updates.available(in: release, current: AppState.runningVersion)
        } catch {
            if manual { AppState.tellUpdateProblem("Couldn't check for updates", error) }
            return
        }

        guard let available else {
            if manual { AppState.tellUpToDate(AppState.runningVersion) }
            return
        }
        guard Updates.shouldOffer(available, skipped: Preferences.skippedUpdateVersion, manual: manual)
        else { return }

        updateActivity = nil
        switch AppState.offerUpdate(available, current: AppState.runningVersion) {
        case .install:
            await installUpdate(available, fetch: fetch)
        case .later:
            break
        case .skip:
            Preferences.skippedUpdateVersion = available.version.description
        }
    }

    enum UpdateChoice { case install, later, skip }

    static func offerUpdate(_ available: Updates.Available, current: Updates.Version) -> UpdateChoice {
        let alert = NSAlert()
        alert.messageText = "Folio \(available.version) is available"
        alert.informativeText = """
            You have \(current). Folio can download the new version, check it against \
            its published checksum, replace this copy and relaunch. If you have unsaved \
            changes, you will be asked about them first.
            """
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        // The help button opens the release page without answering the question.
        let helper = ReleasePageOpener(page: available.page)
        alert.showsHelp = true
        alert.delegate = helper
        switch withExtendedLifetime(helper, { alert.runModal() }) {
        case .alertFirstButtonReturn: return .install
        case .alertThirdButtonReturn: return .skip
        default: return .later
        }
    }

    static func tellUpdateProblem(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    static func tellUpToDate(_ version: Updates.Version) {
        let alert = NSAlert()
        alert.messageText = "Folio is up to date"
        alert.informativeText = "\(version) is the latest version."
        alert.runModal()
    }

    // MARK: - Installing

    func installUpdate(_ available: Updates.Available, fetch: UpdateFetcher = AppState.liveFetcher) async {
        let installed = Bundle.main.bundleURL
        guard installed.pathExtension == "app" else {
            // Running from `swift run` or a test: there is no bundle to replace.
            NSWorkspace.shared.open(available.page)
            return
        }
        updateActivity = "Downloading Folio \(available.version)…"
        defer { updateActivity = nil }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let archive = workspace.appendingPathComponent(Updates.archiveName)
            try await fetch(available.archive).write(to: archive)
            let checksum = String(decoding: try await fetch(available.checksum), as: UTF8.self)

            updateActivity = "Checking Folio \(available.version)…"
            try Updates.verify(archive: archive, checksumFile: checksum)

            let unpacked = workspace.appendingPathComponent("unpacked", isDirectory: true)
            try await AppState.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
            let newApp = unpacked.appendingPathComponent("Folio.app")
            try Updates.validateBundle(at: newApp, expecting: available.version)
            do {
                try await AppState.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
            } catch {
                throw Updates.UpdateError.notAnApp("its code signature does not verify.")
            }

            updateActivity = "Installing Folio \(available.version)…"
            try Updates.replace(installed: installed, with: newApp)
        } catch {
            AppState.tellUpdateProblem("Folio \(available.version) was not installed", error)
            return
        }

        Preferences.skippedUpdateVersion = nil
        relaunchAfterUpdate = true
        NSApp.terminate(nil)
        // Still here: the reader cancelled the quit over unsaved changes. The new copy is
        // already in place, so the next launch is the new version.
        relaunchAfterUpdate = false
        let alert = NSAlert()
        alert.messageText = "Folio \(available.version) is installed"
        alert.informativeText = "It starts the next time you open Folio."
        alert.runModal()
    }

    /// Opens the freshly installed copy once this process has exited. Called from
    /// `applicationWillTerminate`, so it only happens when the quit really goes ahead.
    func relaunchIfUpdated() {
        guard relaunchAfterUpdate else { return }
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                            "folio-relaunch", String(ProcessInfo.processInfo.processIdentifier),
                            Bundle.main.bundleURL.path]
        try? waiter.run()
    }

    /// Runs a system tool, throwing when it fails.
    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: Updates.UpdateError.notAnApp(
                        "\(URL(fileURLWithPath: tool).lastPathComponent) failed."))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// Lets the update alert's help button open the release page.
private final class ReleasePageOpener: NSObject, NSAlertDelegate {
    let page: URL
    init(page: URL) { self.page = page }
    func alertShowHelp(_ alert: NSAlert) -> Bool {
        NSWorkspace.shared.open(page)
        return true
    }
}
