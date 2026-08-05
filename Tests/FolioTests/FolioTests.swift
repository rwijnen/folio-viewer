import Foundation
import Testing

@testable import Folio

// Fixtures live in Samples/ next to the package manifest.
private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // FolioTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // package root
private let samplesRoot = repositoryRoot.appendingPathComponent("Samples")
private let sampleProject = samplesRoot.appendingPathComponent("project")

private func sampleDiff() throws -> ParsedDiff {
    let text = try TextNormalizer.readText(at: samplesRoot.appendingPathComponent("example.diff"))
    return DiffParser.parse(text: text)
}

private func entry(_ parsed: ParsedDiff, named name: String) throws -> FileDiff {
    try #require(parsed.files.first { $0.displayPath.hasSuffix(name) })
}

// MARK: - Parsing

@Suite("Diff parsing")
struct DiffParsingTests {

    @Test func parsesEveryFileEntryInAGitDiff() throws {
        let parsed = try sampleDiff()
        #expect(parsed.files.count == 4)
        #expect(parsed.files.map(\.displayPath) == [
            "Config/settings.json",
            "Sources/Farewell.swift",
            "Sources/Greeter.swift",
            "Sources/Legacy.swift",
        ])
    }

    @Test func classifiesAddedDeletedAndModifiedFiles() throws {
        let parsed = try sampleDiff()
        #expect(try entry(parsed, named: "Farewell.swift").kind == .added)
        #expect(try entry(parsed, named: "Legacy.swift").kind == .deleted)
        #expect(try entry(parsed, named: "Greeter.swift").kind == .modified)
    }

    @Test func countsAdditionsAndDeletions() throws {
        let json = try entry(try sampleDiff(), named: "settings.json")
        #expect(json.additions == 6)
        #expect(json.deletions == 4)
        #expect(json.hunks.count == 1)
        #expect(json.hunks[0].oldStart == 1)
        #expect(json.hunks[0].newStart == 1)
    }

    @Test func keepsHunkHeadingText() throws {
        let greeter = try entry(try sampleDiff(), named: "Greeter.swift")
        #expect(greeter.hunks.count == 2)
        #expect(greeter.hunks[0].heading == "import Foundation")
        #expect(greeter.hunks[1].heading == "struct Greeter {")
    }

    @Test func parsesPlainDiffUWithTimestamps() {
        let text = """
        --- old/main.c\t2026-08-01 09:15:22.000000000 +0200
        +++ new/main.c\t2026-08-04 11:02:04.000000000 +0200
        @@ -1,4 +1,4 @@
         int main(void) {
        -    return 1;
        +    return 0;
         }
        """
        let parsed = DiffParser.parse(text: text)
        #expect(parsed.files.count == 1)
        #expect(parsed.files[0].rawOldPath == "old/main.c")
        #expect(parsed.files[0].rawNewPath == "new/main.c")
        #expect(parsed.files[0].additions == 1)
        #expect(parsed.files[0].deletions == 1)
    }

    @Test func parsesMultipleFilesWithoutGitHeaders() {
        let text = """
        --- a/one.txt
        +++ b/one.txt
        @@ -1 +1 @@
        -one
        +ONE
        --- a/two.txt
        +++ b/two.txt
        @@ -1 +1 @@
        -two
        +TWO
        """
        let parsed = DiffParser.parse(text: text)
        #expect(parsed.files.count == 2)
        #expect(parsed.files.map(\.displayPath) == ["one.txt", "two.txt"])
    }

    @Test func toleratesMissingCountInHunkHeader() {
        let text = """
        --- a/x
        +++ b/x
        @@ -3 +3 @@
        -old
        +new
        """
        let parsed = DiffParser.parse(text: text)
        let hunk = parsed.files[0].hunks[0]
        #expect(hunk.oldStart == 3)
        #expect(hunk.oldCount == 1)
        #expect(hunk.newCount == 1)
    }

    @Test func treatsRemovedLineStartingWithDashesAsContent() {
        // A removed line whose text is "--- header" arrives as "----- header".
        let text = """
        --- a/x
        +++ b/x
        @@ -1,2 +1,2 @@
        ---- header
        ++++ header
        """
        let parsed = DiffParser.parse(text: text)
        #expect(parsed.files.count == 1)
        #expect(parsed.files[0].hunks[0].lines.map(\.text) == ["--- header", "+++ header"])
    }

    @Test func recognisesBinaryStubs() {
        let text = """
        diff --git a/logo.png b/logo.png
        index 1234567..89abcde 100644
        Binary files a/logo.png and b/logo.png differ
        """
        let parsed = DiffParser.parse(text: text)
        #expect(parsed.files.count == 1)
        #expect(parsed.files[0].isBinary)
    }

    @Test func recognisesRenames() {
        let text = """
        diff --git a/old/name.swift b/new/name.swift
        similarity index 98%
        rename from old/name.swift
        rename to new/name.swift
        """
        let parsed = DiffParser.parse(text: text)
        #expect(parsed.files[0].kind == .renamed)
        #expect(parsed.files[0].renameDescription != nil)
    }

    @Test func ignoresNoNewlineMarkers() {
        let text = """
        --- a/x
        +++ b/x
        @@ -1,1 +1,1 @@
        -one
        \\ No newline at end of file
        +two
        \\ No newline at end of file
        """
        let parsed = DiffParser.parse(text: text)
        #expect(parsed.files[0].hunks[0].lines.count == 2)
    }
}

