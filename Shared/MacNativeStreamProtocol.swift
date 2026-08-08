import Foundation

/// Framing shared by the macOS native screen host and the visionOS viewer.
/// The transport is authenticated before these frames are accepted.
nonisolated enum MacNativeStreamProtocol {
    static let defaultPort: UInt16 = 4857
    static let frameLengthPrefixSize = 4
    static let maxFrameBytes: UInt32 = 64 * 1024 * 1024

    enum FrameType: UInt8, Sendable {
        case keepAlive = 0x07
        case hello = 0x10
        case helloAck = 0x11
        case formatDescription = 0x20
        case videoFrame = 0x21
        case replaced = 0x30
        case error = 0x31
        /// Client → server: UInt16 x, UInt16 y (little-endian, in the
        /// stream's own pixel space — see `VideoFrame`/`formatDescription`).
        case mouseMove = 0x40
        /// Client → server: `MacNativeMouseButton` raw byte, UInt16 x, UInt16 y.
        case mouseDown = 0x41
        /// Client → server: same payload as `mouseDown`.
        case mouseUp = 0x42
        /// Client → server: UInt16 x, UInt16 y, Int16 deltaX, Int16 deltaY
        /// (all little-endian; delta is in scroll "lines").
        case scroll = 0x43
        /// Client → server: UInt16 macOS virtual keycode, UInt32
        /// `MacNativeKeyModifiers` raw value (little-endian).
        case keyDown = 0x44
        /// Client → server: same payload as `keyDown`.
        case keyUp = 0x45
        /// Server → client: 1-byte `InputStatus` for current remote-control
        /// availability, pushed on connect and whenever it changes.
        case inputStatus = 0x46
    }

    struct Hello: Codable, Sendable {
        let deviceName: String
    }

    /// Mirrors the stream's own pixel space — a mouse coordinate is only
    /// meaningful alongside the display's current point-space size, which the
    /// Mac companion knows and the viewer learns from `formatDescription`.
    enum MouseButton: UInt8, Sendable {
        case left = 0
        case right = 1
        case other = 2
    }

    /// Whether the companion will actually act on mouse/keyboard frames right
    /// now — mirrors `CompanionInjectProtocol.Status`, but for the full
    /// remote-control channel (mouse + arbitrary key codes/modifiers) rather
    /// than text-only injection.
    enum InputStatus: UInt8, Sendable {
        case available = 0    // master toggle on + Accessibility granted
        case disabled = 1     // master toggle off
        case accessibilityDenied = 2 // toggle on but Accessibility not granted
    }

    struct VideoFrame: Sendable {
        let data: Data
        let isKeyFrame: Bool
        let sequence: UInt64
        let timestampNanoseconds: UInt64
    }

    static func encodeFrame(_ type: FrameType, _ payload: Data = Data()) -> Data {
        var frame = Data(capacity: frameLengthPrefixSize + 1 + payload.count)
        var length = UInt32(1 + payload.count).littleEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(type.rawValue)
        frame.append(payload)
        return frame
    }

    static func encodeHello(deviceName: String) -> Data {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hello = Hello(deviceName: name.isEmpty ? "Vision Pro" : name)
        let payload = (try? JSONEncoder().encode(hello)) ?? Data()
        return encodeFrame(.hello, payload)
    }

    static func decodeHello(_ payload: Data) -> Hello? {
        try? JSONDecoder().decode(Hello.self, from: payload)
    }

    static func encodeVideoFrame(
        _ data: Data,
        isKeyFrame: Bool,
        sequence: UInt64,
        timestampNanoseconds: UInt64
    ) -> Data {
        var payload = Data(capacity: 17 + data.count)
        payload.append(isKeyFrame ? 1 : 0)
        payload.appendLittleEndian(sequence)
        payload.appendLittleEndian(timestampNanoseconds)
        payload.append(data)
        return encodeFrame(.videoFrame, payload)
    }

    static func encodeMouseMove(x: UInt16, y: UInt16) -> Data {
        var payload = Data(capacity: 4)
        payload.appendLittleEndian(x)
        payload.appendLittleEndian(y)
        return encodeFrame(.mouseMove, payload)
    }

    static func decodeMouseMove(_ payload: Data) -> (x: UInt16, y: UInt16)? {
        guard payload.count >= 4, let x = payload.readLittleEndianUInt16(at: payload.startIndex),
              let y = payload.readLittleEndianUInt16(at: payload.startIndex + 2) else { return nil }
        return (x, y)
    }

    static func encodeMouseButton(_ type: FrameType, button: MouseButton, x: UInt16, y: UInt16) -> Data {
        var payload = Data(capacity: 5)
        payload.append(button.rawValue)
        payload.appendLittleEndian(x)
        payload.appendLittleEndian(y)
        return encodeFrame(type, payload)
    }

    static func decodeMouseButton(_ payload: Data) -> (button: MouseButton, x: UInt16, y: UInt16)? {
        guard payload.count >= 5,
              let button = MouseButton(rawValue: payload[payload.startIndex]),
              let x = payload.readLittleEndianUInt16(at: payload.startIndex + 1),
              let y = payload.readLittleEndianUInt16(at: payload.startIndex + 3) else { return nil }
        return (button, x, y)
    }

    static func encodeScroll(x: UInt16, y: UInt16, deltaX: Int16, deltaY: Int16) -> Data {
        var payload = Data(capacity: 8)
        payload.appendLittleEndian(x)
        payload.appendLittleEndian(y)
        payload.appendLittleEndian(UInt16(bitPattern: deltaX))
        payload.appendLittleEndian(UInt16(bitPattern: deltaY))
        return encodeFrame(.scroll, payload)
    }

    static func decodeScroll(_ payload: Data) -> (x: UInt16, y: UInt16, deltaX: Int16, deltaY: Int16)? {
        guard payload.count >= 8,
              let x = payload.readLittleEndianUInt16(at: payload.startIndex),
              let y = payload.readLittleEndianUInt16(at: payload.startIndex + 2),
              let rawDeltaX = payload.readLittleEndianUInt16(at: payload.startIndex + 4),
              let rawDeltaY = payload.readLittleEndianUInt16(at: payload.startIndex + 6) else { return nil }
        return (x, y, Int16(bitPattern: rawDeltaX), Int16(bitPattern: rawDeltaY))
    }

    static func encodeKeyEvent(_ type: FrameType, keyCode: UInt16, modifiers: MacNativeKeyModifiers) -> Data {
        var payload = Data(capacity: 6)
        payload.appendLittleEndian(keyCode)
        payload.appendLittleEndian(modifiers.rawValue)
        return encodeFrame(type, payload)
    }

    static func decodeKeyEvent(_ payload: Data) -> (keyCode: UInt16, modifiers: MacNativeKeyModifiers)? {
        guard payload.count >= 6,
              let keyCode = payload.readLittleEndianUInt16(at: payload.startIndex),
              let rawModifiers = payload.readLittleEndianUInt32(at: payload.startIndex + 2) else { return nil }
        return (keyCode, MacNativeKeyModifiers(rawValue: rawModifiers))
    }

    static func decodeVideoFrame(_ payload: Data) -> VideoFrame? {
        guard payload.count >= 17 else { return nil }
        let start = payload.startIndex
        guard let sequence = payload.readLittleEndianUInt64(at: start + 1),
              let timestamp = payload.readLittleEndianUInt64(at: start + 9) else {
            return nil
        }
        return VideoFrame(
            data: payload.subdata(in: (start + 17)..<payload.endIndex),
            isKeyFrame: payload[start] != 0,
            sequence: sequence,
            timestampNanoseconds: timestamp
        )
    }

    static func decodeFrameLength(_ data: Data) -> UInt32? {
        guard data.count >= frameLengthPrefixSize else { return nil }
        var value: UInt32 = 0
        for index in 0..<frameLengthPrefixSize {
            value |= UInt32(data[data.startIndex + index]) << (8 * index)
        }
        return value
    }

    static func drainFrames(_ buffer: inout Data) -> [(type: UInt8, payload: Data)] {
        var frames: [(type: UInt8, payload: Data)] = []
        while let length = decodeFrameLength(buffer) {
            guard length >= 1, length <= maxFrameBytes else {
                buffer.removeAll(keepingCapacity: false)
                break
            }
            let frameEnd = frameLengthPrefixSize + Int(length)
            guard buffer.count >= frameEnd else { break }

            let start = buffer.startIndex
            let type = buffer[start + frameLengthPrefixSize]
            let payloadStart = start + frameLengthPrefixSize + 1
            frames.append((
                type: type,
                payload: buffer.subdata(in: payloadStart..<(start + frameEnd))
            ))
            buffer.removeFirst(frameEnd)
        }
        return frames
    }
}

