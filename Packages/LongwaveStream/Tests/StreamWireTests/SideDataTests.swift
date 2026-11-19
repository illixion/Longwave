import StreamWire
import XCTest

final class SideDataTests: XCTestCase {
    // Field-by-field vectors, reused by the larger messages below.
    static let identity = "00000000 00000000 00000000 0000803f"
    static let fov = "000040bf 0000403f 0000403f 000040bf" // -0.75, 0.75, 0.75, -0.75
    static let leftEye = identity + " 000000bd 00000000 00000000 " + fov  // x = -0.03125
    static let rightEye = identity + " 0000003d 00000000 00000000 " + fov // x = +0.03125

    static let renderPoseItem = hex(
        "01 6600",           // type renderPose, length 102
        "07000000",          // poseSequence
        "0200",              // spaceEpoch
        "0807060504030201",  // displayTime
        leftEye, rightEye)
    static let foveationItem = hex(
        "02 1400",           // type foveation, length 20
        "03000000",          // parameterEpoch
        "0000003f 0000003f", // left centre (0.5, 0.5)
        "0000003f 0000003f") // right centre
    static let depthRangeItem = hex(
        "03 0d00",           // type depthRange, length 13
        "00",                // flags: not empty
        "0000003e",          // near 0.125
        "0000807f",          // far +infinity
        "00000040")          // convergence 2

    func testGoldenItems() throws {
        XCTAssertEqual(Self.renderPoseItem.count, 3 + RenderPose.wireSize)
        let all = SideData(renderPose: Fixtures.renderPose, foveation: Fixtures.foveation, depthRange: Fixtures.depthRange)
        var writer = WireWriter()
        try all.encodeItems(to: &writer)
        XCTAssertEqual(writer.bytes, Self.renderPoseItem + Self.foveationItem + Self.depthRangeItem)
        XCTAssertEqual(all.encodedItemsLength, writer.count)

        var reader = WireReader(writer.bytes)
        XCTAssertEqual(try SideData(items: &reader), all)
    }

    func testGoldenFramePayload() throws {
        let accessUnit = hex("00000002 2601") // one 2-byte NAL, AVCC length prefix
        let payload = try FramePayload.encode(sideData: SideData(depthRange: Fixtures.depthRange), accessUnit: accessUnit)
        let expected = hex("18000000", "1000") + Self.depthRangeItem + accessUnit // content 24, side data 16
        XCTAssertEqual(payload, expected)
        XCTAssertEqual(FramePayload.encodedLength(sideData: SideData(depthRange: Fixtures.depthRange),
                                                  accessUnitLength: accessUnit.count), expected.count)

        // Reassembled shards end in zero padding, which decode ignores.
        let decoded = try FramePayload.decode(payload + [UInt8](repeating: 0, count: 37))
        XCTAssertEqual(decoded.sideData, SideData(depthRange: Fixtures.depthRange))
        XCTAssertEqual(Array(decoded.accessUnit), accessUnit)
    }

    func testFrameWithoutSideDataCostsSixBytes() throws {
        let payload = try FramePayload.encode(sideData: .none, accessUnit: [1, 2, 3])
        XCTAssertEqual(payload, hex("05000000 0000 010203"))
        XCTAssertEqual(try FramePayload.decode(payload).sideData, .none)
    }

    func testSideDataOnlyFrame() throws {
        let payload = try FramePayload.encode(sideData: SideData(depthRange: .empty), accessUnit: [])
        XCTAssertEqual(payload, hex("12000000 1000 03 0d00 01 00000000 00000000 00000000"))
        let decoded = try FramePayload.decode(payload)
        XCTAssertEqual(decoded.sideData.depthRange, .empty)
        XCTAssertTrue(decoded.accessUnit.isEmpty)
    }

    func testUnknownItemsAreSkippedAndLongerValuesAccepted() throws {
        let unknown = hex("7a 0300 aabbcc")
        var longer = Self.foveationItem
        longer[1] = 0x16 // length 22: two appended bytes from a later revision
        longer += [0xEE, 0xEE]
        var reader = WireReader(unknown + longer)
        XCTAssertEqual(try SideData(items: &reader), SideData(foveation: Fixtures.foveation))
    }

    func testRejects() {
        func decode(_ bytes: [UInt8]) throws(WireError) -> SideData {
            var reader = WireReader(bytes)
            return try SideData(items: &reader)
        }
        XCTAssertWireError(.duplicate("sideData.foveation")) { try decode(Self.foveationItem + Self.foveationItem) }
        XCTAssertWireError(.truncated) { try decode(Array(Self.foveationItem.dropLast())) }
        var short = Self.foveationItem
        short[1] = 0x13 // declared shorter than the defined value
        XCTAssertWireError(.truncated) { try decode(Array(short.dropLast())) }
        var offCentre = Self.foveationItem
        offCentre[7...10] = [0x00, 0x00, 0x00, 0x40] // left x = 2.0, outside 0...1
        XCTAssertWireError(.invalid("foveation.leftCentre")) { try decode(offCentre) }
        var nanPose = Self.renderPoseItem
        nanPose[3 + 14 + 28...3 + 14 + 31] = [0x00, 0x00, 0xC0, 0x7F] // left angleLeft = NaN
        XCTAssertWireError(.invalid("renderPose.left.fieldOfView")) { try decode(nanPose) }
        var skewed = Self.renderPoseItem
        skewed[3 + 14 + 12...3 + 14 + 15] = [0, 0, 0, 0x40] // left w = 2: not a rotation
        XCTAssertWireError(.invalid("renderPose.left.pose")) { try decode(skewed) }
        var depth = Self.depthRangeItem
        depth[4...7] = [0, 0, 0, 0] // near = 0
        XCTAssertWireError(.invalid("depthRange.near")) { try decode(depth) }
        depth = Self.depthRangeItem
        depth[3] = 0x02 // reserved flag
        XCTAssertWireError(.invalid("depthRange.flags")) { try decode(depth) }
        depth = Self.depthRangeItem
        depth[3] = 0x01 // empty, but planes set
        XCTAssertWireError(.inconsistent("depthRange.empty")) { try decode(depth) }
    }