// MARK: - Patch application

@Suite("Patch application")
struct PatchApplicationTests {

    private func original(_ name: String) throws -> [String] {
        let url = sampleProject.appendingPathComponent(name)
        return TextNormalizer.splitLines(try TextNormalizer.readText(at: url))
    }

    @Test func producesTheModifiedFileFromOriginalPlusDiff() throws {
        let json = try entry(try sampleDiff(), named: "settings.json")
        let result = try PatchApplier.apply(hunks: json.hunks, to: try original("Config/settings.json"))
        let text = result.newLines.joined(separator: "\n")
        #expect(text.contains("\"version\": \"1.3.0\""))
        #expect(text.contains("\"timeoutSeconds\": 30"))
        #expect(!text.contains("en_GB"))
        #expect(result.warnings.isEmpty)
    }

    @Test func appliesEveryHunkOfAMultiHunkFile() throws {
        let greeter = try entry(try sampleDiff(), named: "Greeter.swift")
        let originalLines = try original("Sources/Greeter.swift")
        let result = try PatchApplier.apply(hunks: greeter.hunks, to: originalLines)
        let text = result.newLines.joined(separator: "\n")
        #expect(text.contains("case french"))
        #expect(text.contains("case nameTooLong(Int)"))
        #expect(result.newLines.count == originalLines.count + greeter.additions - greeter.deletions)
        #expect(result.applied.count == 2)
    }

    @Test func toleratesLineNumberDrift() throws {
        let json = try entry(try sampleDiff(), named: "settings.json")
        // Five lines of noise pushed in front of the file: the hunk must still land.
        let shifted = ["// generated", "", "// header", "", "// noise"]
            + (try original("Config/settings.json"))
        let result = try PatchApplier.apply(hunks: json.hunks, to: shifted)
        #expect(result.applied[0].offset == 5)
        #expect(result.warnings.contains { $0.contains("offset +5") })
        #expect(result.newLines.joined(separator: "\n").contains("\"version\": \"1.3.0\""))
    }

    @Test func matchesDespiteTrailingWhitespaceDifferences() throws {
        let hunks = DiffParser.parse(text: """
        --- a/x
        +++ b/x
        @@ -1,3 +1,3 @@
         alpha
        -beta
        +BETA
         gamma
        """).files[0].hunks
        let result = try PatchApplier.apply(hunks: hunks, to: ["alpha   ", "beta", "gamma  "])
        #expect(result.newLines == ["alpha", "BETA", "gamma"])
        #expect(result.applied[0].fuzzy)
    }

