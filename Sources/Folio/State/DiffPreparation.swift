import Foundation

/// Turns one diff entry plus the file on disk into everything the split view needs.
///
/// Runs off the main actor — the patch application, LCS and lexer passes are the
/// expensive part of opening a diff.
enum DiffPreparation {

    /// Two versions of a text Folio is holding itself, rather than a diff it was given.
    ///
    /// This is the only path that has to *compute* the difference, because neither side
    /// came from a patch: `mine` is what the tab is showing and `theirs` is what is on
    /// disk. Everything after the comparison is the ordinary pipeline.
    struct Comparison {
        var state: FileLoadState
        /// The synthesised entry the split view puts in its header.
        var diff: FileDiff
    }

    static func prepare(comparing mine: [String], with theirs: [String],
                        named name: String) async -> Comparison {
        let spec = LanguageCatalog.spec(forPath: name)
        return await Task.detached(priority: .userInitiated) { () -> Comparison in
            let result = LineDiff.compare(original: mine, updated: theirs)
            let diff = FileDiff(rawOldPath: name, rawNewPath: name,
                                kind: .modified, hunks: result.applied.map(\.hunk))
            let document = SideBySideBuilder.build(applied: result.applied,
                                                   originalRaw: mine,
                                                   patchedRaw: theirs,
                                                   warnings: [])
            let loaded = LoadedFile(
                document: document,
                leftSpans: SyntaxHighlighter.highlight(lines: document.leftLines, spec: spec),
                rightSpans: SyntaxHighlighter.highlight(lines: document.rightLines, spec: spec),
                languageName: spec.name,
                originalURL: nil,
                degradedReason: nil,
                notice: result.isCoarse
                    // Said rather than hidden: at this size the alignment is coarse, and
                    // a reader comparing two versions should know the pairing is not
                    // line by line.
                    ? "The two versions are too different to line up, so the whole file "
                      + "is shown as replaced."
                    : nil)
            return Comparison(state: .loaded(loaded), diff: diff)
        }.value
    }

    /// The same work for a commit out of a file's history.
    ///
    /// Shorter than the path above because git removes every reason it is long: the
    /// content going in comes from the repository rather than from a file on disk that
    /// might be the wrong revision, so there is no reconstruction, no reversing, and no
    /// guessing at which side of the change the disk holds.
    static func prepare(change: GitHistory.Change) async -> FileLoadState {
        let file = change.diff
        let spec = LanguageCatalog.spec(forPath: file.displayPath)

        if file.isBinary {
            return .failed("\(file.displayName) is a binary file at this commit.")
        }
        if file.hunks.isEmpty, !change.isNew {
            return .failed(file.renameDescription ?? "This commit changed no lines in the file.")
        }

        return await Task.detached(priority: .userInitiated) { () -> FileLoadState in
            var document: SideBySideDocument
            var notice: String?

            if change.isNew {
                document = SideBySideBuilder.wholeFile(lines: file.hunks.flatMap { $0.newLines },
                                                       added: true)
                notice = "This commit added the file."
            } else if file.kind == .deleted {
                document = SideBySideBuilder.wholeFile(lines: change.parentLines, added: false)
                notice = "This commit deleted the file."
            } else if let forward = try? PatchApplier.apply(hunks: file.hunks,
                                                            to: change.parentLines) {
                document = SideBySideBuilder.build(applied: forward.applied,
                                                   originalRaw: change.parentLines,
                                                   patchedRaw: forward.newLines,
                                                   warnings: forward.warnings)
            } else {
                // Should not happen — these hunks came from git, applied to the content
                // git says they were made against. Reported as a notice rather than the
                // degraded banner, because that one offers "Locate Original…" and there
                // is no original on disk to locate.
                document = SideBySideBuilder.buildDiffOnly(file: file, warnings: [])
                notice = "The recorded change could not be replayed, so only the diff is shown."
            }

            return .loaded(LoadedFile(document: document,
                                      leftSpans: SyntaxHighlighter.highlight(
                                        lines: document.leftLines, spec: spec),
                                      rightSpans: SyntaxHighlighter.highlight(
                                        lines: document.rightLines, spec: spec),
                                      languageName: spec.name,
                                      originalURL: nil,
                                      degradedReason: nil,
                                      notice: notice))
        }.value
    }