    func testPayloadRejects() throws {
        let good = try FramePayload.encode(sideData: .none, accessUnit: [1, 2, 3])
        XCTAssertWireError(.invalid("framePayload.padding")) { try FramePayload.decode(good + [0, 1]) }
        XCTAssertWireError(.truncated) { try FramePayload.decode(Array(good.dropLast())) }
        XCTAssertWireError(.truncated) { try FramePayload.decode(hex("05000000 0600 010203")) }
        // An invalid side data value can't be encoded either.
        let bad = SideData(depthRange: .planes(near: 1, far: 0.5, convergence: 0))
        XCTAssertWireError(.invalid("depthRange.far")) { try FramePayload.encode(sideData: bad, accessUnit: [1]) }
    }

    func testMotionFieldGoldenAndRoundTrip() throws {
        // One block per eye: left moved (3, -2) render pixels, right unknown.
        let field = MotionField(cellSize: 32, columns: 1, rows: 1, renderSize: PixelSize(width: 30, height: 20),
                                interval: 22_222, scale: 1, vectors: [3, -2, MotionField.unknown, 0])
        let side = SideData(depthRange: Fixtures.depthRange, motionField: field)
        var writer = WireWriter()
        try side.encodeItems(to: &writer)
        let item = hex("05 1600",   // type motionField, length 22
                       "00 20",     // flags, cell size 32
                       "0100 0100", // 1x1 blocks per eye
                       "1e00 1400", // render eye 30x20
                       "ce560000",  // interval 22222 us
                       "0000803f",  // scale 1
                       "03fe 8000") // left (3, -2), right unknown
        XCTAssertEqual(writer.bytes, Self.depthRangeItem + item)
        XCTAssertEqual(side.encodedItemsLength, writer.count)
        var reader = WireReader(writer.bytes)
        XCTAssertEqual(try SideData(items: &reader), side)

        // A 2536x2040 eye's field fits one item with room to spare.
        let eye = MotionField(cellSize: 32, columns: 80, rows: 64, renderSize: PixelSize(width: 2536, height: 2040),
                              interval: 22_222, scale: 1,
                              vectors: [Int8](repeating: 1, count: 4 * 80 * 64))
        let payload = try FramePayload.encode(sideData: SideData(depthRange: Fixtures.depthRange, motionField: eye),
                                              accessUnit: [1, 2])
        XCTAssertEqual(try FramePayload.decode(payload).sideData.motionField, eye)
    }

    func testMotionFieldRejects() {
        func encode(_ field: MotionField) throws(WireError) {
            var writer = WireWriter()
            try SideData(motionField: field).encodeItems(to: &writer)
        }
        XCTAssertWireError(.inconsistent("motionField.vectors")) {
            try encode(MotionField(cellSize: 32, columns: 2, rows: 1, renderSize: PixelSize(width: 40, height: 20), interval: 1,
                                   scale: 1, vectors: [0, 0, 0, 0]))
        }
        XCTAssertWireError(.invalid("motionField.interval")) {
            try encode(MotionField(cellSize: 32, columns: 1, rows: 1, renderSize: PixelSize(width: 30, height: 20), interval: 0,
                                   scale: 1, vectors: [0, 0, 0, 0]))
        }
        XCTAssertWireError(.invalid("motionField.size")) {
            try encode(MotionField(cellSize: 0, columns: 1, rows: 1, renderSize: PixelSize(width: 30, height: 20), interval: 1,
                                   scale: 1, vectors: [0, 0, 0, 0]))
        }
        XCTAssertWireError(.inconsistent("motionField.renderSize")) {
            try encode(MotionField(cellSize: 32, columns: 1, rows: 1, renderSize: PixelSize(width: 40, height: 20), interval: 1,
                                   scale: 1, vectors: [0, 0, 0, 0]))
        }
        var reader = WireReader(hex("05 1600 01 20 0100 0100 1e00 1400 ce560000 0000803f 03fe 8000"))
        XCTAssertWireError(.invalid("motionField.flags")) { try SideData(items: &reader) }
    }

    func testSeparatedHudMarkerDoesNotSetLegacyMask() throws {
        var writer = WireWriter()
        try SideData(hudSeparated: true).encodeItems(to: &writer)
        XCTAssertEqual(writer.bytes, hex("07 0100 01"))
        var reader = WireReader(writer.bytes)
        let metadata = try SideData(items: &reader)
        XCTAssertTrue(metadata.hudSeparated)
        XCTAssertFalse(metadata.hudMark)
        var repeated = WireReader(writer.bytes + writer.bytes)
        XCTAssertWireError(.duplicate("sideData.hudSeparated")) { try SideData(items: &repeated) }
    }

    func testTheHudMarkIsOneByte() throws {
        var writer = WireWriter()
        try SideData(hudMark: true).encodeItems(to: &writer)
        XCTAssertEqual(writer.bytes, hex("06 0100 01"))
        var reader = WireReader(writer.bytes)
        XCTAssertTrue(try SideData(items: &reader).hudMark)
        var bad = WireReader(hex("06 0100 00"))
        XCTAssertWireError(.invalid("sideData.hudMark")) { try SideData(items: &bad) }
    }
}