    @Test func failsWhenTheOriginalIsUnrelated() throws {
        let json = try entry(try sampleDiff(), named: "settings.json")
        #expect(throws: PatchApplier.Failure.self) {
            _ = try PatchApplier.apply(hunks: json.hunks, to: ["nothing", "to", "do", "with", "it"])
        }
    }

    @Test func reconstructsTheOriginalFromTheAlreadyPatchedFile() throws {
        let json = try entry(try sampleDiff(), named: "settings.json")
        let original = try original("Config/settings.json")
        let patched = try PatchApplier.apply(hunks: json.hunks, to: original).newLines

        // The file on disk is the changed version: forward application must fail…
        #expect(throws: PatchApplier.Failure.self) {
            _ = try PatchApplier.apply(hunks: json.hunks, to: patched)
        }
        // …and the reversed patch must give back exactly the original.
        let backwards = try PatchApplier.apply(hunks: PatchApplier.reverse(json.hunks), to: patched)
        #expect(backwards.newLines == original)
        // Re-running it forwards over that reproduces the on-disk file.
        let forward = try PatchApplier.apply(hunks: json.hunks, to: backwards.newLines)
        #expect(forward.newLines == patched)
    }

    @Test func reversingTwiceIsTheIdentity() throws {
        let greeter = try entry(try sampleDiff(), named: "Greeter.swift")
        let twice = PatchApplier.reverse(PatchApplier.reverse(greeter.hunks))
        #expect(twice.map(\.headerText) == greeter.hunks.map(\.headerText))
        #expect(twice.flatMap { $0.lines.map(\.text) } == greeter.hunks.flatMap { $0.lines.map(\.text) })
    }

    @Test func reconstructionAlignsTheSameWayAsForwardApplication() throws {
        let greeter = try entry(try sampleDiff(), named: "Greeter.swift")
        let original = try original("Sources/Greeter.swift")
        let forwardOnly = try PatchApplier.apply(hunks: greeter.hunks, to: original)
        let expected = SideBySideBuilder.build(applied: forwardOnly.applied, originalRaw: original,
                                              patchedRaw: forwardOnly.newLines, warnings: [])

        // Same file, but reached from the patched version via the reverse path.
        let backwards = try PatchApplier.apply(hunks: PatchApplier.reverse(greeter.hunks),
                                               to: forwardOnly.newLines)
        let replayed = try PatchApplier.apply(hunks: greeter.hunks, to: backwards.newLines)
        let reconstructed = SideBySideBuilder.build(applied: replayed.applied,
                                                    originalRaw: backwards.newLines,
                                                    patchedRaw: replayed.newLines, warnings: [])

        #expect(reconstructed.rows.count == expected.rows.count)
        #expect(reconstructed.rows.map(\.kind) == expected.rows.map(\.kind))
        #expect(reconstructed.rows.map { $0.left?.text } == expected.rows.map { $0.left?.text })
        #expect(reconstructed.rows.map { $0.right?.text } == expected.rows.map { $0.right?.text })
    }

    @Test func handlesPureInsertionHunks() throws {
        let hunks = DiffParser.parse(text: """
        --- a/x
        +++ b/x
        @@ -2,0 +3,2 @@
        +inserted one
        +inserted two
        """).files[0].hunks
        let result = try PatchApplier.apply(hunks: hunks, to: ["one", "two", "three"])
        #expect(result.newLines == ["one", "two", "inserted one", "inserted two", "three"])
    }
}

// MARK: - Side-by-side alignment

@Suite("Side-by-side alignment")
struct SideBySideTests {

