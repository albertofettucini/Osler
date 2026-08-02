import AppKit
import SwiftUI

/// Makes two-finger trackpad scrolling (and mouse wheels) pan the canvas, and
/// reports raw mouse-downs inside the canvas for instant node selection.
///
/// SwiftUI has no scroll-wheel gesture, and an NSView placed behind SwiftUI
/// content never receives `scrollWheel` — the hosting view claims the hit and
/// bubbles the event up the responder chain, away from subviews. So instead of
/// relying on hit-testing, this installs local event monitors and handles any
/// event that lands inside the canvas area of our window.
///
/// The mouse-down monitor only OBSERVES (the event is always passed through) —
/// selection must never compete with SwiftUI's drag/tap gestures, which is
/// exactly what a zero-distance gesture on the node card would do.
struct ScrollPanCatcher: NSViewRepresentable {
    var onScroll: (CGSize) -> Void
    var onMouseDown: ((CGPoint, NSEvent.ModifierFlags) -> Void)?

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        view.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onMouseDown = onMouseDown
    }

    final class CatcherView: NSView {
        var onScroll: ((CGSize) -> Void)?
        var onMouseDown: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
        private var scrollMonitor: Any?
        private var mouseMonitor: Any?

        // Top-left origin, so reported points match SwiftUI's canvas space.
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitors()
                return
            }
            if scrollMonitor == nil {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else {
                        return event
                    }
                    // Only scrolls over the canvas area; the rest of the app
                    // (inspector text, library) keeps normal scrolling.
                    let point = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(point) else { return event }
                    // Trackpads deliver precise pixel deltas; mouse wheels
                    // deliver line ticks that need scaling to feel similar.
                    let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                    self.onScroll?(CGSize(
                        width: event.scrollingDeltaX * scale,
                        height: event.scrollingDeltaY * scale
                    ))
                    return nil // consumed
                }
            }
            if mouseMonitor == nil {
                mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else {
                        return event
                    }
                    let point = self.convert(event.locationInWindow, from: nil)
                    if self.bounds.contains(point) {
                        self.onMouseDown?(point, event.modifierFlags)
                    }
                    return event // observe only — NEVER consume
                }
            }
        }

        private func removeMonitors() {
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
                self.scrollMonitor = nil
            }
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
        }

        deinit {
            removeMonitors()
        }
    }
}
