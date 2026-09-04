#if MOONLIGHT_ENABLED
import Foundation
import os
@preconcurrency import MoonlightCommonC

/// One linked copy of moonlight-common-c, and the Swift side of running more
/// than one game stream at a time.
///
/// moonlight-common-c has no notion of a connection handle: `LiStartConnection`
/// drives one set of globals (stream configuration, callbacks, depacketizer
/// state, worker threads) and every `LiSend*` call targets whatever that one
/// session is. So the app links the library several times — the original plus
/// symbol-prefixed copies `MoonlightCommonC1`, `MoonlightCommonC2` (see
/// `ci/deps/moonlight-common-c/ml_redefine_symbols.h`) — and each
/// `MoonlightConnectionManager` owns one copy for its lifetime. A "slot" is the
/// index of that copy. Everything that used to call a bare `LiSend…` goes through
/// the manager's `library` instead, so the call lands in the right copy.
///
/// The copies are identical in layout, so the app builds every C struct with the
/// types from the unprefixed module and hands the other copies raw pointers;
/// `Functions` is the thin per-copy table that does the pointer casts.
final class MoonlightLibrary: @unchecked Sendable {
    /// How many sessions can stream at once — one per linked copy. Keep in step
    /// with `extraInstances` in `ci/deps/moonlight-common-c/Package.swift` (that
    /// is the number of *extra* copies, so `count` is one more).
    nonisolated static let count = 3

    nonisolated static let all: [MoonlightLibrary] = [
        MoonlightLibrary(slot: 0, functions: .slot0),
        MoonlightLibrary(slot: 1, functions: .slot1),
        MoonlightLibrary(slot: 2, functions: .slot2),
    ]

    nonisolated let slot: Int
    nonisolated let functions: Functions

    // State the C callbacks of this copy read. Set before `LiStartConnection`
    // and cleared after `LiStopConnection`, both off the main thread; the
    // callbacks themselves fire on the library's own threads.
    nonisolated(unsafe) var videoRenderer: MoonlightVideoRenderer?
    nonisolated(unsafe) var audioRenderer: MoonlightAudioRenderer?
    nonisolated(unsafe) var delegate: MoonlightStreamDelegate?
    nonisolated(unsafe) var gamepadManager: MoonlightGamepadManager?

    nonisolated init(slot: Int, functions: Functions) {
        self.slot = slot
        self.functions = functions
    }

