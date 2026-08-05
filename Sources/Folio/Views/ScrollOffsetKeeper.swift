import AppKit
import SwiftUI

/// Remembers where each of a document's scroll views was left.
///
/// Keyed by view, so a diff's split view, its individual files and the Markdown source
/// listing all keep their own place.
@MainActor
final class ScrollOffsetStore {

    private var offsets: [String: CGFloat] = [:]

    func offset(for key: String) -> CGFloat { offsets[key] ?? 0 }

    func record(_ offset: CGFloat, for key: String) { offsets[key] = offset }

    func forgetAll() { offsets.removeAll() }
}

/// A zero-sized probe placed inside a SwiftUI `ScrollView`.
///
/// SwiftUI (on macOS 14) offers no way to read or set a scroll offset, so this reaches
/// the `NSScrollView` that backs it: it records the offset as the reader scrolls and
/// puts it back when the view reappears — which is what makes returning to a tab resume
/// where you left off.
struct ScrollOffsetKeeper: NSViewRepresentable {

    let key: String
    let store: ScrollOffsetStore

    func makeNSView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.configure(key: key, store: store)
    }

    final class ProbeView: NSView {

        private var key: String?
        private var store: ScrollOffsetStore?
        private var observation: NSObjectProtocol?
        private var restoreAttempts = 0
        /// Set while replaying an offset, so the intermediate positions of a lazily
        /// laid-out stack are not written back over the value we are aiming for.
        private var isRestoring = false

        deinit {
            if let observation { NotificationCenter.default.removeObserver(observation) }
        }

        func configure(key newKey: String, store newStore: ScrollOffsetStore) {
            let changed = key != newKey || store !== newStore
            key = newKey
            store = newStore
            guard changed else { return }
            restoreAttempts = 0
            scheduleRestore()
        }

        // Both hooks matter: the probe is usually inserted into the document view
        // before it has a window, and re-parented later.
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            guard superview != nil else { return }
            attachAndRestore()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            attachAndRestore()
        }

        private func attachAndRestore() {
            attachToScrollView()
            restoreAttempts = 0
            scheduleRestore()
        }

        private func attachToScrollView() {
            guard let clipView = enclosingScrollView?.contentView else { return }
            clipView.postsBoundsChangedNotifications = true
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.record() }
            }
        }

        private func record() {
            guard !isRestoring, let key, let store, let scrollView = enclosingScrollView else { return }
            store.record(scrollView.contentView.bounds.origin.y, for: key)
        }

        private func scheduleRestore() {
            guard let key, let store else { return }
            let target = store.offset(for: key)
            guard target > 1 else { return }
            isRestoring = true
            // Straight away, not deferred: when the content is already tall enough this
            // lands in the same layout pass, with no visible jump from the top.
            applyRestore(target: target)
        }

        private func applyRestore(target: CGFloat) {
            guard let scrollView = enclosingScrollView else {
                isRestoring = false
                return
            }
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let visibleHeight = scrollView.contentView.bounds.height
            let reachable = max(documentHeight - visibleHeight, 0)
            let clamped = min(target, reachable)
            scrollView.contentView.scroll(to: CGPoint(x: scrollView.contentView.bounds.origin.x,
                                                      y: clamped))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            restoreAttempts += 1
            // A LazyVStack only grows as it lays out, so the first attempt often cannot
            // reach far enough down. Keep nudging until it can, then stop.
            if clamped < target - 0.5, restoreAttempts < 14 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                    self?.applyRestore(target: target)
                }
            } else {
                isRestoring = false
            }
        }
    }
}

extension View {
    /// Attach inside a `ScrollView` to make it resume where it was left.
    func keepsScrollOffset(key: String, store: ScrollOffsetStore) -> some View {
        background(
            ScrollOffsetKeeper(key: key, store: store)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}
