import SwiftUI
import AppKit

/// A first-responder `NSView` that captures raw mouse and keyboard `NSEvent`s
/// and forwards them to closures. Coordinates are reported flipped (top-left
/// origin) to match the framebuffer / stream coordinate math the remote
/// protocols use. The hosting SwiftUI view maps the events to VNC or Moonlight
/// input.
///
/// This is the macOS counterpart of the visionOS gesture handling + the UIKit
/// `KeyCaptureView`; on macOS a normal window view gets first responder cleanly,
/// so there's no GameController dance.
final class InputSurfaceNSView: NSView {
    var onMouseMove: ((CGPoint) -> Void)?
    /// button: 0 = left, 1 = right, 2 = middle
    var onMouseDown: ((Int, CGPoint) -> Void)?
    var onMouseUp: ((Int, CGPoint) -> Void)?
    var onScroll: ((CGFloat, CGFloat) -> Void)?
    var onKeyDown: ((NSEvent) -> Void)?
    var onKeyUp: ((NSEvent) -> Void)?
    var onFlagsChanged: ((NSEvent) -> Void)?

    /// When true, hide the system pointer while it's inside this view (so only
    /// the remote's own cursor shows). Toggling re-balances the hide/unhide.
    var hideCursorWhenInside: Bool = false {
        didSet {
            guard hideCursorWhenInside != oldValue, pointerInside else { return }
            if hideCursorWhenInside { NSCursor.hide() } else { NSCursor.unhide() }
        }
    }
    private var pointerInside = false

    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // Click into the view without first activating the window swallowing the click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        if hideCursorWhenInside { NSCursor.hide() }
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        if hideCursorWhenInside { NSCursor.unhide() }
    }

    // Balance any outstanding hide() if the view goes away while the cursor is in.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, pointerInside, hideCursorWhenInside {
            NSCursor.unhide()
            pointerInside = false
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseMoved(with event: NSEvent) { onMouseMove?(point(event)) }
    override func mouseDragged(with event: NSEvent) { onMouseMove?(point(event)) }
    override func rightMouseDragged(with event: NSEvent) { onMouseMove?(point(event)) }
    override func otherMouseDragged(with event: NSEvent) { onMouseMove?(point(event)) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onMouseDown?(0, point(event))
    }
    override func mouseUp(with event: NSEvent) { onMouseUp?(0, point(event)) }
    override func rightMouseDown(with event: NSEvent) { onMouseDown?(1, point(event)) }
    override func rightMouseUp(with event: NSEvent) { onMouseUp?(1, point(event)) }
    override func otherMouseDown(with event: NSEvent) { onMouseDown?(2, point(event)) }
    override func otherMouseUp(with event: NSEvent) { onMouseUp?(2, point(event)) }

    override func scrollWheel(with event: NSEvent) {
        // Prefer precise (trackpad) deltas; fall back to line deltas for a wheel.
        let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        onScroll?(dx, dy)
    }

    override func keyDown(with event: NSEvent) { onKeyDown?(event) }
    override func keyUp(with event: NSEvent) { onKeyUp?(event) }
    override func flagsChanged(with event: NSEvent) { onFlagsChanged?(event) }

    // Forward Command-key shortcuts (Cmd+W, Cmd+C, Cmd+T, …) to the remote
    // session instead of letting the local menu act on them — otherwise Cmd+W
    // would close this window, etc. Cmd+Q stays local so the user can always
    // quit. Synthesize down+up here (performKeyEquivalent has no key-up); the
    // Command modifier itself is forwarded separately via flagsChanged.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), window?.firstResponder === self else { return false }
        if event.charactersIgnoringModifiers?.lowercased() == "q" { return false } // keep Quit local
        onKeyDown?(event)
        onKeyUp?(event)
        return true
    }
}

/// SwiftUI wrapper for `InputSurfaceNSView`.
struct MacInputSurface: NSViewRepresentable {
    var onMouseMove: ((CGPoint) -> Void)? = nil
    var onMouseDown: ((Int, CGPoint) -> Void)? = nil
    var onMouseUp: ((Int, CGPoint) -> Void)? = nil
    var onScroll: ((CGFloat, CGFloat) -> Void)? = nil
    var onKeyDown: ((NSEvent) -> Void)? = nil
    var onKeyUp: ((NSEvent) -> Void)? = nil
    var onFlagsChanged: ((NSEvent) -> Void)? = nil
    var hideCursorWhenInside: Bool = false

    func makeNSView(context: Context) -> InputSurfaceNSView {
        let view = InputSurfaceNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: InputSurfaceNSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: InputSurfaceNSView) {
        view.onMouseMove = onMouseMove
        view.onMouseDown = onMouseDown
        view.onMouseUp = onMouseUp
        view.onScroll = onScroll
        view.onKeyDown = onKeyDown
        view.onKeyUp = onKeyUp
        view.onFlagsChanged = onFlagsChanged
        view.hideCursorWhenInside = hideCursorWhenInside
    }
}
