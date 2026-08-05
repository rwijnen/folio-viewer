import Foundation

/// Turns the paths written inside a diff into real files on disk.
///
/// Diff paths are relative to wherever the diff was produced and usually carry a
/// `a/` / `b/` prefix. We therefore try a series of candidates against a base
/// folder rather than trusting the path verbatim.
enum PathResolver {

    /// Strips git's `a/` / `b/` prefix (and svn/hg equivalents) from a diff path.
    static func stripVCSPrefix(_ path: String) -> String {
        for prefix in ["a/", "b/", "i/", "w/", "c/", "o/"] where path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    /// All plausible relative paths for a diff path, most likely first.
    static func candidates(for path: String) -> [String] {
        var results: [String] = []
        let stripped = stripVCSPrefix(path)
        results.append(stripped)
        if stripped != path { results.append(path) }
        // Progressive `-p2`, `-p3` style strips for diffs made from a deeper directory.
        var components = stripped.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        while components.count > 1 {
            components.removeFirst()
            results.append(components.joined(separator: "/"))
        }
        return results.filter { !$0.isEmpty }
    }

    /// Resolves a diff path to an existing file, preferring `base`-relative matches.
    static func resolve(path: String, base: URL?) -> URL? {
        if path.hasPrefix("/") {
            let absolute = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: absolute.path) { return absolute }
        }
        guard let base else { return nil }
        for candidate in candidates(for: path) {
            let url = base.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Picks the folder that resolves the most files in the diff.
    ///
    /// Candidates are the diff's own folder and its ancestors, plus the enclosing
    /// git working copy if there is one. Returns nil when nothing matches.
    static func inferBaseFolder(diffURL: URL, files: [FileDiff]) -> URL? {
        let paths = files.compactMap { $0.rawOldPath ?? $0.rawNewPath }
        guard !paths.isEmpty else { return nil }

        var candidates: [URL] = []
        var ancestors: [URL] = []
        var folder = diffURL.deletingLastPathComponent().standardizedFileURL
        for _ in 0..<8 {
            ancestors.append(folder)
            let parent = folder.deletingLastPathComponent().standardizedFileURL
            if parent.path == folder.path { break }
            folder = parent
        }
        candidates.append(contentsOf: ancestors)
        if let repoRoot = gitRoot(startingAt: diffURL.deletingLastPathComponent()) {
            candidates.insert(repoRoot, at: 0)
        }
        // A diff is often saved next to the checkout rather than inside it
        // (`~/Downloads/fix.diff` + `~/Downloads/project/`), so look one level down too.
        for ancestor in ancestors.prefix(2) {
            candidates.append(contentsOf: subdirectories(of: ancestor))
        }

        var best: (url: URL, score: Int)?
        for candidate in candidates {
            var score = 0
            for path in paths where resolve(path: path, base: candidate) != nil {
                score += 1
            }
            if score > 0, score > (best?.score ?? 0) {
                best = (candidate, score)
            }
            if score == paths.count { break }
        }
        return best?.url
    }

    /// Immediate, visible subdirectories — bounded so a huge folder cannot stall opening.
    private static func subdirectories(of url: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return entries.prefix(200).filter { entry in
            (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    /// Walks up looking for a `.git` entry.
    static func gitRoot(startingAt url: URL) -> URL? {
        var folder = url.standardizedFileURL
        for _ in 0..<32 {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) {
                return folder
            }
            let parent = folder.deletingLastPathComponent().standardizedFileURL
            if parent.path == folder.path { return nil }
            folder = parent
        }
        return nil
    }
}