    private func document(for name: String, path: String) throws -> SideBySideDocument {
        let file = try entry(try sampleDiff(), named: name)
        let original = TextNormalizer.splitLines(
            try TextNormalizer.readText(at: sampleProject.appendingPathComponent(path)))
        let applied = try PatchApplier.apply(hunks: file.hunks, to: original)
        return SideBySideBuilder.build(applied: applied.applied,
                                      originalRaw: original,
                                      patchedRaw: applied.newLines,
                                      warnings: applied.warnings)
    }

    @Test func unchangedRowsCarryIdenticalTextOnBothSides() throws {
        let document = try document(for: "Greeter.swift", path: "Sources/Greeter.swift")
        for row in document.rows where row.kind == .unchanged {
            #expect(row.left?.text == row.right?.text)
        }
    }

    @Test func lineNumbersAreStrictlyIncreasingOnBothSides() throws {
        let document = try document(for: "Greeter.swift", path: "Sources/Greeter.swift")
        var lastLeft = 0
        var lastRight = 0
        for row in document.rows {
            if let left = row.left {
                #expect(left.number == lastLeft + 1)
                lastLeft = left.number
            }
            if let right = row.right {
                #expect(right.number == lastRight + 1)
                lastRight = right.number
            }
        }
        #expect(lastLeft == document.leftLines.count)
        #expect(lastRight == document.rightLines.count)
    }

    @Test func rowTextMatchesTheUnderlyingFiles() throws {
        let document = try document(for: "Greeter.swift", path: "Sources/Greeter.swift")
        for row in document.rows {
            if let left = row.left { #expect(left.text == document.leftLines[left.number - 1]) }
            if let right = row.right { #expect(right.text == document.rightLines[right.number - 1]) }
        }
    }

    @Test func pairsRemovalsWithAdditionsAndMarksChangedWords() throws {
        let document = try document(for: "settings.json", path: "Config/settings.json")
        let versionRow = try #require(document.rows.first {
            $0.left?.text.contains("\"version\"") == true
        })
        #expect(versionRow.kind == .modified)
        #expect(!versionRow.left!.changedRanges.isEmpty)
        #expect(!versionRow.right!.changedRanges.isEmpty)
        // Only the version number differs, so the highlight must not cover the key.
        let highlighted = versionRow.right!.changedRanges.map { range in
            String(Array(versionRow.right!.text)[range])
        }.joined()
        #expect(highlighted.contains("3"))
        #expect(!highlighted.contains("version"))
    }

    @Test func foldsLongRunsOfUnchangedContext() throws {
        let document = try document(for: "Greeter.swift", path: "Sources/Greeter.swift")
        #expect(!document.folds.isEmpty)
        for fold in document.folds {
            #expect(fold.count > 0)
            for index in fold.range {
                #expect(document.rows[index].kind == .unchanged)
            }
        }
    }

    @Test func newFilesRenderWithAnEmptyLeftSide() throws {
        let file = try entry(try sampleDiff(), named: "Farewell.swift")
        let lines = file.hunks.flatMap { $0.newLines }
        let applied = [PatchApplier.AppliedHunk(
            hunk: DiffHunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: lines.count,
                           heading: "", lines: lines.map { HunkLine(kind: .added, text: $0) }),
            originalIndex: 0, newIndex: 0, offset: 0, fuzzy: false)]
        let document = SideBySideBuilder.build(applied: applied, originalRaw: [],
                                              patchedRaw: lines, warnings: [])
        #expect(document.rows.allSatisfy { $0.left == nil })
        #expect(document.rows.count == lines.count)
        #expect(document.rows.allSatisfy { $0.kind == .added })
    }

    @Test func diffOnlyModeStillAlignsHunks() throws {
        let file = try entry(try sampleDiff(), named: "Greeter.swift")
        let document = SideBySideBuilder.buildDiffOnly(file: file, warnings: [])
        #expect(document.isDiffOnly)
        #expect(!document.rows.isEmpty)
        let gaps = document.rows.filter {
            if case .gap = $0.kind { return true }
            return false
        }
        #expect(gaps.count == file.hunks.count)
    }

    @Test func expandsTabsConsistentlyOnBothSides() {
        let original = ["\tone", "\t\ttwo"]
        let patched = ["\tone", "\t\tTWO"]
        let hunks = DiffParser.parse(text: """
        --- a/x
        +++ b/x
        @@ -1,2 +1,2 @@
         \tone
        -\t\ttwo
        +\t\tTWO
        """).files[0].hunks
        let applied = try! PatchApplier.apply(hunks: hunks, to: original)
        #expect(applied.newLines == patched)
        let document = SideBySideBuilder.build(applied: applied.applied, originalRaw: original,
                                              patchedRaw: applied.newLines, warnings: [])
        #expect(document.rows[0].left?.text == "    one")
        #expect(document.rows[1].right?.text == "        TWO")
    }
}

