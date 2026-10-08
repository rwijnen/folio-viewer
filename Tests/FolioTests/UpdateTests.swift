import Foundation
import Testing

@testable import Folio

/// Updating replaces the app with code fetched from the network, so every gate between
/// the download and the swap is pinned here: which release counts as newer, where it may
/// come from, the checksum, what the bundle must say about itself, and that a failed swap
/// leaves the old copy in place.
@Suite("Updates")
struct UpdateTests {

    private func version(_ text: String) -> Updates.Version { Updates.Version(text)! }

    private func release(tag: String = "v2.5.0", draft: Bool = false, prerelease: Bool = false,
                         assets: [(String, String)]? = nil) -> Updates.Release {
        let base = "https://github.com/rwijnen/folio-viewer/releases/download/\(tag)/"
        let list = assets ?? [("Folio.app.zip", base + "Folio.app.zip"),
                              ("Folio.app.zip.sha256", base + "Folio.app.zip.sha256")]
        return Updates.Release(
            tagName: tag,
            htmlURL: URL(string: "https://github.com/rwijnen/folio-viewer/releases/tag/\(tag)")!,
            draft: draft, prerelease: prerelease,
            assets: list.map { .init(name: $0.0, browserDownloadURL: URL(string: $0.1)!) })
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-update-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Versions

    @Test func comparesVersionsNumerically() {
        #expect(version("2.10.0") > version("2.9.9"))
        #expect(version("v2.4.0") == version("2.4"))
        #expect(version("2.4.1") > version("2.4"))
        #expect(version("3") > version("2.99.99"))
        #expect(Updates.Version("2.4.0-beta") == nil)
        #expect(Updates.Version("") == nil)
        #expect(version("v2.4.0").description == "2.4.0")
    }

    // MARK: Releases

    @Test func readsGitHubsLatestReleaseResponse() throws {
        let json = """
        {"tag_name":"v2.4.0","html_url":"https://github.com/rwijnen/folio-viewer/releases/tag/v2.4.0",
         "draft":false,"prerelease":false,"body":"ignored","assets":[
          {"name":"Folio.app.zip","size":3183577,
           "browser_download_url":"https://github.com/rwijnen/folio-viewer/releases/download/v2.4.0/Folio.app.zip"}]}
        """
        let decoded = try Updates.decodeRelease(Data(json.utf8))
        #expect(decoded.tagName == "v2.4.0")
        #expect(decoded.assets.first?.name == "Folio.app.zip")
        #expect(throws: Updates.UpdateError.unreadableResponse) {
            try Updates.decodeRelease(Data("{\"message\":\"Not Found\"}".utf8))
        }
    }

    @Test func offersOnlyANewerPublishedRelease() throws {
        let newer = try #require(try Updates.available(in: release(), current: version("2.4.0")))
        #expect(newer.version == version("2.5.0"))
        #expect(newer.archive.lastPathComponent == "Folio.app.zip")
        #expect(try Updates.available(in: release(tag: "v2.4.0"), current: version("2.4.0")) == nil)
        #expect(try Updates.available(in: release(tag: "v2.3.0"), current: version("2.4.0")) == nil)
        #expect(try Updates.available(in: release(draft: true), current: version("2.4.0")) == nil)
        #expect(try Updates.available(in: release(prerelease: true), current: version("2.4.0")) == nil)
    }