    /// The entry points of one copy, wrapped so callers never name a module.
    /// Every closure is a one-liner around the copy's own `Li…` function; the
    /// three `MoonlightLibrarySlotN.swift` files are identical apart from which
    /// module they import.
    nonisolated struct Functions: Sendable {
        let startConnection: @Sendable (
            _ serverInfo: UnsafeMutableRawPointer,
            _ streamConfig: UnsafeMutableRawPointer,
            _ connectionCallbacks: UnsafeMutableRawPointer,
            _ videoCallbacks: UnsafeMutableRawPointer,
            _ audioCallbacks: UnsafeMutableRawPointer
        ) -> Int32
        let stopConnection: @Sendable () -> Void
        let interruptConnection: @Sendable () -> Void
        let stageName: @Sendable (Int32) -> UnsafePointer<CChar>?
        let estimatedRttInfo: @Sendable (UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Bool
        let hdrMetadata: @Sendable (UnsafeMutableRawPointer) -> Bool
        let requestIdrFrame: @Sendable () -> Void
        let sendMouseMove: @Sendable (Int16, Int16) -> Int32
        let sendMousePosition: @Sendable (Int16, Int16, Int16, Int16) -> Int32
        let sendMouseButton: @Sendable (Int8, Int32) -> Int32
        let sendKeyboard: @Sendable (Int16, Int8, Int8) -> Int32
        let sendHighResScroll: @Sendable (Int16) -> Int32
        let sendHighResHScroll: @Sendable (Int16) -> Int32
        let sendMultiController: @Sendable (Int16, Int16, Int32, UInt8, UInt8, Int16, Int16, Int16, Int16) -> Int32
        let sendControllerArrival: @Sendable (UInt8, UInt16, UInt8, UInt32, UInt16) -> Int32
    }

    // MARK: - Typed conveniences

    nonisolated func stageName(_ stage: Int32) -> String {
        guard let name = functions.stageName(stage) else { return "Unknown" }
        return String(cString: name)
    }

    nonisolated func estimatedRtt() -> (rtt: UInt32, variance: UInt32)? {
        var rtt: UInt32 = 0
        var variance: UInt32 = 0
        guard functions.estimatedRttInfo(&rtt, &variance) else { return nil }
        return (rtt, variance)
    }

    nonisolated func hdrMetadata() -> SS_HDR_METADATA? {
        var metadata = SS_HDR_METADATA()
        let got = withUnsafeMutablePointer(to: &metadata) { functions.hdrMetadata(UnsafeMutableRawPointer($0)) }
        return got ? metadata : nil
    }

    nonisolated func requestIdrFrame() {
        functions.requestIdrFrame()
    }

    nonisolated func sendMouseMove(dx: Int16, dy: Int16) {
        _ = functions.sendMouseMove(dx, dy)
    }

    nonisolated func sendMousePosition(x: Int16, y: Int16, referenceWidth: Int16, referenceHeight: Int16) {
        _ = functions.sendMousePosition(x, y, referenceWidth, referenceHeight)
    }

    nonisolated func sendMouseButton(_ action: Int32, _ button: Int32) {
        _ = functions.sendMouseButton(Int8(action), button)
    }

    /// A press immediately followed by a release.
    nonisolated func clickMouseButton(_ button: Int32) {
        sendMouseButton(BUTTON_ACTION_PRESS, button)
        sendMouseButton(BUTTON_ACTION_RELEASE, button)
    }

    nonisolated func sendKeyboard(_ keyCode: Int16, _ action: Int32, modifiers: Int8) {
        _ = functions.sendKeyboard(keyCode, Int8(action), modifiers)
    }

    nonisolated func sendHighResScroll(_ amount: Int16) {
        _ = functions.sendHighResScroll(amount)
    }

    nonisolated func sendHighResHScroll(_ amount: Int16) {
        _ = functions.sendHighResHScroll(amount)
    }

    nonisolated func sendMultiController(
        controllerNumber: Int16, activeGamepadMask: Int16, buttonFlags: Int32,
        leftTrigger: UInt8, rightTrigger: UInt8,
        leftStickX: Int16, leftStickY: Int16, rightStickX: Int16, rightStickY: Int16
    ) {
        _ = functions.sendMultiController(
            controllerNumber, activeGamepadMask, buttonFlags, leftTrigger, rightTrigger,
            leftStickX, leftStickY, rightStickX, rightStickY
        )
    }

    nonisolated func sendControllerArrival(
        controllerNumber: UInt8, activeGamepadMask: UInt16, type: UInt8,
        supportedButtonFlags: UInt32, capabilities: UInt16
    ) {
        _ = functions.sendControllerArrival(controllerNumber, activeGamepadMask, type, supportedButtonFlags, capabilities)
    }
}

/// Which session the shared physical inputs go to.
///
/// A gamepad, a Bluetooth mouse and a `GCKeyboard` are read through
/// GameController, which is app-wide: every streaming session's bridge sees the
/// same button press. With one stream that was the point; with several, the
/// press has to be delivered to exactly one host, or a jump in one game is a
/// jump in all of them. The stream a user is looking at (visionOS) or pointing
/// at (macOS) claims focus, and the managers check it before forwarding. Window-
/// local inputs — taps, `UIPress` keyboard capture, `NSEvent`s — need no such
/// check: they already arrive at one window.
enum MoonlightInputFocus {
    /// Read from GameController handler queues (main) and written from the
    /// main actor, so a plain global is enough.
    nonisolated(unsafe) private(set) static var slot: Int = 0

    /// Posted on the main actor after `slot` changes, with the previous slot
    /// as `object`, so the losing session can release anything it was holding.
    nonisolated static let didChange = Notification.Name("MoonlightInputFocus.didChange")

    @MainActor
    static func claim(_ newSlot: Int) {
        guard newSlot != slot else { return }
        let previous = slot
        slot = newSlot
        NotificationCenter.default.post(name: didChange, object: previous)
    }

    nonisolated static func owns(_ slot: Int) -> Bool {
        self.slot == slot
    }
}
#endif
