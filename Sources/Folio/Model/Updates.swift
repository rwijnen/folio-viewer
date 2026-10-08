import CryptoKit
import Foundation

/// Finding, checking and installing a newer Folio from the project's GitHub releases.
///
/// The one place besides Push where Folio goes online, and only ever because the reader
/// asked: from the menu, or at launch once they have said yes to that. Everything here is
/// pure or works on files it is handed, so it is testable without a network or a running
/// app; the requests themselves are made through `Updates.Fetcher`.
enum Updates {

    /// Where releases come from. Fixed, not configurable: an update is code that runs as
    /// the reader, so the source of it is not something a preference should be able to move.
    static let repository = "rwijnen/folio-viewer"
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    /// Every asset must be served from under here.
    static let downloadPrefix = "https://github.com/\(repository)/releases/download/"
    static let bundleIdentifier = "com.robinwijnen.Folio"
    static let archiveName = "Folio.app.zip"
    static let checksumName = "Folio.app.zip.sha256"

    // MARK: - Versions

    /// `major.minor.patch`, compared numerically. A leading `v` is accepted so a tag and a
    /// bundle version compare directly; missing parts count as zero.
    struct Version: Comparable, CustomStringConvertible {
        let parts: [Int]

        init?(_ text: String) {
            var text = text.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
            let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
            guard !pieces.isEmpty, pieces.count <= 4 else { return nil }
            var parts: [Int] = []
            for piece in pieces {
                guard let number = Int(piece), number >= 0 else { return nil }
                parts.append(number)
            }
            while parts.count < 3 { parts.append(0) }
            self.parts = parts
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            let count = max(lhs.parts.count, rhs.parts.count)
            for index in 0..<count {
                let left = index < lhs.parts.count ? lhs.parts[index] : 0
                let right = index < rhs.parts.count ? rhs.parts[index] : 0
                if left != right { return left < right }
            }
            return false
        }

        static func == (lhs: Version, rhs: Version) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

        var description: String { parts.map(String.init).joined(separator: ".") }
    }

    // MARK: - Releases

    /// The parts of GitHub's release response that matter here.
    struct Release: Decodable, Equatable {
        struct Asset: Decodable, Equatable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft, prerelease, assets
        }

