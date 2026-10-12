import StreamWire
import XCTest

final class FormatDescriptionTests: XCTestCase {
    static let pcvrBytes = hex(
        "10000000",        // streamID 0x10
        "00000000",        // firstFrameNumber
        "01", "01",        // HEVC, Annex-B parameter sets
        "000f", "8007",    // 3840 x 1920
        "0a", "01",        // 10-bit, 4:2:0
        "01 01 01 00",     // BT.709, video range
        "0500 0000000140", // configuration
        "03 0200 0102",    // ext sideDataTypes: renderPose, foveation
        "05 1e00",         // ext pcvr, 30 bytes:
        "01",              //   side by side
        "000a 000a",       //   render 2560 x 2560 per eye
        "8007 8007",       //   wire 1920 x 1920 per eye
        "03000000",        //   foveation epoch 3
        "01",              //   centre-edge warp
        "0000003f 0000003f 00000040 00000040") // centre 0.5 x 0.5, edge ratio 2 x 2

    static let gameBytes = hex(
        "00000000", "64000000", "01", "01",
        "000a", "a005",           // 2560 x 1440
        "0a", "01",
        "09 10 09 00",            // BT.2020 PQ
        "0600 000000014001",
        "01 1800",                // ext masteringDisplay (G, B, R, white, max, min)
        "c233 c486 4c1d b80b d084 803e 133d 4240 80969800 01000000",
        "02 0400 e803 9001")      // ext contentLightLevel 1000 / 400

    static let depthBytes = hex(
        "00000080", "64000000", "01", "01",
        "0005", "d002",           // 1280 x 720
        "0a", "01",
        "02 02 02 01",            // unspecified colour, full range
        "0500 0000000140",
        "03 0100 03",             // ext sideDataTypes: depthRange
        "04 0500 02 00000000",    // ext auxiliary: depth of stream 0
        "06 0200 01 0a")          // ext depthEncoding: inverse linear, 10 bits

    func testGoldenVectors() throws {
        for (format, bytes) in [(Fixtures.pcvrFormat, Self.pcvrBytes), (Fixtures.gameFormat, Self.gameBytes),
                                (Fixtures.depthFormat, Self.depthBytes)] {
            XCTAssertEqual(hexString(try format.encoded()), hexString(bytes))
            XCTAssertEqual(try FormatDescription(decoding: bytes), format)
        }
    }

    func testAsControlMessage() throws {
        let message = try Fixtures.depthFormat.encodedMessage()
        XCTAssertEqual(Array(message.prefix(2)), [0x20, UInt8(Self.depthBytes.count)])
        let parsed = try XCTUnwrap(try MessageFraming.next(in: message[...]))
        XCTAssertEqual(parsed.message.type, .formatDescription)
        XCTAssertEqual(try FormatDescription(decoding: parsed.message.body), Fixtures.depthFormat)
    }

    func testUnknownExtensionsAreSkipped() throws {
        let withUnknown = Self.depthBytes + hex("c8 0400 01020304") + hex("09 0000")
        XCTAssertEqual(try FormatDescription(decoding: withUnknown), Fixtures.depthFormat)
    }

    func testStructuralRejects() {
        XCTAssertWireError(.duplicate("format.extension(3)")) {
            try FormatDescription(decoding: Self.depthBytes + hex("03 0100 03"))
        }
        var bytes = Self.pcvrBytes
        bytes[30...31] = [0x02, 0x01] // side data types out of order
        XCTAssertWireError(.invalid("format.sideDataTypes.order")) { try FormatDescription(decoding: bytes) }
        bytes = Self.pcvrBytes
        bytes[48] = 0x02 // unknown warp kind
        XCTAssertWireError(.invalid("format.pcvr.warpKind")) { try FormatDescription(decoding: bytes) }
        bytes = Self.pcvrBytes
        bytes[19] = 0x02 // fullRange must be 0 or 1
        XCTAssertWireError(.invalid("format.fullRange")) { try FormatDescription(decoding: bytes) }
        bytes = Self.pcvrBytes
        bytes[8] = 0x04 // unknown codec
        XCTAssertWireError(.invalid("format.codec")) { try FormatDescription(decoding: bytes) }
        XCTAssertWireError(.invalid("format.sideDataTypes")) {
            try FormatDescription(decoding: Array(Self.gameBytes) + hex("03 0000"))
        }
        for cut in [0, 10, 21, 25, 30] {
            XCTAssertWireError(.truncated) { try FormatDescription(decoding: Self.pcvrBytes[0..<cut]) }
        }
    }

