import AppKit
import SwiftUI
import Testing

@testable import Folio

/// Regenerates the screenshots in `Docs/`.
///
/// Off unless asked for, because it writes files:
///
///     FOLIO_SCREENSHOTS=Docs swift test --filter Screenshots
///
/// They are rendered from the app's own views rather than captured from a window, which
/// is the only option on a machine with no screen-recording permission — and has the
/// happy side effect of making them reproducible. Views that come out blank offscreen
/// (`Menu`, `ScrollView`, `List`) are composed from the pieces inside them instead, which
/// is why several of those pieces are not private.
@MainActor
@Suite("Screenshots", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["FOLIO_SCREENSHOTS"] != nil))
struct ScreenshotTests {

    private var folder: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLIO_SCREENSHOTS"]!)
    }

    private func write(_ name: String, width: CGFloat,
                       @ViewBuilder _ content: () -> some View) throws {
        let renderer = ImageRenderer(content:
            content()
                .frame(width: width)
                .padding(14)
                .background(Color(.windowBackgroundColor)))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?
            .representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("\(name).png"))
    }

    private func tab(_ name: String, _ content: DocumentContent = .markdown,
                     group: String? = nil, dirty: Bool = false) -> DocumentTab {
        let tab = DocumentTab(url: URL(fileURLWithPath: "/Users/you/notes/\(name)"),
                              content: content)
        tab.group = group
        if dirty { tab.draftText = "edited" }
        return tab
    }

    private func snapshot(_ state: GitSnapshot.FileState, ahead: Int = 0, behind: Int = 0,
                          added: Int = 0, removed: Int = 0,
                          branch: String? = "main") -> GitSnapshot {
        GitSnapshot(root: URL(fileURLWithPath: "/Users/you/notes", isDirectory: true),
                    branch: branch, upstream: "origin/main", behind: behind, ahead: ahead,
                    fileState: state, addedLines: added, removedLines: removed,
                    hasIdentity: true)
    }

    // MARK: - The pictures

    @Test func tabs() throws {
        let state = AppState()
        try write("tabs", width: 1100) {
            HStack(spacing: 0) {
                TabChip(tab: tab("example.md"), isActive: false, isHovered: false,
                        isDragging: false, minimumWidth: 84, maximumWidth: 260)
                TabChip(tab: tab("example.diff", .diff), isActive: true, isHovered: false,
                        isDragging: false, minimumWidth: 84, maximumWidth: 260)
                TabChip(tab: tab("weekly-review.md", dirty: true), isActive: false,
                        isHovered: true, isDragging: false,
                        minimumWidth: 84, maximumWidth: 260)
                TabChip(tab: tab("WordDiff.swift", .source), isActive: false,
                        isHovered: false, isDragging: false,
                        minimumWidth: 84, maximumWidth: 260)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 28, height: 26)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .background(Theme.gutterBackground)
            .overlay(alignment: .bottom) { Divider() }
            .environment(state)
        }
    }

    @Test func gitStatus() throws {
        func row(_ caption: String, _ label: GitStatusLabel) -> some View {
            HStack(spacing: 12) {
                Text(caption)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(width: 150, alignment: .trailing)
                label
                Spacer(minLength: 0)
            }
        }
        try write("git-status", width: 420) {
            VStack(alignment: .leading, spacing: 7) {
                row("nothing to do", GitStatusLabel(snapshot: snapshot(.committed)))
                row("two commits to push",
                    GitStatusLabel(snapshot: snapshot(.committed, ahead: 2)))
                row("edited since the commit",
                    GitStatusLabel(snapshot: snapshot(.modified, added: 12, removed: 3)))
                row("edits still in the editor",
                    GitStatusLabel(snapshot: snapshot(.committed), hasUnsavedEdits: true))
                row("not in the repository yet",
                    GitStatusLabel(snapshot: snapshot(.untracked)))
                row("an unfinished merge",
                    GitStatusLabel(snapshot: snapshot(.conflicted, ahead: 1, behind: 3)))
            }
        }
    }

    @Test func history() throws {
        // Fixed dates, not offsets from now: a committed picture that changes every time
        // the suite runs shows up as noise in every diff. These are old enough that the
        // list writes them out in full rather than as "2h ago", which is what makes the
        // rendering stable.
        let day: TimeInterval = 86_400
        let reference = Date(timeIntervalSince1970: 1_780_000_000)
        func commit(_ subject: String, ago: TimeInterval, hash: String,
                    _ coAuthors: [String] = []) -> GitCommitSummary {
            GitCommitSummary(hash: hash, shortHash: hash, author: "You",
                             date: reference.addingTimeInterval(-ago), subject: subject,
                             path: "weekly-review.md", coAuthors: coAuthors)
        }
        try write("history", width: 300) {
            VStack(alignment: .leading, spacing: 2) {
                CommitRow(commit: commit("Draft this week's retrospective", ago: 40 * day,
                                         hash: "a1b2c3d",
                                         ["Claude Opus 5 <noreply@anthropic.com>"]),
                          isCurrent: false, isFirst: true)
                CommitRow(commit: commit("Rewrite the summary in my own words",
                                         ago: 60 * day, hash: "9f8e7d6"),
                          isCurrent: true, isFirst: false)
                CommitRow(commit: commit("Add the outcomes section", ago: 90 * day,
                                         hash: "0011223",
                                         ["Claude Opus 5 <noreply@anthropic.com>"]),
                          isCurrent: false, isFirst: false)
            }
        }
    }

    @Test func notes() throws {
        func annotation(_ kind: Annotation.Kind, _ quote: String, _ lines: ClosedRange<Int>,
                        _ comment: String) -> Annotation {
            Annotation(kind: kind, quote: quote, startLine: lines.lowerBound,
                       endLine: lines.upperBound, comment: comment)
        }
        try write("notes", width: 300) {
            VStack(alignment: .leading, spacing: 2) {
                AnnotationRow(annotation: annotation(
                    .changeRequest, "Contacts carry no channel, editing is open to anyone",
                    2...3, "Split this into two sentences and name the role explicitly."))
                AnnotationRow(annotation: annotation(
                    .note, "Indirect reps never see the dealer's end customer",
                    8...8, "Check this against the register — C-1 may contradict it."))
                AnnotationRow(annotation: annotation(
                    .changeRequest, "Actors", 5...5, "Rename to \"Roles\" throughout."))
            }
        }
    }

    @Test func groups() throws {
        let state = AppState()
        try write("groups", width: 620) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("in the title bar")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .frame(width: 120, alignment: .trailing)
                    GroupPickerLabel(group: "Acme rollout")
                        .fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.gutterBackground,
                                    in: RoundedRectangle(cornerRadius: 6))
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    Text("the tabs it shows")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .frame(width: 120, alignment: .trailing)
                    HStack(spacing: 0) {
                        TabChip(tab: tab("brief.md", group: "Acme rollout"),
                                isActive: true, isHovered: false, isDragging: false,
                                minimumWidth: 84, maximumWidth: 200)
                        TabChip(tab: tab("timeline.md", group: "Acme rollout"),
                                isActive: false, isHovered: false, isDragging: false,
                                minimumWidth: 84, maximumWidth: 200)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6).padding(.top, 4)
                    .background(Theme.gutterBackground)
                }
            }
            .environment(state)
        }
    }
}
