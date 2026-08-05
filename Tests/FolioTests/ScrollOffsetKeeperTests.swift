import AppKit
import Testing

@testable import Folio

/// Exercises the AppKit bridge that gives the diff and source listings their scroll
/// memory. SwiftUI is not involved: the probe is driven against a real `NSScrollView`
/// the same way SwiftUI would place it inside one.
@Suite("Scroll offset bridge", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["FOLIO_SKIP_UI_TESTS"] == nil,
                "needs a GUI session (AppKit and WebKit views)"))
@MainActor
struct ScrollOffsetKeeperTests {

    private func pump(_ seconds: Double = 0.35) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// A scroll view with a tall document. Deliberately not in a window: this test
    /// bundle has no NSApplication, and the probe attaches on superview changes too.
    private func makeScrollView() -> (scrollView: NSScrollView, document: NSView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.hasVerticalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 3000))
        scrollView.documentView = document
        scrollView.layoutSubtreeIfNeeded()
        return (scrollView, document)
    }

    private func scroll(_ scrollView: NSScrollView, to offset: CGFloat) {
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @Test func recordsTheOffsetAsTheReaderScrolls() {
        let store = ScrollOffsetStore()
        let (scrollView, document) = makeScrollView()

        let probe = ScrollOffsetKeeper.ProbeView()
        document.addSubview(probe)
        probe.configure(key: "source", store: store)
        pump()

        scroll(scrollView, to: 1200)
        pump()
        #expect(store.offset(for: "source") == 1200)

        scroll(scrollView, to: 640)
        pump()
        #expect(store.offset(for: "source") == 640)
    }

    @Test func putsAFreshViewBackWhereTheLastOneWas() {
        let store = ScrollOffsetStore()
        store.record(1500, for: "diff:abc")

        let (scrollView, document) = makeScrollView()

        // A brand-new probe, as SwiftUI builds when a tab is shown again.
        let probe = ScrollOffsetKeeper.ProbeView()
        document.addSubview(probe)
        probe.configure(key: "diff:abc", store: store)
        pump(0.6)

        #expect(abs(scrollView.contentView.bounds.origin.y - 1500) < 1)
    }

    @Test func doesNotScrollWhenThereIsNothingRemembered() {
        let store = ScrollOffsetStore()
        let (scrollView, document) = makeScrollView()

        let probe = ScrollOffsetKeeper.ProbeView()
        document.addSubview(probe)
        probe.configure(key: "unseen", store: store)
        pump()

        #expect(scrollView.contentView.bounds.origin.y == 0)
    }

    @Test func clampsToWhatTheDocumentCanActuallyReach() {
        let store = ScrollOffsetStore()
        // Further than the document is tall — a stale offset after the file shrank.
        store.record(99_000, for: "source")

        let (scrollView, document) = makeScrollView()

        let probe = ScrollOffsetKeeper.ProbeView()
        document.addSubview(probe)
        probe.configure(key: "source", store: store)
        pump(0.8)

        let reachable = document.bounds.height - scrollView.contentView.bounds.height
        #expect(scrollView.contentView.bounds.origin.y <= reachable + 1)
        #expect(scrollView.contentView.bounds.origin.y > 0)
    }

    @Test func switchingKeysSwitchesRememberedPositions() {
        let store = ScrollOffsetStore()
        store.record(800, for: "markdown-source")
        store.record(200, for: "source")

        let (scrollView, document) = makeScrollView()

        let probe = ScrollOffsetKeeper.ProbeView()
        document.addSubview(probe)
        probe.configure(key: "markdown-source", store: store)
        pump(0.6)
        #expect(abs(scrollView.contentView.bounds.origin.y - 800) < 1)

        // Reusing the same probe for another view, as SwiftUI does when the tab changes.
        probe.configure(key: "source", store: store)
        pump(0.6)
        #expect(abs(scrollView.contentView.bounds.origin.y - 200) < 1)
    }
}
