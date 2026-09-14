import Foundation
import Testing
@testable import Folio

@Suite("Parse probe", .enabled(if: ProcessInfo.processInfo.environment["FOLIO_PROBE"] != nil))
struct ParseProbe {
    @Test func realDiff() throws {
        let text = try String(contentsOf: URL(fileURLWithPath:
            "/private/tmp/claude-502/-Users-wijnenr-Repositories-claude-diff-viewer/da745e43-b542-4250-ac1e-af2a9b5264ef/scratchpad/spaced.diff"), encoding: .utf8)
        let parsed = DiffParser.parse(text: text)
        print("PROBE files parsed: \(parsed.files.count)")
        for f in parsed.files {
            print("PROBE   rawOld=\(f.rawOldPath ?? "nil")")
            print("PROBE   rawNew=\(f.rawNewPath ?? "nil")")
            print("PROBE   display=\(f.displayPath)  hunks=\(f.hunks.count) +\(f.additions) -\(f.deletions)")
        }
    }
}