// MARK: - Word diff

@Suite("Word diff")
struct WordDiffTests {

    private func changed(_ text: String, _ ranges: [Range<Int>]) -> [String] {
        let characters = Array(text)
        return ranges.map { String(characters[$0]) }
    }

    @Test func highlightsOnlyTheChangedToken() throws {
        let result = try #require(WordDiff.compare(left: "let retries = 3",
                                                   right: "let retries = 5"))
        #expect(changed("let retries = 3", result.left) == ["3"])
        #expect(changed("let retries = 5", result.right) == ["5"])
    }

    @Test func highlightsInsertedWords() throws {
        let result = try #require(WordDiff.compare(left: "func greet(name: String)",
                                                   right: "func greet(name: String, loudly: Bool)"))
        #expect(changed("func greet(name: String, loudly: Bool)", result.right)
            .joined().contains("loudly"))
        #expect(result.left.isEmpty)
    }

    @Test func skipsUnrelatedLines() {
        #expect(WordDiff.compare(left: "import Foundation",
                                 right: "let x = compute(a, b, c) + 42") == nil)
    }

    @Test func returnsNilForIdenticalText() {
        #expect(WordDiff.compare(left: "same", right: "same") == nil)
    }
}

// MARK: - Path resolution

@Suite("Path resolution")
struct PathResolutionTests {

    @Test func stripsGitPrefixes() {
        #expect(PathResolver.stripVCSPrefix("a/src/main.swift") == "src/main.swift")
        #expect(PathResolver.stripVCSPrefix("src/main.swift") == "src/main.swift")
    }

    @Test func offersProgressivelyStrippedCandidates() {
        let candidates = PathResolver.candidates(for: "a/deep/nested/file.txt")
        #expect(candidates.first == "deep/nested/file.txt")
        #expect(candidates.contains("nested/file.txt"))
        #expect(candidates.contains("file.txt"))
    }

    @Test func findsTheSampleProjectFromTheDiffLocation() throws {
        let parsed = try sampleDiff()
        let base = try #require(PathResolver.inferBaseFolder(
            diffURL: samplesRoot.appendingPathComponent("example.diff"), files: parsed.files))
        #expect(base.standardizedFileURL.path == sampleProject.standardizedFileURL.path)
    }

    @Test func resolvesEachEntryAgainstTheInferredBase() throws {
        let parsed = try sampleDiff()
        let resolved = parsed.files.compactMap {
            PathResolver.resolve(path: $0.rawOldPath ?? "", base: sampleProject)
        }
        // Everything except the added file exists on disk.
        #expect(resolved.count == 3)
    }
}

// MARK: - Syntax highlighting

@Suite("Syntax highlighting")
struct SyntaxHighlightingTests {

    private func kinds(_ line: String, in lines: [String], spec: LanguageSpec) -> [TokenKind] {
        let table = SyntaxHighlighter.highlight(lines: lines, spec: spec)
        guard let index = lines.firstIndex(of: line) else { return [] }
        return table[index].map(\.kind)
    }

