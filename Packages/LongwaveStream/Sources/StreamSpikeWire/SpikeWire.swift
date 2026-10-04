// SPIKE ONLY (Phase 2 go/no-go, 2026-10-04). A deliberately minimal video
// packetization - no FEC, no encryption, no acknowledgement - just enough to
// carry encoded pictures over UDP and prove they reassemble into a decodable
// stream. The Phase 1 StreamWire module replaces it.
//
// Datagram: a 28-byte big-endian header, then up to `maxPayload` bytes of one
// picture's Annex-B bitstream.
//
//   0  u32  magic "LWSP"
//   4  u32  picture number (increasing per stream)
//   8  u16  shard index
//  10  u16  shard count
//  12  u8   flags (bit 0: IDR)
//  13  u8   reserved
//  14  u16  payload length
//  16  u64  capture time, host monotonic nanoseconds
//  24  u32  picture size in bytes

public enum SpikeWire {
    public static let magic: UInt32 = 0x4C57_5350 // "LWSP"
    public static let headerSize = 28
    /// Tailscale's 1280-byte MTU minus IPv6 (40) and UDP (8) headers, rounded down.
    public static let maxDatagram = 1200
    public static let maxPayload = maxDatagram - headerSize
}

public struct SpikeShardHeader: Equatable, Sendable {
    public var picture: UInt32
    public var shard: UInt16
    public var shardCount: UInt16
    public var isIDR: Bool
    public var payloadLength: UInt16
    public var captureNanos: UInt64
    public var pictureSize: UInt32

    public init(picture: UInt32, shard: UInt16, shardCount: UInt16, isIDR: Bool, payloadLength: UInt16,
                captureNanos: UInt64, pictureSize: UInt32) {
        self.picture = picture
        self.shard = shard
        self.shardCount = shardCount
        self.isIDR = isIDR
        self.payloadLength = payloadLength
        self.captureNanos = captureNanos
        self.pictureSize = pictureSize
    }

    public func write(to buffer: UnsafeMutableRawBufferPointer) {
        precondition(buffer.count >= SpikeWire.headerSize)
        buffer.storeBytes(of: SpikeWire.magic.bigEndian, toByteOffset: 0, as: UInt32.self)
        buffer.storeBytes(of: picture.bigEndian, toByteOffset: 4, as: UInt32.self)
        buffer.storeBytes(of: shard.bigEndian, toByteOffset: 8, as: UInt16.self)
        buffer.storeBytes(of: shardCount.bigEndian, toByteOffset: 10, as: UInt16.self)
        buffer.storeBytes(of: isIDR ? UInt8(1) : 0, toByteOffset: 12, as: UInt8.self)
        buffer.storeBytes(of: UInt8(0), toByteOffset: 13, as: UInt8.self)
        buffer.storeBytes(of: payloadLength.bigEndian, toByteOffset: 14, as: UInt16.self)
        buffer.storeBytes(of: captureNanos.bigEndian, toByteOffset: 16, as: UInt64.self)
        buffer.storeBytes(of: pictureSize.bigEndian, toByteOffset: 24, as: UInt32.self)
    }

