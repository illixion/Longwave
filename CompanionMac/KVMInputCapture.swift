import Foundation
import AppKit
import CoreGraphics

/// Takes this Mac's keyboard and mouse away from macOS and turns them into HID
/// reports for the KVM dongle, so one set of input devices drives the Vision
/// Pro. This is the capture half; `KVMBridgeController` owns it and does the
/// sending.
///
/// The tap is installed in two shapes. *Armed* watches only for the toggle
/// hotkey and passes every event through untouched — the user needs a way back
/// while wearing a headset, and a tap that is not installed cannot offer one.
/// *Capturing* takes the full mask and swallows everything, because an event
/// that reaches both the Mac and the headset would type into two places at
/// once. Both need the Accessibility permission the companion already asks for.
///
/// Output is pulled, not pushed: the tap callback must return quickly and
/// cannot wait on a 3 ms serial round trip, so it appends to two structures the
/// sender drains. Key presses and media keys queue in order — dropping or
/// reordering one leaves a key stuck down on the headset — while pointer motion
/// coalesces into the tail frame, which is lossless because the deltas are
/// relative and `int16`.
@MainActor
final class KVMInputCapture {

    enum Outgoing {
        case key([UInt8])
        case consumer(usage: UInt16, pressed: Bool)
    }

    struct Motion {
        var dx: Int = 0
        var dy: Int = 0
        var buttons: UInt8 = 0
        var wheel: Int = 0
        var pan: Int = 0

        var isEmpty: Bool { dx == 0 && dy == 0 && wheel == 0 && pan == 0 }
    }

    /// Called when the user asks for capture to flip, by hotkey.
    var onToggleHotkey: (() -> Void)?
    /// Called when the system disables our tap (it does that if a callback ever
    /// runs long) so the owner can note it; the tap is re-enabled either way.
    var onTapReenabled: (() -> Void)?

    /// Multiplies pointer deltas. The headset's pointer and the Mac's have
    /// different ideas of a comfortable speed, and the Mac's own acceleration
    /// is already baked into the deltas we read.
    var pointerSpeed: Double = 1.0

    private(set) var isCapturing = false
    private(set) var isArmed = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Keyboard state, mirrored so every report is a complete snapshot.
    private var modifiers: UInt8 = 0
    private var downUsages: [UInt8] = []
    private var capsLockOn = false

    // Pull queues.
    private var pending: [Outgoing] = []
    private var motion: [Motion] = []
    private var buttons: UInt8 = 0
    private var wheelRemainder = 0.0
    private var panRemainder = 0.0
    private var xRemainder = 0.0
    private var yRemainder = 0.0

    // MARK: - Arming

    enum CaptureError: LocalizedError {
        case tapRefused

        var errorDescription: String? {
            "macOS refused the input tap. Grant Longwave Companion the Accessibility permission in System Settings > Privacy & Security."
        }
    }

    func arm() throws {
        guard !isArmed else { return }
        isArmed = true
        try installTap()
    }

    func disarm() {
        setCapturing(false)
        isArmed = false
        removeTap()
    }

    func setCapturing(_ capturing: Bool) {
        guard capturing != isCapturing else { return }
        isCapturing = capturing
        if capturing {
            // Unglue the pointer from the mouse: the deltas keep arriving, the
            // Mac's cursor stops moving, and it cannot wander into a corner
            // hot spot or another display while the user is looking elsewhere.
            CGAssociateMouseAndMouseCursorPosition(0)
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            resetState()
        }
        if isArmed {
            removeTap()
            try? installTap()
        }
    }

    private func resetState() {
        modifiers = 0
        downUsages.removeAll()
        buttons = 0
        pending.removeAll()
        motion.removeAll()
        wheelRemainder = 0
        panRemainder = 0
        xRemainder = 0
        yRemainder = 0
    }

    private func installTap() throws {
        let mask: CGEventMask
        if isCapturing {
            mask = [CGEventType.keyDown, .keyUp, .flagsChanged,
                    .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                    .otherMouseDown, .otherMouseUp, .scrollWheel]
                .reduce(CGEventMask(1) << CGEventMask(CGEventType.systemDefinedRawValue)) {
                    $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
                }
        } else {
            mask = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: kvmInputTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            isArmed = false
            throw CaptureError.tapRefused
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = source
    }

    private func removeTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tap { CFMachPortInvalidate(tap) }
        runLoopSource = nil
        tap = nil
    }

    // MARK: - Draining