private nonisolated extension Data {
    mutating func appendLittleEndian(_ value: UInt64) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func readLittleEndianUInt64(at index: Index) -> UInt64? {
        guard distance(from: index, to: endIndex) >= MemoryLayout<UInt64>.size else {
            return nil
        }
        var value: UInt64 = 0
        for offset in 0..<MemoryLayout<UInt64>.size {
            value |= UInt64(self[index + offset]) << (8 * offset)
        }
        return value
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func readLittleEndianUInt16(at index: Index) -> UInt16? {
        guard distance(from: index, to: endIndex) >= MemoryLayout<UInt16>.size else {
            return nil
        }
        var value: UInt16 = 0
        for offset in 0..<MemoryLayout<UInt16>.size {
            value |= UInt16(self[index + offset]) << (8 * offset)
        }
        return value
    }

    func readLittleEndianUInt32(at index: Index) -> UInt32? {
        guard distance(from: index, to: endIndex) >= MemoryLayout<UInt32>.size else {
            return nil
        }
        var value: UInt32 = 0
        for offset in 0..<MemoryLayout<UInt32>.size {
            value |= UInt32(self[index + offset]) << (8 * offset)
        }
        return value
    }
}

/// Modifier bitmask for `MacNativeStreamProtocol` key events. A standalone
/// type (not `CGEventFlags`) because `CGEvent`/`CGEventFlags` don't exist on
/// visionOS — the viewer only ever builds and sends this raw bitmask; the Mac
/// companion converts it to `CGEventFlags` when injecting (see the
/// `os(macOS)` extension below).
struct MacNativeKeyModifiers: OptionSet, Sendable {
    let rawValue: UInt32

    static let shift = MacNativeKeyModifiers(rawValue: 1 << 0)
    static let control = MacNativeKeyModifiers(rawValue: 1 << 1)
    static let option = MacNativeKeyModifiers(rawValue: 1 << 2)
    static let command = MacNativeKeyModifiers(rawValue: 1 << 3)
    static let capsLock = MacNativeKeyModifiers(rawValue: 1 << 4)
}

#if os(macOS)
import CoreGraphics

extension MacNativeKeyModifiers {
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.capsLock) { flags.insert(.maskAlphaShift) }
        return flags
    }
}
#endif
