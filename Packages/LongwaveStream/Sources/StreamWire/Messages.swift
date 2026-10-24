/// Message types carried on the reliable channels (sections 4.3 and 4.5).
///
/// One namespace across the three channels, so a type byte means the same
/// thing wherever it appears. Append-only; an open set, because a receiver
/// skips messages it doesn't know by their length.
public struct MessageType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    // Control, channel 0 (0x20...0x3F). Others (streamConfig, stats,
    // audioAnchor, clipboard) come with the features that use them.
    public static let formatDescription = MessageType(rawValue: 0x20)
    /// Client -> host: a stream's reference chain broke (`RecoveryRequest`).
    public static let recoveryRequest = MessageType(rawValue: 0x21)
    /// Either way: the session is ending, with a reason (UTF-8, may be empty).
    public static let bye = MessageType(rawValue: 0x22)
    // v2's JSON bodies, unchanged inside the message (section 4.5).
    /// Host -> client: the desktops the host can stream, and the one it streams.
    public static let displayList = MessageType(rawValue: 0x23)
    /// Client -> host: stream this display (its id, UTF-8).
    public static let selectDisplay = MessageType(rawValue: 0x24)
    /// Client -> host: a virtual display resolution or exclusivity change.
    public static let virtualDisplayChange = MessageType(rawValue: 0x25)
    /// Host -> client: the streamable windows (`windowStreams`).
    public static let windowInventory = MessageType(rawValue: 0x26)

    // Input events, client -> host, channel 1 (0x40...0x5F). See `InputEvent`.
    public static let keyDown = MessageType(rawValue: 0x40)
    public static let keyUp = MessageType(rawValue: 0x41)
    public static let mouseDown = MessageType(rawValue: 0x42)
    public static let mouseUp = MessageType(rawValue: 0x43)
    public static let scroll = MessageType(rawValue: 0x44)
    public static let textInput = MessageType(rawValue: 0x45)
    public static let focusWindow = MessageType(rawValue: 0x46)
    public static let gamepadConnected = MessageType(rawValue: 0x47)
    public static let gamepadDisconnected = MessageType(rawValue: 0x48)
    public static let releaseAll = MessageType(rawValue: 0x49)

    // Input feedback, host -> client, channel 1 (0x60...0x6F). See `HostInputEvent`.
    public static let rumble = MessageType(rawValue: 0x60)
    public static let lightBar = MessageType(rawValue: 0x61)
    public static let triggerEffect = MessageType(rawValue: 0x62)
    public static let cursor = MessageType(rawValue: 0x63)
    public static let controlStatus = MessageType(rawValue: 0x64)

    public var description: String { "0x" + String(rawValue, radix: 16) }
}

/// One message from a reliable channel. `body` is a slice of the stream buffer.
public struct Message: Sendable, Equatable {
    public var type: MessageType
    public var body: ArraySlice<UInt8>

    public init(type: MessageType, body: ArraySlice<UInt8>) {
        self.type = type
        self.body = body
    }
}

/// Splits a reliable channel's byte stream into messages:
/// `type u8 | length varint | body`, the same shape as datagram frames.
public enum MessageFraming {
    /// Larger payloads (clipboard images, artwork) are chunked on the bulk
    /// channel by their own message type.
    public static let maxBodyLength = 1 << 20

    public static func append(_ type: MessageType, body: some Collection<UInt8>,
                              to writer: inout WireWriter) throws(WireError) {
        guard body.count <= maxBodyLength else { throw .tooLarge("message.body") }
        writer.writeUInt8(type.rawValue)
        try writer.writeVarint(body.count)
        writer.writeBytes(body)
    }

    public static func encode(_ type: MessageType, body: some Collection<UInt8>) throws(WireError) -> [UInt8] {
        var writer = WireWriter(reservingCapacity: body.count + 4)
        try append(type, body: body, to: &writer)
        return writer.bytes
    }

    /// The first complete message in `buffer` and how many bytes it used, or
    /// nil if the buffer ends inside it (wait for more bytes). Throws when the
    /// stream is malformed, which ends the session: a reliable stream cannot
    /// resynchronise after a bad length.
    public static func next(in buffer: ArraySlice<UInt8>) throws(WireError) -> (message: Message, consumed: Int)? {
        guard let rawType = buffer.first else { return nil }
        let lengthStart = buffer.startIndex + 1
        switch try Varint.parsePrefix(buffer[lengthStart...]) {
        case .incomplete:
            return nil
        case .complete(let length, let lengthSize):
            guard length <= maxBodyLength else { throw .tooLarge("message.body") }
            let bodyStart = lengthStart + lengthSize
            guard buffer.endIndex - bodyStart >= length else { return nil }
            let message = Message(type: MessageType(rawValue: rawType), body: buffer[bodyStart..<(bodyStart + length)])
            return (message, 1 + lengthSize + length)
        }
    }

    /// Every complete message in `buffer`; convenience for tests and tools.
    /// Throws `.truncated` if the buffer ends inside a message.
    public static func messages(in buffer: [UInt8]) throws(WireError) -> [Message] {
        var rest = buffer[...]
        var messages: [Message] = []
        while !rest.isEmpty {
            guard let (message, consumed) = try next(in: rest) else { throw .truncated }
            messages.append(message)
            rest = rest.dropFirst(consumed)
        }
        return messages
    }
}
