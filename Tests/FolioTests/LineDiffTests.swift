import Foundation
import Testing

@testable import Folio

/// The first diff Folio computes rather than reads, so it is pinned closely.
@Suite("Line diff")
struct LineDiffTests {

    /// Replays the hunks the way the split view does, which is the only definition of
    /// correct that matters: applying them to the original must produce the updated file.
    private func roundTrips(_ original: [String], _ updated: [String],
                            sourceLocation: SourceLocation = #_sourceLocation) {
        let result = LineDiff.compare(original: original, updated: updated)
        let hunks = result.applied.map(\.hunk)
        guard !hunks.isEmpty else {
            #expect(original == updated, "no hunks, so the files should be identical",
                    sourceLocation: sourceLocation)
            return
        }
        do {
            let applied = try PatchApplier.apply(hunks: hunks, to: original)
            #expect(applied.newLines == updated, sourceLocation: sourceLocation)
        } catch {
            Issue.record("the hunks did not apply: \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func identicalFilesProduceNothing() {
        let result = LineDiff.compare(original: ["a", "b", "c"], updated: ["a", "b", "c"])
        #expect(result.isEmpty)
        #expect(!result.isCoarse)
    }

    @Test func bothEmpty() {
        #expect(LineDiff.compare(original: [], updated: []).isEmpty)
    }

    @Test func aSingleChangedLine() {
        let original = ["one", "two", "three"]
        let updated = ["one", "TWO", "three"]
        let result = LineDiff.compare(original: original, updated: updated)
        #expect(result.applied.count == 1)
        let hunk = result.applied[0].hunk
        #expect(hunk.oldLines == original)
        #expect(hunk.newLines == updated)
        roundTrips(original, updated)
    }

    @Test func insertionsAndDeletionsAtTheEnds() {
        roundTrips([], ["new"])
        roundTrips(["gone"], [])
        roundTrips(["a", "b"], ["prefix", "a", "b"])
        roundTrips(["a", "b"], ["a", "b", "suffix"])
        roundTrips(["a", "b", "c"], ["b", "c"])
        roundTrips(["a", "b", "c"], ["a", "b"])
    }

    @Test func aWholesaleRewrite() {
        roundTrips(["one", "two", "three"], ["alpha", "beta"])
    }

    @Test func twoDistantChangesBecomeTwoHunks() {
        var original = (1...40).map { "line \($0)" }
        var updated = original
        updated[2] = "changed near the top"
        updated[37] = "changed near the bottom"
        let result = LineDiff.compare(original: original, updated: updated)
        #expect(result.applied.count == 2)
        roundTrips(original, updated)

        // And two changes close together stay in one hunk, or their context would overlap.
        original = (1...40).map { "line \($0)" }
        updated = original
        updated[10] = "changed"
        updated[12] = "also changed"
        #expect(LineDiff.compare(original: original, updated: updated).applied.count == 1)
    }

    @Test func contextSurroundsEachChange() {
        let original = (1...20).map { "line \($0)" }
        var updated = original
        updated[9] = "changed"
        let hunk = try! #require(LineDiff.compare(original: original, updated: updated)
            .applied.first?.hunk)
        // Three lines either side, as a unified diff carries.
        #expect(hunk.lines.prefix(3).allSatisfy { $0.kind == .context })
        #expect(hunk.lines.suffix(3).allSatisfy { $0.kind == .context })
        #expect(hunk.oldStart == 7)
        #expect(hunk.newStart == 7)
    }

    /// The realistic case: a model rewrites one paragraph of a long note.
    @Test func oneParagraphChangedInALongDocument() {
        let original = (1...4_000).map { "This is line \($0) of a long document." }
        var updated = original
        updated[1_999] = "This paragraph was rewritten."
        updated.insert("And a sentence was added.", at: 2_000)

        let result = LineDiff.compare(original: original, updated: updated)
        #expect(result.applied.count == 1)
        #expect(!result.isCoarse)
        roundTrips(original, updated)
    }

    @Test func repeatedLinesAlignSensibly() {
        // Blank lines and repeated markers are everywhere in Markdown, and a careless
        // diff pairs the wrong ones.
        let original = ["# A", "", "text", "", "# B", "", "text"]
        let updated = ["# A", "", "text", "", "# B", "", "different"]
        roundTrips(original, updated)
    }

    @Test func aFileTooLargeToAlignIsReportedAsReplacedRatherThanStalling() {
        // Past the ceiling, and deliberately sharing no lines so trimming cannot help.
        let original = (1...2_500).map { "old \($0)" }
        let updated = (1...2_500).map { "new \($0)" }
        let result = LineDiff.compare(original: original, updated: updated)
        #expect(result.isCoarse)
        roundTrips(original, updated)
    }

    @Test func trimmingKeepsALargeFileOutOfTheCeiling() {
        // Same size as above, but almost all of it identical: trimming the common ends
        // leaves a middle small enough to align properly.
        let original = (1...2_500).map { "line \($0)" }
        var updated = original
        updated[1_250] = "changed"
        let result = LineDiff.compare(original: original, updated: updated)
        #expect(!result.isCoarse)
        #expect(result.applied.count == 1)
    }

    @Test func theHunksFeedTheSplitViewCorrectly() {
        let original = ["keep", "old", "tail"]
        let updated = ["keep", "new", "tail"]
        let result = LineDiff.compare(original: original, updated: updated)
        let document = SideBySideBuilder.build(applied: result.applied,
                                               originalRaw: original,
                                               patchedRaw: updated,
                                               warnings: [])
        #expect(document.leftLines == original)
        #expect(document.rightLines == updated)
        // The changed pair lines up as one modified row rather than a delete and an add.
        #expect(document.rows.contains { $0.kind == .modified })
    }
}
