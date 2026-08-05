import Foundation

/// Turns one diff entry plus the file on disk into everything the split view needs.
///
/// Runs off the main actor — the patch application, LCS and lexer passes are the
/// expensive part of opening a diff.
enum DiffPreparation {

    static func prepare(entry: FileEntry) async -> FileLoadState {
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