    /// The next keyboard or media report, in the order it happened.
    func takePending() -> Outgoing? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// The next pointer report, with everything that accumulated behind it
    /// folded in.
    func takeMotion() -> (dx: Int16, dy: Int16, buttons: UInt8, wheel: Int8, pan: Int8)? {
        guard !motion.isEmpty else { return nil }
        let frame = motion.removeFirst()
        return (dx: Int16(clamping: frame.dx),
                dy: Int16(clamping: frame.dy),
                buttons: frame.buttons,
                wheel: Int8(clamping: frame.wheel),
                pan: Int8(clamping: frame.pan))
    }

    var hasWork: Bool { !pending.isEmpty || !motion.isEmpty }

    /// The report that puts the headset back in a neutral state.
    static let releasedKeyboardReport = [UInt8](repeating: 0, count: 8)

    // MARK: - The tap

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            onTapReenabled?()
            return nil
        }

        if type == .keyDown, isToggleHotkey(event) {
            onToggleHotkey?()
            return nil
        }

        guard isCapturing else { return passThrough }

        switch type {
        case .keyDown:
            // The headset repeats a held key itself, the way any HID host does,
            // so the Mac's own auto-repeat would double it.
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                press(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
            }
        case .keyUp:
            release(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
        case .flagsChanged:
            updateModifiers(event)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            addMotion(event)
        case .leftMouseDown: setButton(0x01, down: true)
        case .leftMouseUp: setButton(0x01, down: false)
        case .rightMouseDown: setButton(0x02, down: true)
        case .rightMouseUp: setButton(0x02, down: false)
        case .otherMouseDown, .otherMouseUp:
            let index = event.getIntegerValueField(.mouseEventButtonNumber)
            let bit: UInt8 = index == 2 ? 0x04 : (index == 3 ? 0x08 : (index == 4 ? 0x10 : 0))
            if bit != 0 { setButton(bit, down: type == .otherMouseDown) }
        case .scrollWheel:
            addScroll(event)
        default:
            if type.rawValue == CGEventType.systemDefinedRawValue {
                handleSystemDefined(event)
            }
        }
        return nil
    }

    /// Control-Option-Command-K, checked before anything else so it works in
    /// both tap shapes — it is the way out of capture as well as the way in.
    private func isToggleHotkey(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.keyboardEventKeycode) == 0x28 else { return false }
        let flags = event.flags
        return flags.contains(.maskControl) && flags.contains(.maskAlternate) && flags.contains(.maskCommand)
    }

    // MARK: - Keyboard

    private func press(keyCode: UInt16) {
        guard let usage = MacKeyCodeMap.hidUsage(forMacKeyCode: keyCode),
              let byte = UInt8(exactly: usage), !MacKeyCodeMap.isModifierOnly(hidUsage: usage) else { return }
        guard !downUsages.contains(byte) else { return }
        // Six is the boot-protocol limit; the seventh key is simply not sent,
        // which is what a real keyboard's rollover does too.
        guard downUsages.count < 6 else { return }
        downUsages.append(byte)
        enqueueKeyboardReport()
    }

    private func release(keyCode: UInt16) {
        guard let usage = MacKeyCodeMap.hidUsage(forMacKeyCode: keyCode),
              let byte = UInt8(exactly: usage),
              let index = downUsages.firstIndex(of: byte) else { return }
        downUsages.remove(at: index)
        enqueueKeyboardReport()
    }

    private func enqueueKeyboardReport() {
        var report = [UInt8](repeating: 0, count: 8)
        report[0] = modifiers
        for (offset, usage) in downUsages.prefix(6).enumerated() {
            report[2 + offset] = usage
        }
        pending.append(.key(report))
    }

    /// Rebuilds the modifier bitmap from the event's device-dependent flag
    /// bits, which name the *side* the key is on. Tracking presses by keycode
    /// instead would drift the moment a modifier is released while another
    /// window has focus.
    private func updateModifiers(_ event: CGEvent) {
        let flags = event.flags.rawValue
        var bitmap: UInt8 = 0
        if flags & 0x0000_0001 != 0 { bitmap |= 0x01 } // left control
        if flags & 0x0000_0002 != 0 { bitmap |= 0x02 } // left shift
        if flags & 0x0000_0020 != 0 { bitmap |= 0x04 } // left option
        if flags & 0x0000_0008 != 0 { bitmap |= 0x08 } // left command
        if flags & 0x0000_2000 != 0 { bitmap |= 0x10 } // right control
        if flags & 0x0000_0004 != 0 { bitmap |= 0x20 } // right shift
        if flags & 0x0000_0040 != 0 { bitmap |= 0x40 } // right option
        if flags & 0x0000_0010 != 0 { bitmap |= 0x80 } // right command
        modifiers = bitmap

        // Caps Lock is a latch on the Mac and a key everywhere else: the
        // headset keeps its own latch, so each toggle here is one tap there.
        let capsNow = event.flags.contains(.maskAlphaShift)
        if capsNow != capsLockOn {
            capsLockOn = capsNow
            var report = [UInt8](repeating: 0, count: 8)
            report[0] = modifiers
            report[2] = UInt8(MacKeyCodeMap.HID.capsLock)
            pending.append(.key(report))
        }
        enqueueKeyboardReport()
    }

    // MARK: - Pointer

    private func addMotion(_ event: CGEvent) {
        let rawX = Double(event.getIntegerValueField(.mouseEventDeltaX)) * pointerSpeed + xRemainder
        let rawY = Double(event.getIntegerValueField(.mouseEventDeltaY)) * pointerSpeed + yRemainder
        let dx = rawX.rounded(.towardZero)
        let dy = rawY.rounded(.towardZero)
        xRemainder = rawX - dx
        yRemainder = rawY - dy
        guard dx != 0 || dy != 0 else { return }
        mutateTail { frame in
            frame.dx += Int(dx)
            frame.dy += Int(dy)
        }
    }

    private func addScroll(_ event: CGEvent) {
        let lines = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) + wheelRemainder
        let clicks = lines.rounded(.towardZero)
        wheelRemainder = lines - clicks
        let sideways = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) + panRemainder
        let pan = sideways.rounded(.towardZero)
        panRemainder = sideways - pan
        guard clicks != 0 || pan != 0 else { return }
        mutateTail { frame in
            frame.wheel += Int(clicks)
            // HID pans right on a positive value; macOS's axis 2 is positive
            // when the content moves right, which is the other way round.
            frame.pan -= Int(pan)
        }
    }

    private func setButton(_ bit: UInt8, down: Bool) {
        let updated = down ? (buttons | bit) : (buttons & ~bit)
        guard updated != buttons else { return }
        buttons = updated
        // A button change is its own report: folding it into the frame ahead
        // would move the click to where the pointer used to be, and folding
        // two changes together would lose the click entirely.
        motion.append(Motion(buttons: buttons))
    }

    /// Adds to the newest frame when it is still open — same button state, and
    /// no wheel-versus-motion ambiguity — otherwise starts a new one.
    private func mutateTail(_ body: (inout Motion) -> Void) {
        if var last = motion.last, last.buttons == buttons {
            body(&last)
            motion[motion.count - 1] = last
        } else {
            var frame = Motion(buttons: buttons)
            body(&frame)
            motion.append(frame)
        }
    }

    // MARK: - Media keys

    /// The keyboard's media row arrives as one `NSSystemDefined` event rather
    /// than a key code, and carries the button in `data1`.
    private func handleSystemDefined(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else { return }
        let data = nsEvent.data1
        let key = Int32((data & 0xFFFF_0000) >> 16)
        let down = ((data & 0x0000_FF00) >> 8) == 0x0A
        let usage: UInt16
        switch key {
        case NX_KEYTYPE_SOUND_UP: usage = 0x00E9
        case NX_KEYTYPE_SOUND_DOWN: usage = 0x00EA
        case NX_KEYTYPE_MUTE: usage = 0x00E2
        case NX_KEYTYPE_PLAY: usage = 0x00CD
        case NX_KEYTYPE_NEXT, NX_KEYTYPE_FAST: usage = 0x00B5
        case NX_KEYTYPE_PREVIOUS, NX_KEYTYPE_REWIND: usage = 0x00B6
        default: return
        }
        pending.append(.consumer(usage: usage, pressed: down))
    }
}

private extension CGEventType {
    /// `NSEvent.EventType.systemDefined`, which `CGEventType` has no case for.
    static let systemDefinedRawValue: UInt32 = 14
}

/// The tap callback has to be a C function, which a main-actor-isolated
/// function cannot be — and this file compiles under the project's
/// MainActor-by-default isolation, so it says `nonisolated` explicitly. It
/// does run on the main thread: that is where the run loop source was added,
/// which is what makes the hop below an assertion rather than a dispatch.
private nonisolated func kvmInputTapCallback(proxy: CGEventTapProxy,
                                 type: CGEventType,
                                 event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let capture = Unmanaged<KVMInputCapture>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { capture.handle(type: type, event: event) }
}