    static func prepare(entry: FileEntry) async -> FileLoadState {
        // A diff of the working tree against a commit: the committed side comes from git,
        // so none of the reconstruction below is needed. It is the same shape as a commit
        // out of the history, and goes through the same path.
        if let source = entry.committedOriginal {
            let committed = await source.git.run(
                ["show", "\(source.revision):\(source.path)"])
            let isNew = !committed.succeeded || entry.diff.kind == .added
            return await prepare(change: GitHistory.Change(
                diff: entry.diff,
                parentLines: isNew ? [] : TextNormalizer.splitLines(committed.output),
                isNew: isNew))
        }

        let file = entry.diff
        let path = file.displayPath
        let spec = LanguageCatalog.spec(forPath: path)

        if file.isBinary {
            return .failed("\(file.displayName) is a binary file. There is nothing to show side by side.")
        }
        if file.hunks.isEmpty {
            let detail: String
            switch file.kind {
            case .renamed: detail = file.renameDescription ?? "File was renamed."
            case .copied: detail = file.renameDescription ?? "File was copied."
            case .modeOnly: detail = "Only the file mode changed (\(file.oldMode ?? "?") → \(file.newMode ?? "?"))."
            default: detail = "This entry contains no line changes."
            }
            return .failed(detail)
        }

        return await Task.detached(priority: .userInitiated) { () -> FileLoadState in
            var degradedReason: String?
            var notice: String?
            var leftIsReconstructed = false
            var document: SideBySideDocument

            func diffOnly(_ reason: String) -> SideBySideDocument {
                degradedReason = reason
                return SideBySideBuilder.buildDiffOnly(file: file, warnings: [])
            }

            switch file.kind {
            case .added:
                // New file: nothing on disk to read, the right side is the diff content.
                document = SideBySideBuilder.wholeFile(lines: file.hunks.flatMap { $0.newLines },
                                                       added: true)

            case .deleted where entry.originalURL == nil:
                // Already deleted on disk; the diff carries the whole previous content.
                document = SideBySideBuilder.wholeFile(lines: file.hunks.flatMap { $0.oldLines },
                                                       added: false)
                notice = "\(file.displayName) is already gone from disk, so the left side comes from the diff."

            default:
                guard let originalURL = entry.originalURL else {
                    document = diffOnly("Original not found for \(path). Showing the diff content only.")
                    break
                }
                do {
                    let disk = TextNormalizer.splitLines(try TextNormalizer.readText(at: originalURL))
                    if file.kind == .deleted {
                        document = SideBySideBuilder.wholeFile(lines: disk, added: false)
                        break
                    }
                    do {
                        let forward = try PatchApplier.apply(hunks: file.hunks, to: disk)
                        document = SideBySideBuilder.build(applied: forward.applied,
                                                           originalRaw: disk,
                                                           patchedRaw: forward.newLines,
                                                           warnings: forward.warnings)
                    } catch let forwardError {
                        // The file on disk is often the *changed* version rather than the
                        // original — that is what you have after applying a patch, or when
                        // the diff was produced somewhere else. The original is then exactly
                        // recoverable: run the patch backwards, and re-run it forwards over
                        // the result so the row alignment comes from the normal path.
                        if let backwards = try? PatchApplier.apply(
                                hunks: PatchApplier.reverse(file.hunks), to: disk),
                           let forward = try? PatchApplier.apply(
                                hunks: file.hunks, to: backwards.newLines) {
                            leftIsReconstructed = true
                            notice = "\(file.displayName) on disk already contains these changes, "
                                + "so the original was reconstructed by applying the diff backwards."
                            document = SideBySideBuilder.build(applied: forward.applied,
                                                               originalRaw: backwards.newLines,
                                                               patchedRaw: forward.newLines,
                                                               warnings: forward.warnings)
                        } else {
                            document = diffOnly("\(forwardError.localizedDescription) "
                                + "The file on disk looks like a different revision — it is neither "
                                + "the original nor the changed version. Showing the diff content only.")
                        }
                    }
                } catch {
                    document = diffOnly("\(error.localizedDescription) Showing the diff content only.")
                }
            }

            let leftSpans = SyntaxHighlighter.highlight(lines: document.leftLines, spec: spec)
            let rightSpans = SyntaxHighlighter.highlight(lines: document.rightLines, spec: spec)
            return .loaded(LoadedFile(document: document,
                                      leftSpans: leftSpans,
                                      rightSpans: rightSpans,
                                      languageName: spec.name,
                                      originalURL: entry.originalURL,
                                      degradedReason: degradedReason,
                                      notice: notice,
                                      leftIsReconstructed: leftIsReconstructed))
        }.value
    }
}
