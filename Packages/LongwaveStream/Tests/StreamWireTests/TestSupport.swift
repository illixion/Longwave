import StreamWire
import XCTest

/// Bytes from hex fragments; spaces are ignored, so vectors can be written
/// one field per fragment.
func hex(_ parts: String...) -> [UInt8] {
    let digits = parts.joined().filter { !$0.isWhitespace }
    precondition(digits.count % 2 == 0, "odd hex digit count")
    var bytes: [UInt8] = []
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        bytes.append(UInt8(digits[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

func hexString(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
}

/// Asserts that `body` throws exactly `expected`.
func XCTAssertWireError<T>(_ expected: WireError, file: StaticString = #filePath, line: UInt = #line,
                           _ body: () throws -> T) {
    do {
        let value = try body()
        XCTFail("expected \(expected), decoded \(value)", file: file, line: line)
    } catch let error as WireError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got non-wire error \(error)", file: file, line: line)
    }
}

/// SplitMix64: tiny, seedable, the same sequence on every platform, so a
/// failing fuzz iteration reproduces anywhere from its seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Fixtures with exact binary32 values, so golden vectors are hand-checkable.
//   1.0 = 3f800000   1.5 = 3fc00000   0.75 = 3f400000   0.5 = 3f000000
//   0.03125 = 3d000000   0.25 = 3e800000   2.0 = 40000000   0.125 = 3e000000

enum Fixtures {
    static let fov = FieldOfView(angleLeft: -0.75, angleRight: 0.75, angleUp: 0.75, angleDown: -0.75)
    static let leftEye = EyeView(pose: Pose(orientation: .identity, position: Vector3(-0.03125, 0, 0)), fieldOfView: fov)
    static let rightEye = EyeView(pose: Pose(orientation: .identity, position: Vector3(0.03125, 0, 0)), fieldOfView: fov)

    static let renderPose = RenderPose(poseSequence: 7, spaceEpoch: 2, displayTime: 0x0102_0304_0506_0708,
                                       left: leftEye, right: rightEye)
    static let foveation = FoveationSideData(parameterEpoch: 3)
    static let depthRange = DepthRange.planes(near: 0.125, far: .infinity, convergence: 2)

    static let warp = CentreEdgeWarp(centreSizeX: 0.5, centreSizeY: 0.5, edgeRatioX: 2, edgeRatioY: 2)

    /// 2 x 1920 x 1920 eyes, rendered at 2560 x 2560 each.
    static let pcvrFormat = FormatDescription(
        streamID: 0x10, firstFrameNumber: 0, codec: .hevc, formatKind: .annexBParameterSets,
        size: PixelSize(width: 3840, height: 1920), bitDepth: 10, chromaFormat: .yuv420, colour: .bt709,
        configuration: [0, 0, 0, 1, 0x40], sideDataTypes: [.renderPose, .foveation],
        pcvr: PCVRLayout(layout: .sideBySide, renderSize: PixelSize(width: 2560, height: 2560),
                         wireSize: PixelSize(width: 1920, height: 1920),
                         foveation: FoveationParameters(epoch: 3, warp: .centreEdge(warp))))

    static let gameFormat = FormatDescription(
        streamID: 0, firstFrameNumber: 100, codec: .hevc, formatKind: .annexBParameterSets,
        size: PixelSize(width: 2560, height: 1440), bitDepth: 10, chromaFormat: .yuv420, colour: .bt2020PQ,
        configuration: [0, 0, 0, 1, 0x40, 0x01], masteringDisplay: .p3D65_1000,
        contentLightLevel: ContentLightLevel(maxContentLightLevel: 1000, maxFrameAverageLightLevel: 400))

    static let depthFormat = FormatDescription(
        streamID: 0x8000_0000, firstFrameNumber: 100, codec: .hevc, formatKind: .annexBParameterSets,
        size: PixelSize(width: 1280, height: 720), bitDepth: 10, chromaFormat: .yuv420,
        colour: ColourInfo(primaries: 2, transfer: 2, matrix: 2, fullRange: true),
        configuration: [0, 0, 0, 1, 0x40], sideDataTypes: [.depthRange],
        auxiliary: AuxiliaryStream(role: .depth, primaryStreamID: 0),
        depthEncoding: DepthEncoding(kind: .inverseLinear, valueBits: 10))

    static let headPose = HeadPose(
        displayTime: 1_000_000, spaceEpoch: 1,
        head: Pose(orientation: .identity, position: Vector3(0, 1.5, 0)),
        leftEye: leftEye, rightEye: rightEye,
        presented: PresentedFrame(frameNumber: 41, presentTime: 900_000),
        gaze: GazeSample(direction: Vector3(0, 0, -1), distance: 0.5, sampleTime: 990_000))

    static let gamepad = GamepadState(
        buttons: [.south, .dpadUp], leftX: 100, leftY: -100, rightX: 0, rightY: 32767, leftTrigger: 0, rightTrigger: 65535,
        motion: GamepadMotion(rotationRate: Vector3(0.25, 0, 0), acceleration: Vector3(0, -1, 0)),
        touchpad: [TouchpadContact(id: 1, x: 0x8000, y: 0x4000)])
}