    @Test func refusesAReleaseWithoutItsChecksum() {
        let zipOnly = release(assets: [("Folio.app.zip",
            "https://github.com/rwijnen/folio-viewer/releases/download/v2.5.0/Folio.app.zip")])
        #expect(throws: Updates.UpdateError.missingAssets("2.5.0")) {
            try Updates.available(in: zipOnly, current: self.version("2.4.0"))
        }
    }

    @Test func refusesDownloadsFromAnywhereElse() {
        let elsewhere = release(assets: [
            ("Folio.app.zip", "https://example.com/Folio.app.zip"),
            ("Folio.app.zip.sha256", "https://github.com/rwijnen/folio-viewer/releases/download/v2.5.0/Folio.app.zip.sha256"),
        ])
        #expect(throws: Updates.UpdateError.untrustedLocation("https://example.com/Folio.app.zip")) {
            try Updates.available(in: elsewhere, current: self.version("2.4.0"))
        }
        let otherRepository = release(assets: [
            ("Folio.app.zip", "https://github.com/someone/folio-viewer/releases/download/v2.5.0/Folio.app.zip"),
            ("Folio.app.zip.sha256", "https://github.com/someone/folio-viewer/releases/download/v2.5.0/Folio.app.zip.sha256"),
        ])
        #expect(throws: (any Error).self) {
            try Updates.available(in: otherRepository, current: self.version("2.4.0"))
        }
    }

    // MARK: Asking

    @Test func asksOnceThenFollowsTheAnswer() {
        #expect(Updates.launchAction(checksAtLaunch: nil) == .ask)
        #expect(Updates.launchAction(checksAtLaunch: true) == .check)
        #expect(Updates.launchAction(checksAtLaunch: false) == .nothing)
    }

    @Test func aSkippedVersionStaysQuietOnlyAtLaunch() throws {
        let available = try #require(try Updates.available(in: release(), current: version("2.4.0")))
        #expect(!Updates.shouldOffer(available, skipped: "2.5.0", manual: false))
        #expect(Updates.shouldOffer(available, skipped: "2.5.0", manual: true))
        #expect(Updates.shouldOffer(available, skipped: "2.4.9", manual: false))
        #expect(Updates.shouldOffer(available, skipped: nil, manual: false))
    }

    // MARK: Verifying

    @Test func checksTheDownloadAgainstItsPublishedHash() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("Folio.app.zip")
        try Data("folio".utf8).write(to: archive)
        // shasum -a 256 of the five bytes "folio".
        let hash = try Updates.sha256(of: archive)
        #expect(hash.count == 64)

        try Updates.verify(archive: archive, checksumFile: "\(hash)  Folio.app.zip\n")
        #expect(throws: Updates.UpdateError.checksumMismatch) {
            try Updates.verify(archive: archive, checksumFile: String(repeating: "0", count: 64) + "  Folio.app.zip")
        }
        #expect(throws: Updates.UpdateError.unreadableChecksum) {
            try Updates.verify(archive: archive, checksumFile: "<html>Not Found</html>")
        }
    }

    private func makeBundle(in folder: URL, identifier: String = "com.robinwijnen.Folio",
                            version: String = "2.5.0", marker: String = "new") throws -> URL {
        let app = folder.appendingPathComponent("Folio.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("Folio")
        try Data(marker.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return app
    }

    @Test func acceptsOnlyFolioAtThePromisedVersion() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        let good = try makeBundle(in: folder.appendingPathComponent("good"))
        try Updates.validateBundle(at: good, expecting: version("2.5.0"))

        let other = try makeBundle(in: folder.appendingPathComponent("other"), identifier: "com.example.Other")
        #expect(throws: (any Error).self) { try Updates.validateBundle(at: other, expecting: self.version("2.5.0")) }

        let stale = try makeBundle(in: folder.appendingPathComponent("stale"), version: "2.4.0")
        #expect(throws: (any Error).self) { try Updates.validateBundle(at: stale, expecting: self.version("2.5.0")) }

        #expect(throws: (any Error).self) {
            try Updates.validateBundle(at: folder.appendingPathComponent("missing.app"), expecting: self.version("2.5.0"))
        }
    }

    // MARK: Installing

    @Test func replacesTheInstalledCopy() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let applications = folder.appendingPathComponent("Applications", isDirectory: true)
        let installed = try makeBundle(in: applications, version: "2.4.0", marker: "old")
        let newApp = try makeBundle(in: folder.appendingPathComponent("download"), marker: "new")

        try Updates.replace(installed: installed, with: newApp,
                            discard: { try FileManager.default.removeItem(at: $0) })

        let executable = installed.appendingPathComponent("Contents/MacOS/Folio")
        #expect(String(decoding: try Data(contentsOf: executable), as: UTF8.self) == "new")
        // Only the new copy is left beside it; the old one was discarded.
        let left = try FileManager.default.contentsOfDirectory(atPath: applications.path)
        #expect(left == ["Folio.app"])
    }

    @Test func aFailedSwapKeepsTheOldCopy() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let applications = folder.appendingPathComponent("Applications", isDirectory: true)
        let installed = try makeBundle(in: applications, version: "2.4.0", marker: "old")
        let missing = folder.appendingPathComponent("download/Folio.app")

        #expect(throws: (any Error).self) {
            try Updates.replace(installed: installed, with: missing,
                                discard: { try FileManager.default.removeItem(at: $0) })
        }

        let executable = installed.appendingPathComponent("Contents/MacOS/Folio")
        #expect(String(decoding: try Data(contentsOf: executable), as: UTF8.self) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["Folio.app"])
    }
}

/// The launch check must never interrupt: offline, or with nothing new, it says nothing.
@Suite("Update check at launch")
@MainActor
struct UpdateLaunchTests {

    @Test func anOfflineLaunchCheckIsSilent() async {
        let state = AppState()
        await state.checkForUpdates(manual: false) { _ in throw URLError(.notConnectedToInternet) }
        #expect(state.updateActivity == nil)
        #expect(state.errorMessage == nil)
    }

    @Test func aDraftReleaseIsNotOffered() async {
        let state = AppState()
        let json = """
        {"tag_name":"v99.0.0","html_url":"https://github.com/rwijnen/folio-viewer/releases/tag/v99.0.0",
         "draft":true,"prerelease":false,"assets":[]}
        """
        await state.checkForUpdates(manual: false) { _ in Data(json.utf8) }
        #expect(state.updateActivity == nil)
    }
}
