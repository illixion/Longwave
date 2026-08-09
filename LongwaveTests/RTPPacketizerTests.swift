import XCTest
@testable import Longwave

final class RTPPacketizerTests: XCTestCase {

    // MARK: - RTP header

    func testHeaderEncoding() {
        let header = RTPHeader.encode(marker: true, payloadType: 96, sequenceNumber: 0xABCD,
                                      timestamp: 0x01020304, ssrc: 0xDEADBEEF)
        XCTAssertEqual(header.count, 12)
        let bytes = [UInt8](header)
        XCTAssertEqual(bytes[0], 0x80)                       // V=2, no P/X/CC
        XCTAssertEqual(bytes[1], 0x80 | 96)                  // marker + PT
        XCTAssertEqual(bytes[2], 0xAB)
        XCTAssertEqual(bytes[3], 0xCD)
        XCTAssertEqual(Array(bytes[4...7]), [0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(Array(bytes[8...11]), [0xDE, 0xAD, 0xBE, 0xEF])
    }

    func testHeaderNoMarker() {
        let header = RTPHeader.encode(marker: false, payloadType: 97, sequenceNumber: 0,
                                      timestamp: 0, ssrc: 1)
        XCTAssertEqual([UInt8](header)[1], 97)
    }

    // MARK: - AVCC splitting

    func testAVCCSplitter() {
        var avcc = Data()
        let nal1: [UInt8] = [0x65, 0x01, 0x02]
        let nal2: [UInt8] = [0x41, 0xFF]
        avcc.append(contentsOf: [0, 0, 0, 3]); avcc.append(contentsOf: nal1)
        avcc.append(contentsOf: [0, 0, 0, 2]); avcc.append(contentsOf: nal2)
        let units = AVCCSplitter.nalUnits(fromAVCC: avcc)
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual([UInt8](units[0]), nal1)
        XCTAssertEqual([UInt8](units[1]), nal2)
    }

    func testAVCCSplitterTruncatedInput() {
        var avcc = Data()
        avcc.append(contentsOf: [0, 0, 0, 10, 0x65])    // claims 10 bytes, has 1
        XCTAssertTrue(AVCCSplitter.nalUnits(fromAVCC: avcc).isEmpty)
    }

    // MARK: - H.264 single NAL

    func testSingleNALPacket() {
        var packetizer = H264Packetizer(ssrc: 42, maxPayloadSize: 1200, initialSequenceNumber: 100)
        let nal = Data([0x65] + [UInt8](repeating: 0xAA, count: 50))
        let packets = packetizer.packetize(nalUnits: [nal], timestamp: 9000)
        XCTAssertEqual(packets.count, 1)
        let bytes = [UInt8](packets[0])
        XCTAssertEqual(bytes[1], 0x80 | 96, "marker must be set on the last packet of an access unit")
        XCTAssertEqual(Array(bytes[12...]), [UInt8](nal), "single-NAL payload is the NAL verbatim")
        XCTAssertEqual(packetizer.sequenceNumber, 101)
    }

    func testMarkerOnlyOnLastNAL() {
        var packetizer = H264Packetizer(ssrc: 1)
        let sps = Data([0x67, 0x01]), pps = Data([0x68, 0x02]), idr = Data([0x65, 0x03])
        let packets = packetizer.packetize(nalUnits: [sps, pps, idr], timestamp: 0)
        XCTAssertEqual(packets.count, 3)
        XCTAssertEqual([UInt8](packets[0])[1] & 0x80, 0)
        XCTAssertEqual([UInt8](packets[1])[1] & 0x80, 0)
        XCTAssertEqual([UInt8](packets[2])[1] & 0x80, 0x80)
    }

    // MARK: - FU-A fragmentation

    func testFUAFragmentationRoundTrip() {
        let maxPayload = 100
        var packetizer = H264Packetizer(ssrc: 7, maxPayloadSize: maxPayload, initialSequenceNumber: 0)
        let originalNAL = Data([0x65] + (0..<350).map { UInt8(truncatingIfNeeded: $0) })
        let packets = packetizer.packetize(nalUnits: [originalNAL], timestamp: 1234)

        XCTAssertGreaterThan(packets.count, 1)
        var reassembled = Data()
        for (index, packet) in packets.enumerated() {
            let bytes = [UInt8](packet)
            let payload = Array(bytes[12...])
            XCTAssertLessThanOrEqual(payload.count, maxPayload + 2)
            let fuIndicator = payload[0]
            let fuHeader = payload[1]
            XCTAssertEqual(fuIndicator & 0x1F, 28, "FU-A type")
            XCTAssertEqual(fuIndicator & 0xE0, 0x65 & 0xE0, "F/NRI preserved")
            XCTAssertEqual(fuHeader & 0x1F, 0x65 & 0x1F, "original NAL type in FU header")
            let isFirst = index == 0
            let isLast = index == packets.count - 1
            XCTAssertEqual(fuHeader & 0x80 != 0, isFirst, "start bit")
            XCTAssertEqual(fuHeader & 0x40 != 0, isLast, "end bit")
            XCTAssertEqual(bytes[1] & 0x80 != 0, isLast, "marker on final fragment only")
            if isFirst {
                reassembled.append(0x65)    // reconstruct NAL header from FU bits
            }
            reassembled.append(contentsOf: payload[2...])
            // Sequence numbers must be contiguous.
            XCTAssertEqual(Int(bytes[2]) << 8 | Int(bytes[3]), index)
        }
        XCTAssertEqual(reassembled, originalNAL)
    }

    func testSequenceNumberWraps() {
        var packetizer = H264Packetizer(ssrc: 1, initialSequenceNumber: 0xFFFF)
        _ = packetizer.packetize(nalUnits: [Data([0x41, 0x00])], timestamp: 0)
        XCTAssertEqual(packetizer.sequenceNumber, 0)
    }

    // MARK: - Opus

    func testOpusPacket() {
        var packetizer = OpusPacketizer(ssrc: 9, initialSequenceNumber: 5)
        let frame = Data([0x78, 0x01, 0x02, 0x03])
        let packet = packetizer.packetize(frame: frame, timestamp: 960)
        let bytes = [UInt8](packet)
        XCTAssertEqual(bytes[1], 97, "marker must be 0 for Opus (RFC 7587)")
        XCTAssertEqual(Array(bytes[12...]), [UInt8](frame))
        XCTAssertEqual(packetizer.sequenceNumber, 6)
    }

    // MARK: - RTCP sender report

    func testSenderReportLayout() {
        let report = RTCPSenderReport.encode(ssrc: 0x11223344, ntpTime: 0xAABBCCDD_EEFF0011,
                                             rtpTimestamp: 90_000, packetCount: 10, octetCount: 999)
        XCTAssertEqual(report.count, 28)
        let bytes = [UInt8](report)
        XCTAssertEqual(bytes[0], 0x80)
        XCTAssertEqual(bytes[1], 200)
        XCTAssertEqual(Int(bytes[2]) << 8 | Int(bytes[3]), 6, "length in 32-bit words minus one")
        XCTAssertEqual(Array(bytes[4...7]), [0x11, 0x22, 0x33, 0x44])
        XCTAssertEqual(Array(bytes[8...15]), [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11])
    }

    func testNTPTimestampEpoch() {
        // Unix epoch == 2,208,988,800 s after the NTP epoch.
        let ntp = RTCPSenderReport.ntpTimestamp(unixTime: 0)
        XCTAssertEqual(ntp >> 32, 2_208_988_800)
    }
}