        var version: Version? { Version(tagName) }
    }

    /// A release that is newer than this copy and carries what an install needs.
    struct Available: Equatable {
        let version: Version
        let archive: URL
        let checksum: URL
        let page: URL
    }

    enum UpdateError: LocalizedError, Equatable {
        case unreadableResponse
        case missingAssets(String)
        case untrustedLocation(String)
        case checksumMismatch
        case unreadableChecksum
        case notAnApp(String)
        case cannotReplace(String)

        var errorDescription: String? {
            switch self {
            case .unreadableResponse:
                return "GitHub's answer about the latest release could not be read."
            case .missingAssets(let version):
                return "Release \(version) has no \(Updates.archiveName) with a checksum beside it."
            case .untrustedLocation(let url):
                return "The download is not served from Folio's releases (\(url)), so it was not used."
            case .checksumMismatch:
                return "The download does not match its published checksum, so it was not installed."
            case .unreadableChecksum:
                return "The published checksum could not be read."
            case .notAnApp(let reason):
                return "The download is not a usable Folio: \(reason)"
            case .cannotReplace(let reason):
                return "Folio could not replace itself: \(reason)"
            }
        }
    }

    /// What the latest release means for this copy: nil when it is not newer, or is a
    /// draft or prerelease. Throws when it is newer but cannot be installed safely.
    static func available(in release: Release, current: Version) throws -> Available? {
        guard !release.draft, !release.prerelease,
              let version = release.version, version > current else { return nil }
        guard let archive = release.assets.first(where: { $0.name == archiveName }),
              let checksum = release.assets.first(where: { $0.name == checksumName }) else {
            throw UpdateError.missingAssets(version.description)
        }
        for url in [archive.browserDownloadURL, checksum.browserDownloadURL]
        where !url.absoluteString.hasPrefix(downloadPrefix) {
            throw UpdateError.untrustedLocation(url.absoluteString)
        }
        return Available(version: version, archive: archive.browserDownloadURL,
                         checksum: checksum.browserDownloadURL, page: release.htmlURL)
    }

    static func decodeRelease(_ data: Data) throws -> Release {
        do {
            return try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw UpdateError.unreadableResponse
        }
    }

    // MARK: - Launch

    /// What to do about updates when Folio starts.
    enum LaunchAction: Equatable {
        /// Not asked yet: ask once whether to check at launch.
        case ask
        case check
        case nothing
    }

    /// `checksAtLaunch` is nil until the reader has answered the question.
    static func launchAction(checksAtLaunch: Bool?) -> LaunchAction {
        switch checksAtLaunch {
        case nil: return .ask
        case true?: return .check
        case false?: return .nothing
        }
    }

    /// Whether a launch check should bring this release up. A manual check always does;
    /// a launch check stays quiet about a version the reader chose to skip.
    static func shouldOffer(_ available: Available, skipped: String?, manual: Bool) -> Bool {
        if manual { return true }
        guard let skipped, let skippedVersion = Version(skipped) else { return true }
        return available.version != skippedVersion
    }

    // MARK: - Verifying

    /// The hash out of a `shasum -a 256` line: `<64 hex>  Folio.app.zip`.
    static func expectedHash(fromChecksumFile text: String) throws -> String {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first,
              first.count == 64, first.allSatisfy(\.isHexDigit) else {
            throw UpdateError.unreadableChecksum
        }
        return first.lowercased()
    }

    static func sha256(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verify(archive: URL, checksumFile text: String) throws {
        let expected = try expectedHash(fromChecksumFile: text)
        guard try sha256(of: archive) == expected else { throw UpdateError.checksumMismatch }
    }

    /// Checks an unpacked bundle is Folio, at the version promised, before anything is
    /// replaced with it. The code signature is checked separately (`codesign --verify`).
    static func validateBundle(at app: URL, expecting version: Version) throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw UpdateError.notAnApp("it has no readable Info.plist.") }
        guard plist["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateError.notAnApp("it is a different app.")
        }
        guard let bundled = (plist["CFBundleShortVersionString"] as? String).flatMap(Version.init),
              bundled == version else {
            throw UpdateError.notAnApp("it says it is a different version than the release.")
        }
        let executable = app.appendingPathComponent("Contents/MacOS/Folio")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UpdateError.notAnApp("it has no Folio executable.")
        }
    }

    // MARK: - Installing

    /// Puts `newApp` where `installed` is, keeping the old copy until the new one is in
    /// place so a failure part-way leaves a working Folio behind. The old copy goes to
    /// the Trash rather than being deleted. Safe while the old copy is running: the
    /// process keeps its open files, and the new copy is what the next launch finds.
    static func replace(installed: URL, with newApp: URL, fileManager: FileManager = .default,
                        discard: (URL) throws -> Void = moveToTrash) throws {
        let parent = installed.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parent.path) else {
            throw UpdateError.cannotReplace("\(parent.path) is not writable.")
        }
        let aside = parent.appendingPathComponent(".Folio-previous-\(UUID().uuidString).app")
        do {
            try fileManager.moveItem(at: installed, to: aside)
        } catch {
            throw UpdateError.cannotReplace(error.localizedDescription)
        }
        do {
            try fileManager.moveItem(at: newApp, to: installed)
        } catch {
            // Put the old one back so the reader is never left without an app.
            try? fileManager.moveItem(at: aside, to: installed)
            throw UpdateError.cannotReplace(error.localizedDescription)
        }
        if (try? discard(aside)) == nil {
            try? fileManager.removeItem(at: aside)
        }
    }

    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