    @Test func picksLanguageFromExtension() {
        #expect(LanguageCatalog.spec(forPath: "Sources/Main.swift").name == "Swift")
        #expect(LanguageCatalog.spec(forPath: "app/settings.json").name == "JSON")
        #expect(LanguageCatalog.spec(forPath: "force-app/AccountService.cls").name == "Apex")
        #expect(LanguageCatalog.spec(forPath: "objects/Account.object-meta.xml").name == "XML")
        #expect(LanguageCatalog.spec(forPath: "notes.txt").name == "Text")
    }

    @Test func coloursKeywordsAndStrings() {
        let line = #"let greeting = "Hello""#
        let spans = SyntaxHighlighter.highlight(lines: [line], spec: LanguageCatalog.swift)[0]
        #expect(spans.contains { $0.kind == .keyword })
        #expect(spans.contains { $0.kind == .string })
    }

    @Test func carriesBlockCommentStateAcrossLines() {
        let lines = ["/* opening", "still comment", "closing */ let x = 1"]
        let table = SyntaxHighlighter.highlight(lines: lines, spec: LanguageCatalog.swift)
        #expect(table[1].allSatisfy { $0.kind == .comment })
        #expect(table[1].first?.range == 0..<lines[1].count)
        #expect(table[2].contains { $0.kind == .comment })
        #expect(table[2].contains { $0.kind == .keyword })
    }

    @Test func spansStayInsideTheLine() {
        let lines = ["let a = \"unterminated", "let b = 2"]
        let table = SyntaxHighlighter.highlight(lines: lines, spec: LanguageCatalog.swift)
        for (index, spans) in table.enumerated() {
            for span in spans {
                #expect(span.range.lowerBound >= 0)
                #expect(span.range.upperBound <= lines[index].count)
            }
        }
    }

    @Test func leavesPlainTextAlone() {
        let table = SyntaxHighlighter.highlight(lines: ["just some prose"], spec: .plain)
        #expect(table[0].isEmpty)
    }
}

// MARK: - Search

@Suite("Search")
struct SearchTests {

    @Test func findsEveryOccurrence() {
        let ranges = AppState.occurrences(of: Array("re"), in: "retries retried", caseSensitive: true)
        #expect(ranges == [0..<2, 8..<10])
    }

    @Test func honoursCaseSensitivity() {
        #expect(AppState.occurrences(of: Array("hello"), in: "Hello", caseSensitive: true).isEmpty)
        #expect(AppState.occurrences(of: Array("hello"), in: "Hello", caseSensitive: false) == [0..<5])
    }

    @Test func doesNotOverlapMatches() {
        let ranges = AppState.occurrences(of: Array("aa"), in: "aaaa", caseSensitive: true)
        #expect(ranges == [0..<2, 2..<4])
    }
}

// MARK: - Line rendering

@Suite("Line rendering")
struct LineRenderingTests {

    @Test func keepsEveryCharacterWhenMergingSyntaxAndWordDiff() {
        let text = #"let version = "1.3.0""#
        let spans = SyntaxHighlighter.highlight(lines: [text], spec: LanguageCatalog.swift)[0]
        let attributed = LineRenderer.build(text: text, spans: spans,
                                            changedRanges: [15..<20], isRemoved: false)
        #expect(String(attributed.characters) == text)
    }

    @Test func rendersEmptyLinesAsASingleSpaceSoRowsKeepTheirHeight() {
        let attributed = LineRenderer.build(text: "", spans: [], changedRanges: [], isRemoved: false)
        #expect(String(attributed.characters) == " ")
    }

    @Test func searchHighlightDoesNotChangeTheText() {
        let base = LineRenderer.build(text: "retries", spans: [], changedRanges: [], isRemoved: false)
        let highlighted = LineRenderer.highlighting(base, ranges: [0..<2], current: 0..<2)
        #expect(String(highlighted.characters) == "retries")
    }
}