    /// Parses and validates a datagram's header; nil for anything malformed.
    public init?(parsing datagram: UnsafeRawBufferPointer) {
        guard datagram.count >= SpikeWire.headerSize,
              UInt32(bigEndian: datagram.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) == SpikeWire.magic
        else { return nil }
        picture = UInt32(bigEndian: datagram.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        shard = UInt16(bigEndian: datagram.loadUnaligned(fromByteOffset: 8, as: UInt16.self))
        shardCount = UInt16(bigEndian: datagram.loadUnaligned(fromByteOffset: 10, as: UInt16.self))
        isIDR = datagram[12] & 1 != 0
        payloadLength = UInt16(bigEndian: datagram.loadUnaligned(fromByteOffset: 14, as: UInt16.self))
        captureNanos = UInt64(bigEndian: datagram.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
        pictureSize = UInt32(bigEndian: datagram.loadUnaligned(fromByteOffset: 24, as: UInt32.self))
        guard shardCount > 0, shard < shardCount,
              Int(payloadLength) == datagram.count - SpikeWire.headerSize,
              Int(payloadLength) <= SpikeWire.maxPayload,
              Int(pictureSize) <= Int(shardCount) * SpikeWire.maxPayload
        else { return nil }
    }
}

/// Splits one encoded picture into datagrams, handing each to `send`.
public struct SpikePacketizer {
    private var nextPicture: UInt32 = 0
    private var scratch = [UInt8](repeating: 0, count: SpikeWire.maxDatagram)

    public init() {}

    /// Returns the picture number used.
    @discardableResult
    public mutating func packetize(_ picture: UnsafeRawBufferPointer, isIDR: Bool, captureNanos: UInt64,
                                   send: (UnsafeRawBufferPointer) -> Void) -> UInt32 {
        let number = nextPicture
        nextPicture &+= 1
        let count = max(1, (picture.count + SpikeWire.maxPayload - 1) / SpikeWire.maxPayload)
        precondition(count <= Int(UInt16.max), "picture too large for the spike wire")
        scratch.withUnsafeMutableBytes { buffer in
            for index in 0..<count {
                let start = index * SpikeWire.maxPayload
                let length = min(SpikeWire.maxPayload, picture.count - start)
                SpikeShardHeader(picture: number, shard: UInt16(index), shardCount: UInt16(count), isIDR: isIDR,
                                 payloadLength: UInt16(length), captureNanos: captureNanos,
                                 pictureSize: UInt32(picture.count)).write(to: buffer)
                if length > 0 {
                    UnsafeMutableRawBufferPointer(rebasing: buffer[SpikeWire.headerSize..<(SpikeWire.headerSize + length)])
                        .copyMemory(from: UnsafeRawBufferPointer(rebasing: picture[start..<(start + length)]))
                }
                send(UnsafeRawBufferPointer(rebasing: buffer[0..<(SpikeWire.headerSize + length)]))
            }
        }
        return number
    }
}

/// A picture the reassembler finished.
public struct SpikePicture: Sendable {
    public var number: UInt32
    public var isIDR: Bool
    public var captureNanos: UInt64
    public var bytes: [UInt8]
}

/// Rebuilds pictures from datagrams. Latest-wins: once a picture completes,
/// any older incomplete picture is abandoned (counted as lost), and pictures
/// older than the last one delivered are ignored - the behaviour a real-time
/// player wants, and what makes loss visible in the counts.
public struct SpikeReassembler {
    private struct Partial {
        var isIDR: Bool
        var captureNanos: UInt64
        var bytes: [UInt8]
        var received: [Bool]
        var receivedCount = 0
    }

    private var partials: [UInt32: Partial] = [:]
    private var lastDelivered: UInt32?
    public private(set) var lostPictures = 0
    public private(set) var lateDatagrams = 0
    public private(set) var duplicateShards = 0
    public private(set) var malformedDatagrams = 0

    public init() {}

    public mutating func receive(_ datagram: UnsafeRawBufferPointer) -> SpikePicture? {
        guard let header = SpikeShardHeader(parsing: datagram) else {
            malformedDatagrams += 1
            return nil
        }
        if let last = lastDelivered, !isNewer(header.picture, than: last) {
            lateDatagrams += 1
            return nil
        }
        var partial = partials[header.picture] ?? Partial(
            isIDR: header.isIDR, captureNanos: header.captureNanos,
            bytes: [UInt8](repeating: 0, count: Int(header.pictureSize)),
            received: [Bool](repeating: false, count: Int(header.shardCount)))
        guard partial.received.count == Int(header.shardCount), partial.bytes.count == Int(header.pictureSize) else {
            malformedDatagrams += 1
            return nil
        }
        let index = Int(header.shard)
        if partial.received[index] {
            duplicateShards += 1
            return nil
        }
        let start = index * SpikeWire.maxPayload
        let length = Int(header.payloadLength)
        guard start + length <= partial.bytes.count else {
            malformedDatagrams += 1
            return nil
        }
        partial.bytes.withUnsafeMutableBytes { dest in
            UnsafeMutableRawBufferPointer(rebasing: dest[start..<(start + length)])
                .copyMemory(from: UnsafeRawBufferPointer(rebasing: datagram[SpikeWire.headerSize..<(SpikeWire.headerSize + length)]))
        }
        partial.received[index] = true
        partial.receivedCount += 1

        guard partial.receivedCount == partial.received.count else {
            partials[header.picture] = partial
            return nil
        }
        partials[header.picture] = nil
        // Everything older that is still incomplete will never be shown.
        var abandoned = 0
        for key in partials.keys where isNewer(header.picture, than: key) {
            partials[key] = nil
            abandoned += 1
        }
        if let last = lastDelivered {
            // Every picture between the last one shown and this one is lost,
            // whether it arrived in part or not at all.
            lostPictures += Int(header.picture &- last) - 1
        } else {
            lostPictures += abandoned // before the first picture, only what we saw part of
        }
        lastDelivered = header.picture
        return SpikePicture(number: header.picture, isIDR: partial.isIDR, captureNanos: partial.captureNanos,
                            bytes: partial.bytes)
    }

    private func isNewer(_ a: UInt32, than b: UInt32) -> Bool {
        Int32(bitPattern: a &- b) > 0
    }
}
