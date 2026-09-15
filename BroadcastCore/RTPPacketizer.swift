import Foundation

/// RTP packet construction: header encoding, H.264 payloading (RFC 6184,
/// single-NAL + FU-A fragmentation) and Opus payloading (RFC 7587).
/// Pure value types with no I/O so the framing logic is unit-testable;
/// `RTSPPublisher` owns the socket.

nonisolated enum RTPHeader {
    /// Builds the fixed 12-byte RTP header (V=2, no padding/extension/CSRC).
    static func encode(marker: Bool, payloadType: UInt8, sequenceNumber: UInt16,
                       timestamp: UInt32, ssrc: UInt32) -> Data {
        var header = Data(capacity: 12)
        header.append(0x80)
        header.append((marker ? 0x80 : 0x00) | (payloadType & 0x7F))
        header.append(UInt8(sequenceNumber >> 8))
        header.append(UInt8(sequenceNumber & 0xFF))
        header.appendBigEndian(timestamp)
        header.appendBigEndian(ssrc)
        return header
    }
}

/// Packetizes H.264 access units per RFC 6184. NAL units that fit in
/// `maxPayloadSize` go out as single-NAL packets; larger ones are FU-A
/// fragmented. The RTP marker bit is set on the last packet of each
/// access unit.
nonisolated struct H264Packetizer {
    let payloadType: UInt8
    let ssrc: UInt32
    /// Payload budget per packet. Conservative default keeps the full RTP
    /// packet under a 1500-byte path MTU even with interleaving overhead.
    let maxPayloadSize: Int
    private(set) var sequenceNumber: UInt16

    init(payloadType: UInt8 = 96, ssrc: UInt32, maxPayloadSize: Int = 1200, initialSequenceNumber: UInt16 = 0) {
        self.payloadType = payloadType
        self.ssrc = ssrc
        self.maxPayloadSize = maxPayloadSize
        self.sequenceNumber = initialSequenceNumber
    }

    /// `nalUnits` are the raw NALs of one access unit (no start codes / length
    /// prefixes). `timestamp` is in the 90 kHz RTP clock.
    mutating func packetize(nalUnits: [Data], timestamp: UInt32) -> [Data] {
        var packets: [Data] = []
        for (index, nal) in nalUnits.enumerated() where !nal.isEmpty {
            let isLastNAL = index == nalUnits.count - 1
            let bytes = [UInt8](nal)
            if bytes.count <= maxPayloadSize {
                packets.append(makePacket(payload: Data(bytes), marker: isLastNAL, timestamp: timestamp))
            } else {
                // FU-A: indicator carries F/NRI with type 28; the original
                // NAL type moves into the FU header with start/end flags.
                let fuIndicator = (bytes[0] & 0xE0) | 28
                let nalType = bytes[0] & 0x1F
                let body = bytes[1...]
                let chunkSize = maxPayloadSize - 2
                var start = body.startIndex
                while start < body.endIndex {
                    let end = min(start + chunkSize, body.endIndex)
                    let isFirst = start == body.startIndex
                    let isLast = end == body.endIndex
                    var payload = Data(capacity: 2 + (end - start))
                    payload.append(fuIndicator)
                    payload.append((isFirst ? 0x80 : 0x00) | (isLast ? 0x40 : 0x00) | nalType)
                    payload.append(contentsOf: body[start..<end])
                    packets.append(makePacket(payload: payload, marker: isLastNAL && isLast, timestamp: timestamp))
                    start = end
                }
            }
        }
        return packets
    }

    private mutating func makePacket(payload: Data, marker: Bool, timestamp: UInt32) -> Data {
        var packet = RTPHeader.encode(marker: marker, payloadType: payloadType,
                                      sequenceNumber: sequenceNumber, timestamp: timestamp, ssrc: ssrc)
        packet.append(payload)
        sequenceNumber &+= 1
        return packet
    }
}

/// Packetizes Opus frames per RFC 7587: one Opus packet per RTP packet,
/// marker bit always 0, 48 kHz RTP clock regardless of capture rate.
nonisolated struct OpusPacketizer {
    let payloadType: UInt8
    let ssrc: UInt32
    private(set) var sequenceNumber: UInt16

    init(payloadType: UInt8 = 97, ssrc: UInt32, initialSequenceNumber: UInt16 = 0) {
        self.payloadType = payloadType
        self.ssrc = ssrc
        self.sequenceNumber = initialSequenceNumber
    }

    mutating func packetize(frame: Data, timestamp: UInt32) -> Data {
        var packet = RTPHeader.encode(marker: false, payloadType: payloadType,
                                      sequenceNumber: sequenceNumber, timestamp: timestamp, ssrc: ssrc)
        packet.append(frame)
        sequenceNumber &+= 1
        return packet
    }
}

/// Minimal RTCP Sender Report (RFC 3550 §6.4.1, no report blocks) so the
/// receiver can map each track's RTP clock to wall time for A/V sync.
nonisolated enum RTCPSenderReport {
    static func encode(ssrc: UInt32, ntpTime: UInt64, rtpTimestamp: UInt32,
                       packetCount: UInt32, octetCount: UInt32) -> Data {
        var report = Data(capacity: 28)
        report.append(0x80)            // V=2, P=0, RC=0
        report.append(200)             // PT=SR
        report.append(0x00)
        report.append(0x06)            // length = 6 32-bit words minus one
        report.appendBigEndian(ssrc)
        report.appendBigEndian(UInt32(truncatingIfNeeded: ntpTime >> 32))
        report.appendBigEndian(UInt32(truncatingIfNeeded: ntpTime))
        report.appendBigEndian(rtpTimestamp)
        report.appendBigEndian(packetCount)
        report.appendBigEndian(octetCount)
        return report
    }

    /// Converts a Unix epoch interval to a 64-bit NTP timestamp (epoch 1900).
    static func ntpTimestamp(unixTime: TimeInterval) -> UInt64 {
        let ntpEpochOffset = 2_208_988_800.0
        let total = unixTime + ntpEpochOffset
        let seconds = UInt64(total)
        let fraction = UInt64((total - Double(seconds)) * Double(UInt32.max))
        return (seconds << 32) | fraction
    }
}

nonisolated extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
