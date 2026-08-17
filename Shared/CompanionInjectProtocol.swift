import Foundation

/// Wire protocol for the **text-only keyboard injection** channel: a visionOS
/// viewer — the VNC one, or the Native Mac stream — asks the macOS companion to
/// type literal text (or backspaces) into whatever app is frontmost on the Mac.
/// Deliberately minimal — it can express *only* Unicode insertion and backspace,
/// never key codes or modifiers, so a compromised channel cannot synthesize
/// Cmd+Space / Run-dialog "DuckyScript" payloads. Modifiers and special keys go
/// over the transport's own key path instead (VNC keysyms, or Native's
/// separately-gated shortcut channel).
///
/// Transport: TLS 1.2-PSK over TCP (see `CompanionInjectCrypto`), keyed by the
/// same companion token as audio but domain-separated, so a leaked audio PSK is
/// not an inject PSK. Frames mirror the audio framing: `[UInt32 len][UInt8
/// type][payload]`, little-endian. There is no app-layer auth — a wrong token
/// fails the handshake before any frame.
nonisolated enum CompanionInjectProtocol {
    static let defaultPort: UInt16 = 4856
    static let frameLengthPrefixSize = 4
    /// Text injection is tiny; cap a frame at 64 KB.
    static let maxFrameBytes: UInt32 = 1 << 16

    enum FrameType: UInt8, Sendable {
        /// Client → server handshake greeting (empty payload).
        case hello = 0x10
        /// Server → client: 1-byte `Status` for current injection availability.
        case helloAck = 0x11
        /// Client → server: UTF-8 text to insert verbatim.
        case injectText = 0x20
        /// Client → server: UInt16 little-endian count of backspaces.
        case injectBackspace = 0x22
        /// Server → client: 1-byte `Status`, pushed when availability changes
        /// (toggle flipped, Accessibility granted/revoked).
        case injectStatus = 0xa0
        /// Empty heartbeat (either direction).
        case keepAlive = 0x07
    }

    /// Whether the companion will actually inject right now.
    enum Status: UInt8, Sendable {
        case available = 0          // master toggle on + Accessibility granted
        case disabled = 1           // master toggle off
        case accessibilityDenied = 2 // toggle on but Accessibility not granted
    }

    /// Wraps a payload in a typed, length-prefixed frame.
    static func encodeFrame(_ type: FrameType, _ payload: Data = Data()) -> Data {
        var frame = Data(capacity: frameLengthPrefixSize + 1 + payload.count)
        var length = UInt32(1 + payload.count).littleEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(type.rawValue)
        frame.append(payload)
        return frame
    }

    /// Little-endian backspace-count payload for `.injectBackspace`.
    static func encodeBackspace(_ count: Int) -> Data {
        var n = UInt16(clamping: count).littleEndian
        return withUnsafeBytes(of: &n) { Data($0) }
    }

    static func decodeBackspace(_ payload: Data) -> Int? {
        guard payload.count == 2 else { return nil }
        let lo = UInt16(payload[payload.startIndex])
        let hi = UInt16(payload[payload.startIndex + 1])
        return Int(lo | (hi << 8))
    }

    static func decodeFrameLength(_ data: Data) -> UInt32? {
        guard data.count >= frameLengthPrefixSize else { return nil }
        var value: UInt32 = 0
        for i in 0..<frameLengthPrefixSize {
            value |= UInt32(data[data.startIndex + i]) << (8 * i)
        }
        return value
    }

    /// Pops every complete frame from the front of `buffer`, leaving any
    /// partial trailing frame in place. A malformed length (zero or beyond the
    /// cap) can't occur on the authenticated channel, so it's treated as a
    /// corrupt stream and the buffer is reset.
    static func drainFrames(_ buffer: inout Data) -> [(type: UInt8, payload: Data)] {
        var out: [(type: UInt8, payload: Data)] = []
        while let length = decodeFrameLength(buffer) {
            guard length >= 1, length <= maxFrameBytes else {
                buffer.removeAll(keepingCapacity: false)
                break
            }
            let frameEnd = frameLengthPrefixSize + Int(length)
            guard buffer.count >= frameEnd else { break }
            let start = buffer.startIndex
            let type = buffer[start + frameLengthPrefixSize]
            let payload = buffer.subdata(
                in: start.advanced(by: frameLengthPrefixSize + 1)..<start.advanced(by: frameEnd)
            )
            buffer.removeFirst(frameEnd)
            out.append((type: type, payload: payload))
        }
        return out
    }
}
