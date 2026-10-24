// Control-channel message bodies (section 4.5) that are fixed binary. The
// JSON ones (`displayList`, `virtualDisplayChange`, `windowInventory`) carry
// v2's Codable bodies unchanged and are opaque here.

/// Client -> host: frames of `streamID` from `firstLostFrame` on can't be
/// decoded, because that frame was lost or arrived with a broken reference
/// chain (section 6.3, "Reference invalidation"). The host invalidates the
/// reference where its encoder can, and sends a key frame otherwise.
///
/// Body: `streamID u32 | firstLostFrame u32` (8).
public struct RecoveryRequest: WireCodable, Hashable {
    public var streamID: UInt32
    public var firstLostFrame: UInt32

    public init(streamID: UInt32, firstLostFrame: UInt32) {
        self.streamID = streamID
        self.firstLostFrame = firstLostFrame
    }

    public init(from reader: inout WireReader) throws(WireError) {
        streamID = try reader.readUInt32()
        firstLostFrame = try reader.readUInt32()
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        writer.writeUInt32(streamID)
        writer.writeUInt32(firstLostFrame)
    }
}

/// Client -> host: which stream a `streamStart` or `streamStop` is about.
///
/// Body: `streamID u32` (4).
public struct StreamSubscription: WireCodable, Hashable {
    public var streamID: UInt32

    public init(streamID: UInt32) {
        self.streamID = streamID
    }

    public init(from reader: inout WireReader) throws(WireError) {
        streamID = try reader.readUInt32()
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        writer.writeUInt32(streamID)
    }
}

/// UTF-8 text bodies (`bye`'s reason, `selectDisplay`'s id), checked strictly.
public enum TextBody {
    public static let maxBytes = 1024

    public static func encode(_ text: String) throws(WireError) -> [UInt8] {
        let bytes = Array(text.utf8)
        guard bytes.count <= maxBytes else { throw .tooLarge("text") }
        return bytes
    }

    public static func decode(_ body: ArraySlice<UInt8>) throws(WireError) -> String {
        guard body.count <= maxBytes else { throw .tooLarge("text") }
        let text = String(decoding: body, as: UTF8.self)
        guard text.utf8.elementsEqual(body) else { throw .invalid("text.utf8") }
        return text
    }
}
