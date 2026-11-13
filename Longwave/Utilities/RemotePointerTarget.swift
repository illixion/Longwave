import CoreGraphics
import RoyalVNCKit
#if MOONLIGHT_ENABLED
@preconcurrency import MoonlightCommonC
#endif

/// A mouse button, independent of each protocol's own codes.
enum RemotePointerButton: Hashable, Sendable {
    case left, right, middle, back, forward
}

/// One remote desktop's pointer — VNC, the Native desktop or a Moonlight
/// stream — in the few verbs the visionOS stream surface
/// (`StreamPointerController`) and the mouse bridge (`StreamMouseBridge`) need.
/// Everything above this line is written once; each protocol only maps the
/// verbs onto its own wire calls.
///
/// Positions are stream pixels. Presses, releases and scrolls act wherever the
/// cursor is, so a Direct-mode click is a move to the point followed by a
/// press and a release there.
@MainActor
protocol RemotePointerTarget: AnyObject {
    /// The remote picture's size in its own pixels; zero until known.
    var pointerStreamSize: CGSize { get }
    /// Direct (absolute) or Touchpad (relative). The ornament flips it.
    var touchMode: TouchMode { get set }
    /// The client-side cursor, for drawing the local dot; nil where only the
    /// host knows where its cursor is (Moonlight).
    var pointerCursor: (x: UInt16, y: UInt16)? { get }
    /// Whether the host paints its own cursor into the stream. macOS Screen
    /// Sharing over VNC doesn't, so with a mouse driving it the surface draws
    /// the local dot instead.
    var hostDrawsCursor: Bool { get }

    /// Puts the cursor on a stream pixel.
    func pointerMove(to point: (x: UInt16, y: UInt16))
    /// Moves the cursor by stream pixels. Fractions may be kept by the target.
    func pointerMove(dx: CGFloat, dy: CGFloat)
    func pointerButton(_ button: RemotePointerButton, pressed: Bool)
    /// Whole line steps at the cursor, in `ScrollStepAccumulator`'s and
    /// `GCMouse`'s sign: +dy scrolls up (content moves down), +dx scrolls left
    /// (content follows the hands to the right).
    func pointerScroll(dx: Int, dy: Int)
}

extension RemotePointerTarget {
    func pointerClick(_ button: RemotePointerButton) {
        pointerButton(button, pressed: true)
        pointerButton(button, pressed: false)
    }
}

// MARK: - VNC

extension VNCConnectionManager: RemotePointerTarget {
    var pointerStreamSize: CGSize { framebufferSize }
    var pointerCursor: (x: UInt16, y: UInt16)? { (virtualCursorX, virtualCursorY) }
    var hostDrawsCursor: Bool { false }

    func pointerMove(to point: (x: UInt16, y: UInt16)) {
        moveCursorAbsolute(x: point.x, y: point.y)
    }

    func pointerMove(dx: CGFloat, dy: CGFloat) {
        moveVirtualCursor(dx: dx, dy: dy)
    }

    func pointerButton(_ button: RemotePointerButton, pressed: Bool) {
        let vncButton: VNCMouseButton
        switch button {
        case .left: vncButton = .left
        case .right: vncButton = .right
        case .middle: vncButton = .middle
        case .back, .forward: return
        }
        if pressed {
            pressMouseAtVirtualCursor(button: vncButton)
        } else {
            releaseMouseAtVirtualCursor(button: vncButton)
        }
    }

    func pointerScroll(dx: Int, dy: Int) {
        if dy != 0 {
            scrollAtVirtualCursor(wheel: dy > 0 ? .up : .down, steps: UInt32(abs(dy)))
        }
        if dx != 0 {
            scrollAtVirtualCursor(wheel: dx > 0 ? .left : .right, steps: UInt32(abs(dx)))
        }
    }
}

// MARK: - Native

extension MacNativeStreamManager: RemotePointerTarget {
    var pointerStreamSize: CGSize { streamSize }
    var pointerCursor: (x: UInt16, y: UInt16)? { (virtualCursorX, virtualCursorY) }
    /// The Mac draws its cursor into the captured stream.
    var hostDrawsCursor: Bool { true }

    func pointerMove(to point: (x: UInt16, y: UInt16)) {
        moveCursorAbsolute(x: point.x, y: point.y)
    }

    func pointerMove(dx: CGFloat, dy: CGFloat) {
        moveVirtualCursor(dx: dx, dy: dy)
    }

    func pointerButton(_ button: RemotePointerButton, pressed: Bool) {
        let nativeButton: MacNativeStreamProtocol.MouseButton
        switch button {
        case .left: nativeButton = .left
        case .right: nativeButton = .right
        case .middle: nativeButton = .other
        case .back, .forward: return
        }
        if pressed {
            pressMouseAtVirtualCursor(button: nativeButton)
        } else {
            releaseMouseAtVirtualCursor(button: nativeButton)
        }
    }

    func pointerScroll(dx: Int, dy: Int) {
        scrollAtVirtualCursor(deltaX: Int16(clamping: dx), deltaY: Int16(clamping: dy))
    }
}

// MARK: - Moonlight

#if MOONLIGHT_ENABLED
extension MoonlightConnectionManager: RemotePointerTarget {
    var pointerStreamSize: CGSize { CGSize(width: streamWidth, height: streamHeight) }
    /// Sunshine and GFE draw the host cursor into the video; where it is
    /// after relative motion only the host knows.
    var pointerCursor: (x: UInt16, y: UInt16)? { nil }
    var hostDrawsCursor: Bool { true }

    func pointerMove(to point: (x: UInt16, y: UInt16)) {
        setExternalCursorPosition(x: Int(point.x), y: Int(point.y))
        library.sendMousePosition(
            x: Int16(clamping: Int(point.x)),
            y: Int16(clamping: Int(point.y)),
            referenceWidth: Int16(clamping: streamWidth),
            referenceHeight: Int16(clamping: streamHeight)
        )
    }

    func pointerMove(dx: CGFloat, dy: CGFloat) {
        let whole = takeRelativeMotion(dx: dx, dy: dy)
        guard whole.dx != 0 || whole.dy != 0 else { return }
        library.sendMouseMove(dx: Int16(clamping: whole.dx), dy: Int16(clamping: whole.dy))
    }

    func pointerButton(_ button: RemotePointerButton, pressed: Bool) {
        let code: Int32
        switch button {
        case .left: code = BUTTON_LEFT
        case .right: code = BUTTON_RIGHT
        case .middle: code = BUTTON_MIDDLE
        case .back: code = BUTTON_X1
        case .forward: code = BUTTON_X2
        }
        library.sendMouseButton(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, code)
    }

    /// One line is 20 high-res units (moonlight-ios's conversion). Horizontal
    /// is negated: Moonlight's positive horizontal scroll goes right.
    func pointerScroll(dx: Int, dy: Int) {
        if dy != 0 { library.sendHighResScroll(Int16(clamping: dy * 20)) }
        if dx != 0 { library.sendHighResHScroll(Int16(clamping: -dx * 20)) }
    }
}
#endif
