// Remote control of the desktop stream (SendInput), as the Windows Companion's
// v2 server does it (CompanionWindows/backend/NativeStream/InputInjector.cs):
// absolute pointer in the captured monitor's physical pixels, wheel lines, and
// HID keyboard usages (the ack names `hidUsage`, so modifiers arrive as their
// own key events and the mask is ignored).

import StreamWire
import WinSDK

final class DesktopInput {
    /// The captured monitor's origin on the virtual desktop, physical pixels.
    var origin = (x: 0, y: 0)
    private var held: Set<UInt16> = []
    private var buttons: Set<MouseButton> = []

    func move(x: UInt16, y: UInt16) {
        sendMouse(x: x, y: y, flags: DWORD(MOUSEEVENTF_MOVE))
    }

    func button(_ button: MouseButton, down: Bool, x: UInt16, y: UInt16) {
        let flags: Int32
        switch (button, down) {
        case (.left, true): flags = MOUSEEVENTF_LEFTDOWN
        case (.left, false): flags = MOUSEEVENTF_LEFTUP
        case (.right, true): flags = MOUSEEVENTF_RIGHTDOWN
        case (.right, false): flags = MOUSEEVENTF_RIGHTUP
        case (_, true): flags = MOUSEEVENTF_MIDDLEDOWN
        case (_, false): flags = MOUSEEVENTF_MIDDLEUP
        }
        if down { buttons.insert(button) } else { buttons.remove(button) }
        sendMouse(x: x, y: y, flags: DWORD(MOUSEEVENTF_MOVE | flags))
    }

    func scroll(x: UInt16, y: UInt16, lines: (x: Int16, y: Int16)) {
        sendMouse(x: x, y: y, flags: DWORD(MOUSEEVENTF_MOVE))
        if lines.y != 0 { sendWheel(DWORD(MOUSEEVENTF_WHEEL), Int32(lines.y) * Int32(WHEEL_DELTA)) }
        if lines.x != 0 { sendWheel(DWORD(MOUSEEVENTF_HWHEEL), Int32(lines.x) * Int32(WHEEL_DELTA)) }
    }

    func key(hidUsage: UInt16, down: Bool) {
        guard let vk = Self.virtualKey[hidUsage] else { return }
        if down { held.insert(hidUsage) } else { held.remove(hidUsage) }
        var input = INPUT()
        input.type = DWORD(INPUT_KEYBOARD)
        input.ki.wVk = vk
        input.ki.dwFlags = (down ? 0 : DWORD(KEYEVENTF_KEYUP)) | (Self.extended.contains(vk) ? DWORD(KEYEVENTF_EXTENDEDKEY) : 0)
        _ = SendInput(1, &input, Int32(MemoryLayout<INPUT>.size))
    }

    /// Lets go of everything this viewer holds (it left, or asked).
    func releaseAll() {
        for usage in held { key(hidUsage: usage, down: false) }
        var point = POINT()
        GetCursorPos(&point)
        let x = UInt16(clamping: Int(point.x) - origin.x), y = UInt16(clamping: Int(point.y) - origin.y)
        for button in buttons { self.button(button, down: false, x: x, y: y) }
    }

    private func sendMouse(x: UInt16, y: UInt16, flags: DWORD) {
        let left = GetSystemMetrics(SM_XVIRTUALSCREEN), top = GetSystemMetrics(SM_YVIRTUALSCREEN)
        let width = GetSystemMetrics(SM_CXVIRTUALSCREEN), height = GetSystemMetrics(SM_CYVIRTUALSCREEN)
        guard width > 1, height > 1 else { return }
        let screenX = Double(origin.x + Int(x) - Int(left)), screenY = Double(origin.y + Int(y) - Int(top))
        var input = INPUT()
        input.type = DWORD(INPUT_MOUSE)
        input.mi.dx = LONG((screenX * 65535 / Double(width - 1)).rounded())
        input.mi.dy = LONG((screenY * 65535 / Double(height - 1)).rounded())
        input.mi.dwFlags = flags | DWORD(MOUSEEVENTF_ABSOLUTE) | DWORD(MOUSEEVENTF_VIRTUALDESK)
        _ = SendInput(1, &input, Int32(MemoryLayout<INPUT>.size))
    }

    private func sendWheel(_ flags: DWORD, _ data: Int32) {
        var input = INPUT()
        input.type = DWORD(INPUT_MOUSE)
        input.mi.mouseData = DWORD(bitPattern: data)
        input.mi.dwFlags = flags
        _ = SendInput(1, &input, Int32(MemoryLayout<INPUT>.size))
    }

    /// USB HID keyboard-page usage to Windows virtual key (InputInjector.cs's table).
    private static let virtualKey: [UInt16: WORD] = {
        var map: [UInt16: WORD] = [:]
        for i in 0..<26 { map[0x04 + UInt16(i)] = 0x41 + WORD(i) }            // A-Z
        for i in 0..<9 { map[0x1E + UInt16(i)] = 0x31 + WORD(i) }             // 1-9
        map[0x27] = 0x30                                                     // 0
        let rest: [(UInt16, WORD)] = [
            (0x28, 0x0D), (0x29, 0x1B), (0x2A, 0x08), (0x2B, 0x09), (0x2C, 0x20),
            (0x2D, 0xBD), (0x2E, 0xBB), (0x2F, 0xDB), (0x30, 0xDD), (0x31, 0xDC),
            (0x33, 0xBA), (0x34, 0xDE), (0x35, 0xC0), (0x36, 0xBC), (0x37, 0xBE), (0x38, 0xBF),
            (0x39, 0x14),
            (0x46, 0x2C), (0x47, 0x91), (0x48, 0x13), (0x49, 0x2D), (0x4A, 0x24),
            (0x4B, 0x21), (0x4C, 0x2E), (0x4D, 0x23), (0x4E, 0x22),
            (0x4F, 0x27), (0x50, 0x25), (0x51, 0x28), (0x52, 0x26),
            (0x53, 0x90), (0x54, 0x6F), (0x55, 0x6A), (0x56, 0x6D), (0x57, 0x6B), (0x58, 0x0D),
            (0x59, 0x61), (0x5A, 0x62), (0x5B, 0x63), (0x5C, 0x64), (0x5D, 0x65), (0x5E, 0x66),
            (0x5F, 0x67), (0x60, 0x68), (0x61, 0x69), (0x62, 0x60), (0x63, 0x6E),
            (0x65, 0x5D),
            (0xE0, 0xA2), (0xE1, 0xA0), (0xE2, 0xA4), (0xE3, 0x5B),
            (0xE4, 0xA3), (0xE5, 0xA1), (0xE6, 0xA5), (0xE7, 0x5C),
        ]
        for i in 0..<12 { map[0x3A + UInt16(i)] = 0x70 + WORD(i) }            // F1-F12
        for (usage, vk) in rest { map[usage] = vk }
        return map
    }()

    private static let extended: Set<WORD> = [
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2C, 0x2D, 0x2E,
        0x5B, 0x5C, 0x5D, 0xA3, 0xA5, 0x90, 0x6F,
    ]
}
