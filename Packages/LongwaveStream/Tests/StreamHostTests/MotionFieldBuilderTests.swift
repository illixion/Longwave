import Foundation
@testable import StreamHost
import StreamWire
import XCTest

final class MotionFieldBuilderTests: XCTestCase {
    let renderEye = PixelSize(width: 2536, height: 2040)
    let fov = FieldOfView(angleLeft: -0.9, angleRight: 0.8, angleUp: 0.75, angleDown: -0.85)

    func pose(yaw: Float, displayTime: UInt64) -> RenderPose {
        let q = Quaternion(x: 0, y: sin(yaw / 2), z: 0, w: cos(yaw / 2))
        func eye(_ x: Float) -> EyeView { EyeView(pose: Pose(orientation: q, position: Vector3(x, 0, 0)), fieldOfView: fov) }
        return RenderPose(poseSequence: 1, spaceEpoch: 0, displayTime: displayTime, left: eye(-0.032), right: eye(0.032))
    }

    func testTheSearchEyeIsAQuarterInWholeBlocks() {
        XCTAssertEqual(MotionFieldBuilder.searchEye(forRender: renderEye), PixelSize(width: 640, height: 512))
    }

    func testTurningLeftMovesTheWorldRight() throws {
        // Turned 1 degree left since the previous frame: the centre's content was
        // left of the centre then (v.x < 0), by the turn in pixels.
        let yaw = Float(1.0 * .pi / 180)
        let turn = MotionFieldBuilder.Rotation(from: pose(yaw: yaw, displayTime: 0).left.pose.orientation,
                                               to: pose(yaw: 0, displayTime: 0).left.pose.orientation)
        let centreX = (0 - tan(fov.angleLeft)) / (tan(fov.angleRight) - tan(fov.angleLeft)) * Float(renderEye.width)
        let p = SIMD2<Float>(centreX, 1000)
        let v = try XCTUnwrap(MotionFieldBuilder.headMotion(at: p, renderEye: renderEye, now: fov, before: fov, turn: turn))
        let expected = -tan(yaw) * Float(renderEye.width) / (tan(fov.angleRight) - tan(fov.angleLeft))
        XCTAssertEqual(v.x, expected, accuracy: 0.5)
        XCTAssertLessThan(v.x, -15) // about 19 pixels a degree here
        XCTAssertEqual(v.y, 0, accuracy: 0.5)
    }

    /// A search whose every block saw the head's turn plus `game` render pixels.
    func search(yaw: Float, game: SIMD2<Float>, unknownBlock: Int? = nil) -> MotionFieldBuilder.Search {
        let eye = MotionFieldBuilder.searchEye(forRender: renderEye)
        let block = 8
        let gridWidth = 2 * Int(eye.width) / block, gridHeight = Int(eye.height) / block
        let sx = Float(renderEye.width) / Float(eye.width), sy = Float(renderEye.height) / Float(eye.height)
        let turn = MotionFieldBuilder.Rotation(from: pose(yaw: yaw, displayTime: 0).left.pose.orientation,
                                               to: pose(yaw: 0, displayTime: 0).left.pose.orientation)
        var vectors = [Int16](repeating: 0, count: gridWidth * gridHeight * 2)
        var known = [UInt8](repeating: 1, count: gridWidth * gridHeight)
        for by in 0..<gridHeight {
            for bx in 0..<gridWidth {
                let local = bx % (gridWidth / 2)
                let p = SIMD2<Float>((Float(local * block) + 4) * sx, (Float(by * block) + 4) * sy)
                let head = MotionFieldBuilder.headMotion(at: p, renderEye: renderEye, now: fov, before: fov, turn: turn) ?? .zero
                let v = head + game
                vectors[(by * gridWidth + bx) * 2] = Int16((v.x / sx * 4).rounded())
                vectors[(by * gridWidth + bx) * 2 + 1] = Int16((v.y / sy * 4).rounded())
            }
        }
        if let unknownBlock { known[unknownBlock] = 0 }
        return MotionFieldBuilder.Search(gridWidth: gridWidth, gridHeight: gridHeight, block: block, vectors: vectors,
                                         known: known, eye: eye)
    }

    func testTheHeadsTurnIsRemovedAndTheGamesMotionKept() throws {
        let yaw = Float(1.5 * .pi / 180)
        let current = pose(yaw: yaw, displayTime: 1_022_222_222), previous = pose(yaw: 0, displayTime: 1_000_000_000)
        for game in [SIMD2<Float>(0, 0), SIMD2<Float>(9, -5)] {
            let field = try XCTUnwrap(MotionFieldBuilder.field(search: search(yaw: yaw, game: game), renderEye: renderEye,
                                                               current: current, previous: previous))
            XCTAssertEqual(field.columns, 80)
            XCTAssertEqual(field.rows, 64)
            XCTAssertEqual(field.cellSize, 32)
            XCTAssertEqual(field.interval, 22_222)
            XCTAssertEqual(field.vectors.count, 4 * 80 * 64)
            for i in stride(from: 0, to: field.vectors.count, by: 2) {
                XCTAssertEqual(Float(field.vectors[i]), game.x, accuracy: 1, "block \(i / 2) x")
                XCTAssertEqual(Float(field.vectors[i + 1]), game.y, accuracy: 1, "block \(i / 2) y")
            }
        }
    }

    func testABlockWithoutAVectorIsUnknownAndAStrayOneIsOutvoted() throws {
        let current = pose(yaw: 0, displayTime: 2_000_000), previous = pose(yaw: 0, displayTime: 1_000_000)
        var s = search(yaw: 0, game: SIMD2(4, 0), unknownBlock: 0)
        // A stray vector in the middle of the left eye: its neighbours outvote it.
        let stray = 30 * s.gridWidth + 40
        s.vectors[stray * 2] = 400
        let field = try XCTUnwrap(MotionFieldBuilder.field(search: s, renderEye: renderEye, current: current, previous: previous))
        XCTAssertEqual(field.vectors[0], MotionField.unknown)
        XCTAssertEqual(field.vectors[1], 0)
        // Search block (40, 30) is under render cell (40, 30) (4x scale, 8-pixel blocks, 32-pixel cells).
        let cell = (30 * 80 + 40) * 2
        XCTAssertEqual(field.vectors[cell], 4)
        XCTAssertNil(MotionFieldBuilder.field(search: s, renderEye: renderEye, current: previous, previous: current))
    }
}
