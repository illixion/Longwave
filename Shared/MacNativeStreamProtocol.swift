import Foundation

/// Framing shared by the macOS native screen host and the visionOS viewer.
/// The transport is authenticated before these frames are accepted.
nonisolated enum MacNativeStreamProtocol {
    static let defaultPort: UInt16 = 4857
    static let frameLengthPrefixSize = 4
    static let maxFrameBytes: UInt32 = 64 * 1024 * 1024
    /// Keeps opt-in Unity sessions from creating an unbounded number of
    /// simultaneous ScreenCaptureKit and VideoToolbox pipelines.
    static let maxConcurrentWindowStreams = 6

    /// v1: single anonymous desktop stream over `formatDescription`/`videoFrame`.
    /// v2: adds hosts other than macOS, a published window inventory, and
    /// multiplexed per-window streams (`window*` frames, `.desktopStreamID`
    /// for the whole-desktop composition). A v2 server keeps speaking v1 to a
    /// hello without a `protocolVersion`.
    static let protocolVersion = 2

    /// The stream ID of the whole-desktop composition when multiplexed
    /// streams are in use. Real window IDs are never 0 (CGWindowID and
    /// Windows HWNDs are both nonzero).
    static let desktopStreamID: UInt32 = 0

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
        /// Server → client: 1-byte `RemoteControlStatus` for current mouse
        /// availability, pushed on connect and whenever it changes.
        case mouseStatus = 0x46
        /// Server → client: 1-byte `RemoteControlStatus` for current
        /// keyboard-*shortcuts* availability (full keycode + modifiers).
        /// Printable typing has its own always-attempted fallback over
        /// `CompanionInjectProtocol` (text only, no modifiers) independent of
        /// this — see `MacNativeStreamManager`.
        case keyboardStatus = 0x47

        // MARK: v2 — window inventory + multiplexed streams

        /// Server → client: JSON `WindowInventory` — the host's current
        /// streamable windows. Pushed after `helloAck` (v2 clients only) and
        /// again whenever the inventory changes.
        case windowList = 0x50
        /// Client → server: UInt32 stream ID (little-endian) — start
        /// streaming this window (`desktopStreamID` for the whole desktop).
        case windowStreamStart = 0x51
        /// Client → server: UInt32 stream ID — stop streaming this window.
        case windowStreamStop = 0x52
        /// Server → client: UInt32 stream ID, UInt8 `FormatKind`, then the
        /// codec configuration blob in that kind's encoding.
        case windowFormatDescription = 0x53
        /// Server → client: UInt32 stream ID, then the `videoFrame` payload
        /// (UInt8 isKeyFrame, UInt64 sequence, UInt64 ptsNanos, sample data).
        case windowVideoFrame = 0x54
        /// Server → client: UInt32 stream ID + optional UTF-8 reason — the
        /// stream ended (window closed, capture failed, budget exceeded).
        case windowClosed = 0x55
        /// Client → server: UInt32 stream ID — raise/activate this window on
        /// the host so keyboard input routes to it.
        case focusWindow = 0x56

        /// Client → server: UInt32 stream ID + the v1 `mouseMove` payload,
        /// with (x, y) in that stream's own pixel space.
        case windowMouseMove = 0x60
        /// Client → server: UInt32 stream ID + the v1 `mouseDown` payload.
        case windowMouseDown = 0x61
        /// Client → server: UInt32 stream ID + the v1 `mouseUp` payload.
        case windowMouseUp = 0x62
        /// Client → server: UInt32 stream ID + the v1 `scroll` payload.
        case windowScroll = 0x63
    }

    struct Hello: Codable, Sendable {
        let deviceName: String
        /// Absent in v1 clients — treat as 1.
        var protocolVersion: Int?
        /// Whether the client wants the desktop stream at all right now
        /// (the Native window's Screen toggle). Absent for a genuine v1
        /// client, which has no such toggle and always wants it — treat a
        /// missing value as `true` so that legacy behavior is unchanged.
        /// Lets the Mac skip starting capture, and skip the "connected"
        /// notification, for a session that's audio-only from the start.
        var wantsScreen: Bool?

        init(deviceName: String, protocolVersion: Int? = nil, wantsScreen: Bool? = nil) {
            self.deviceName = deviceName
            self.protocolVersion = protocolVersion
            self.wantsScreen = wantsScreen
        }
    }

    /// v2 `helloAck` payload. A v1 server sends an empty payload instead —
    /// `decodeHelloAck` returns nil and the client falls back to v1 behavior
    /// (one anonymous desktop stream, macOS virtual keycodes).
    struct HelloAck: Codable, Sendable {
        let protocolVersion: Int
        /// "macOS" or "windows" — drives client copy and expectations only;
        /// capabilities below are what actually gate behavior.
        let platform: String
        /// Interpretation of `keyDown`/`keyUp` keycodes: "macVirtual" (kVK_*)
        /// or "hidUsage" (USB HID keyboard usage IDs). Servers on non-Mac
        /// hosts use "hidUsage" so clients skip their HID→kVK mapping.
        let keyCodeSpace: KeyCodeSpace
        /// Whether `windowList`/per-window streams are available.
        let supportsWindowStreams: Bool
        /// Whether the alpha-preserving transparent-desktop composition is
        /// available (macOS). When false the desktop stream is opaque.
        let supportsTransparentDesktop: Bool
        /// Whether this host also serves the companion audio stream on
        /// `AudioStreamProtocol.defaultPort`. Optional so an older host that
        /// predates the field still decodes — see `servesAudioStream`.
        let supportsAudioStream: Bool?

        /// Audio availability, with the pre-capability fallback: only the
        /// macOS companion ever served audio, so an absent flag means
        /// "macOS yes, anything else no". Without this a Windows host leaves
        /// the audio player spinning on "Connecting…" forever.
        var servesAudioStream: Bool { supportsAudioStream ?? (platform == "macOS") }
    }

    enum KeyCodeSpace: String, Codable, Sendable {
        case macVirtual
        case hidUsage
    }

    enum FormatKind: UInt8, Sendable {
        /// CoreMedia big-endian ImageDescription blob (exact `muxa`/alpha
        /// metadata transport) — what macOS hosts send.
        case coreMediaImageDescription = 0
        /// Concatenated Annex-B HEVC parameter sets (VPS/SPS/PPS, each with a
        /// start code). Video samples are 4-byte big-endian length-prefixed
        /// NAL units (AVCC/HVCC layout). What non-Apple hosts send.
        case hevcParameterSets = 1
    }

    /// One streamable host window, published via `windowList`.
    struct WindowInfo: Codable, Sendable, Equatable, Identifiable {
        let id: UInt32
        let title: String
        let appName: String
        /// Window size in host points — the aspect-ratio source of truth
        /// (the stream's pixel size may be scaled).
        let width: Double
        let height: Double
        /// Whether this is the host's frontmost window right now.
        let isFocused: Bool
    }

    struct WindowInventory: Codable, Sendable, Equatable {
        let windows: [WindowInfo]
    }

    /// Mirrors the stream's own pixel space — a mouse coordinate is only
    /// meaningful alongside the display's current point-space size, which the
    /// Mac companion knows and the viewer learns from `formatDescription`.
    enum MouseButton: UInt8, Sendable {
        case left = 0
        case right = 1
        case other = 2
    }

    /// Whether the companion will actually act on mouse or keyboard-shortcut
    /// frames right now — mirrors `CompanionInjectProtocol.Status`. Mouse and
    /// keyboard shortcuts are independent capabilities (independent toggles,
    /// see `mouseStatus`/`keyboardStatus`), each gated the same way: a master
    /// toggle plus the shared Accessibility permission.
    enum RemoteControlStatus: UInt8, Sendable {
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

    static func encodeHello(
        deviceName: String,
        protocolVersion: Int = protocolVersion,
        wantsScreen: Bool? = nil
    ) -> Data {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hello = Hello(
            deviceName: name.isEmpty ? "Vision Pro" : name,
            protocolVersion: protocolVersion,
            wantsScreen: wantsScreen
        )
        let payload = (try? JSONEncoder().encode(hello)) ?? Data()
        return encodeFrame(.hello, payload)
    }

    static func decodeHello(_ payload: Data) -> Hello? {
        try? JSONDecoder().decode(Hello.self, from: payload)
    }

    static func encodeHelloAck(_ ack: HelloAck) -> Data {
        encodeFrame(.helloAck, (try? JSONEncoder().encode(ack)) ?? Data())
    }

    /// nil for an empty (v1) payload or undecodable JSON.
    static func decodeHelloAck(_ payload: Data) -> HelloAck? {
        guard !payload.isEmpty else { return nil }
        return try? JSONDecoder().decode(HelloAck.self, from: payload)
    }

    static func encodeWindowInventory(_ windows: [WindowInfo]) -> Data {
        let payload = (try? JSONEncoder().encode(WindowInventory(windows: windows))) ?? Data()
        return encodeFrame(.windowList, payload)
    }

    static func decodeWindowInventory(_ payload: Data) -> [WindowInfo]? {
        (try? JSONDecoder().decode(WindowInventory.self, from: payload))?.windows
    }

    /// `windowStreamStart` / `windowStreamStop` / `focusWindow` all carry a
    /// bare little-endian UInt32 stream ID.
    static func encodeWindowID(_ type: FrameType, windowID: UInt32) -> Data {
        var payload = Data(capacity: 4)
        payload.appendLittleEndian(windowID)
        return encodeFrame(type, payload)
    }

    static func decodeWindowID(_ payload: Data) -> UInt32? {
        payload.readLittleEndianUInt32(at: payload.startIndex)
    }

    static func encodeWindowFormatDescription(
        windowID: UInt32,
        kind: FormatKind,
        data: Data
    ) -> Data {
        var payload = Data(capacity: 5 + data.count)
        payload.appendLittleEndian(windowID)
        payload.append(kind.rawValue)
        payload.append(data)
        return encodeFrame(.windowFormatDescription, payload)
    }

    static func decodeWindowFormatDescription(
        _ payload: Data
    ) -> (windowID: UInt32, kind: FormatKind, data: Data)? {
        let start = payload.startIndex
        guard payload.count >= 5,
              let windowID = payload.readLittleEndianUInt32(at: start),
              let kind = FormatKind(rawValue: payload[start + 4]) else { return nil }
        return (windowID, kind, payload.subdata(in: (start + 5)..<payload.endIndex))
    }

    static func encodeWindowVideoFrame(
        windowID: UInt32,
        _ data: Data,
        isKeyFrame: Bool,
        sequence: UInt64,
        timestampNanoseconds: UInt64
    ) -> Data {
        var payload = Data(capacity: 21 + data.count)
        payload.appendLittleEndian(windowID)
        payload.append(isKeyFrame ? 1 : 0)
        payload.appendLittleEndian(sequence)
        payload.appendLittleEndian(timestampNanoseconds)
        payload.append(data)
        return encodeFrame(.windowVideoFrame, payload)
    }

    static func decodeWindowVideoFrame(
        _ payload: Data
    ) -> (windowID: UInt32, frame: VideoFrame)? {
        let start = payload.startIndex
        guard payload.count >= 4,
              let windowID = payload.readLittleEndianUInt32(at: start),
              let frame = decodeVideoFrame(payload.subdata(in: (start + 4)..<payload.endIndex))
        else { return nil }
        return (windowID, frame)
    }

    static func encodeWindowClosed(windowID: UInt32, reason: String? = nil) -> Data {
        var payload = Data(capacity: 4)
        payload.appendLittleEndian(windowID)
        if let reason {
            payload.append(Data(reason.utf8))
        }
        return encodeFrame(.windowClosed, payload)
    }

    static func decodeWindowClosed(_ payload: Data) -> (windowID: UInt32, reason: String?)? {
        let start = payload.startIndex
        guard let windowID = payload.readLittleEndianUInt32(at: start) else { return nil }
        let reasonData = payload.subdata(in: (start + 4)..<payload.endIndex)
        let reason = reasonData.isEmpty ? nil : String(data: reasonData, encoding: .utf8)
        return (windowID, reason)
    }

    // MARK: v2 per-window input — UInt32 stream ID + the v1 payload

    static func encodeWindowMouseMove(windowID: UInt32, x: UInt16, y: UInt16) -> Data {
        var payload = Data(capacity: 8)
        payload.appendLittleEndian(windowID)
        payload.appendLittleEndian(x)
        payload.appendLittleEndian(y)
        return encodeFrame(.windowMouseMove, payload)
    }

    static func decodeWindowMouseMove(_ payload: Data) -> (windowID: UInt32, x: UInt16, y: UInt16)? {
        let start = payload.startIndex
        guard payload.count >= 8,
              let windowID = payload.readLittleEndianUInt32(at: start),
              let x = payload.readLittleEndianUInt16(at: start + 4),
              let y = payload.readLittleEndianUInt16(at: start + 6) else { return nil }
        return (windowID, x, y)
    }

    static func encodeWindowMouseButton(
        _ type: FrameType,
        windowID: UInt32,
        button: MouseButton,
        x: UInt16,
        y: UInt16
    ) -> Data {
        var payload = Data(capacity: 9)
        payload.appendLittleEndian(windowID)
        payload.append(button.rawValue)
        payload.appendLittleEndian(x)
        payload.appendLittleEndian(y)
        return encodeFrame(type, payload)
    }

    static func decodeWindowMouseButton(
        _ payload: Data
    ) -> (windowID: UInt32, button: MouseButton, x: UInt16, y: UInt16)? {
        let start = payload.startIndex
        guard payload.count >= 9,
              let windowID = payload.readLittleEndianUInt32(at: start),
              let button = MouseButton(rawValue: payload[start + 4]),
              let x = payload.readLittleEndianUInt16(at: start + 5),
              let y = payload.readLittleEndianUInt16(at: start + 7) else { return nil }
        return (windowID, button, x, y)
    }

    static func encodeWindowScroll(
        windowID: UInt32,
        x: UInt16,
        y: UInt16,
        deltaX: Int16,
        deltaY: Int16
    ) -> Data {
        var payload = Data(capacity: 12)
        payload.appendLittleEndian(windowID)
        payload.appendLittleEndian(x)
        payload.appendLittleEndian(y)
        payload.appendLittleEndian(UInt16(bitPattern: deltaX))
        payload.appendLittleEndian(UInt16(bitPattern: deltaY))
        return encodeFrame(.windowScroll, payload)
    }

    static func decodeWindowScroll(
        _ payload: Data
    ) -> (windowID: UInt32, x: UInt16, y: UInt16, deltaX: Int16, deltaY: Int16)? {
        let start = payload.startIndex
        guard payload.count >= 12,
              let windowID = payload.readLittleEndianUInt32(at: start),
              let x = payload.readLittleEndianUInt16(at: start + 4),
              let y = payload.readLittleEndianUInt16(at: start + 6),
              let rawDeltaX = payload.readLittleEndianUInt16(at: start + 8),
              let rawDeltaY = payload.readLittleEndianUInt16(at: start + 10) else { return nil }
        return (windowID, x, y, Int16(bitPattern: rawDeltaX), Int16(bitPattern: rawDeltaY))
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