    func testSemanticRejects() {
        func expect(_ error: WireError, _ base: FormatDescription = Fixtures.pcvrFormat,
                    line: UInt = #line, _ change: (inout FormatDescription) -> Void) {
            var format = base
            change(&format)
            XCTAssertWireError(error, line: line) { try format.encoded() }
        }
        expect(.missing("format.configuration")) { $0.configuration = [] }
        expect(.invalid("format.size")) { $0.size.height = 0 }
        expect(.invalid("format.bitDepth")) { $0.bitDepth = 7 }
        expect(.inconsistent("format.formatKind")) { $0.codec = .av1 }
        expect(.missing("format.sideDataTypes.renderPose")) { $0.sideDataTypes = [.foveation] }
        expect(.missing("format.sideDataTypes.foveation")) { $0.sideDataTypes = [.renderPose] }
        expect(.inconsistent("format.pcvr.wireSize")) { $0.size.width = 3842 }
        expect(.inconsistent("format.pcvr.renderSize")) { $0.pcvr?.foveation.warp = .none }
        expect(.invalid("foveation.centreSize")) {
            $0.pcvr?.foveation.warp = .centreEdge(CentreEdgeWarp(centreSizeX: 0, centreSizeY: 1, edgeRatioX: 1, edgeRatioY: 1))
        }
        expect(.invalid("foveation.edgeRatio")) {
            $0.pcvr?.foveation.warp = .centreEdge(CentreEdgeWarp(centreSizeX: 1, centreSizeY: 1, edgeRatioX: 0.5, edgeRatioY: 1))
        }
        expect(.inconsistent("format.pcvr")) { $0.auxiliary = AuxiliaryStream(role: .alpha, primaryStreamID: 1) }

        expect(.inconsistent("format.auxiliary.primaryStreamID"), Fixtures.depthFormat) { format in let id = format.streamID; format.auxiliary?.primaryStreamID = id }
        expect(.inconsistent("format.depthEncoding"), Fixtures.depthFormat) { $0.depthEncoding = nil }
        expect(.inconsistent("format.depthEncoding"), Fixtures.depthFormat) { $0.auxiliary?.role = .alpha }
        expect(.missing("format.sideDataTypes.depthRange"), Fixtures.depthFormat) { $0.sideDataTypes = [] }
        expect(.invalid("format.depthEncoding.valueBits"), Fixtures.depthFormat) { $0.depthEncoding?.valueBits = 11 }
        expect(.invalid("masteringDisplay.luminance"), Fixtures.gameFormat) { $0.masteringDisplay?.minLuminance = 20_000_000 }
        expect(.invalid("masteringDisplay.chromaticity"), Fixtures.gameFormat) { $0.masteringDisplay?.redX = 50001 }
    }

    func testFrameSideDataAgainstFormat() throws {
        let pcvr = Fixtures.pcvrFormat
        try pcvr.validate(frameSideData: SideData(renderPose: Fixtures.renderPose, foveation: Fixtures.foveation))
        XCTAssertWireError(.missing("sideData.renderPose")) { try pcvr.validate(frameSideData: SideData(foveation: Fixtures.foveation)) }
        XCTAssertWireError(.missing("sideData.foveation")) { try pcvr.validate(frameSideData: SideData(renderPose: Fixtures.renderPose)) }
        XCTAssertWireError(.inconsistent("sideData.foveation.parameterEpoch")) {
            try pcvr.validate(frameSideData: SideData(renderPose: Fixtures.renderPose, foveation: FoveationSideData(parameterEpoch: 4)))
        }
        XCTAssertWireError(.inconsistent("sideData.undeclared")) {
            try pcvr.validate(frameSideData: SideData(renderPose: Fixtures.renderPose, foveation: Fixtures.foveation,
                                                      depthRange: .empty))
        }
        try Fixtures.depthFormat.validate(frameSideData: SideData(depthRange: .empty))
        XCTAssertWireError(.missing("sideData.depthRange")) { try Fixtures.depthFormat.validate(frameSideData: .none) }
        try Fixtures.gameFormat.validate(frameSideData: .none)
    }
}
