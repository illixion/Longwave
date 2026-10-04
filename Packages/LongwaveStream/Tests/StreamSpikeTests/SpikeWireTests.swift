import StreamSpikeWire
import XCTest

final class SpikeWireTests: XCTestCase {
    func testPacketizeThenReassembleRoundTrips() {
        var packetizer = SpikePacketizer()
        var reassembler = SpikeReassembler()
        let picture = (0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        var datagrams: [[UInt8]] = []
        picture.withUnsafeBytes { raw in
            packetizer.packetize(raw, isIDR: true, captureNanos: 42) { datagrams.append(Array($0)) }
        }
        XCTAssertEqual(datagrams.count, (picture.count + SpikeWire.maxPayload - 1) / SpikeWire.maxPayload)
        XCTAssertTrue(datagrams.allSatisfy { $0.count <= SpikeWire.maxDatagram })
        var result: SpikePicture?
        for datagram in datagrams.reversed() { // order must not matter
            if let done = datagram.withUnsafeBytes({ reassembler.receive($0) }) { result = done }
        }
        XCTAssertEqual(result?.bytes, picture)
        XCTAssertEqual(result?.isIDR, true)
        XCTAssertEqual(result?.captureNanos, 42)
    }

    func testIncompletePictureCountsAsLostWhenANewerOneCompletes() {
        var packetizer = SpikePacketizer()
        var reassembler = SpikeReassembler()
        var first: [[UInt8]] = []
        var second: [[UInt8]] = []
        let picture = [UInt8](repeating: 7, count: 3000)
        picture.withUnsafeBytes { raw in
            packetizer.packetize(raw, isIDR: false, captureNanos: 1) { first.append(Array($0)) }
            packetizer.packetize(raw, isIDR: false, captureNanos: 2) { second.append(Array($0)) }
        }
        _ = first[0].withUnsafeBytes { reassembler.receive($0) } // first stays incomplete
        var done: SpikePicture?
        for d in second { if let p = d.withUnsafeBytes({ reassembler.receive($0) }) { done = p } }
        XCTAssertEqual(done?.number, 1)
        XCTAssertEqual(reassembler.lostPictures, 1)
        // A late shard of the abandoned picture is ignored.
        XCTAssertNil(first[1].withUnsafeBytes { reassembler.receive($0) })
        XCTAssertEqual(reassembler.lateDatagrams, 1)
    }

    func testMalformedDatagramsAreRejected() {
        var reassembler = SpikeReassembler()
        let junk = [UInt8](repeating: 0xFF, count: 40)
        XCTAssertNil(junk.withUnsafeBytes { reassembler.receive($0) })
        XCTAssertEqual(reassembler.malformedDatagrams, 1)
    }
}
