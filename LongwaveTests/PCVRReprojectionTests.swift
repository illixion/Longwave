import XCTest
import Metal
import simd
@testable import Longwave

/// The PCVR receiver's reprojection maths, checked against the definition
/// rather than against itself: a world point projected straight into the
/// render eye must land where the homography sends the same point's display
/// pixel. Random poses and asymmetric frusta, since a headset's are never
/// symmetric and a sign slip in one tangent hides behind a symmetric one.
///
/// Gated with the feature, like the rest of PCVR.
#if FOVEATED_ENABLED
final class PCVRReprojectionTests: XCTestCase {

    private var generator = SeededGenerator(seed: 0x5EED_CAFE)

    /// Signed tangents, left and down negative (stored as `XrFovf` angles).
    private let headsetFOV = PCVRFieldOfView(tangentLeft: -1.05, tangentRight: 0.85, tangentUp: 0.95, tangentDown: -1.15)

    // MARK: Helpers

    private func random(_ range: ClosedRange<Float>) -> Float {
        Float.random(in: range, using: &generator)
    }

    private func randomRotation(maxAngle: Float) -> simd_quatf {
        let axis = simd_normalize(SIMD3(random(-1...1), random(-1...1), random(-1...1)) + SIMD3(0, 1e-3, 0))
        return simd_quatf(angle: random(-maxAngle...maxAngle), axis: axis)
    }

    private func randomHeadPose() -> PCVRPose {
        PCVRPose(rotation: randomRotation(maxAngle: .pi),
                 position: SIMD3(random(-1...1), random(1.2...1.8), random(-1...1)))
    }

    /// A display eye a little moved from the render eye: what tens of
    /// milliseconds of head motion look like.
    private func perturbed(_ pose: PCVRPose, angle: Float, distance: Float) -> PCVRPose {
        let offset = simd_normalize(SIMD3(random(-1...1), random(-1...1), random(-1...1)) + SIMD3(1e-3, 0, 0)) * distance
        return PCVRPose(rotation: randomRotation(maxAngle: angle) * pose.rotation, position: pose.position + offset)
    }

    private func project(_ worldPoint: SIMD3<Float>, into eye: PCVREyeView) -> SIMD2<Float>? {
        eye.fieldOfView.ndc(ofEyePoint: eye.pose.inverse.transformPoint(worldPoint))
    }

    private func assertClose(_ a: SIMD2<Float>?, _ b: SIMD2<Float>?, accuracy: Float = 1e-4,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let a, let b else { return XCTFail("missing value: \(String(describing: a)) vs \(String(describing: b))", file: file, line: line) }
        XCTAssertLessThan(simd_distance(a, b), accuracy, "\(a) vs \(b)", file: file, line: line)
    }

    // MARK: Pose and frustum

    func testPoseRoundTripsThroughMatrixAndInverse() {
        for _ in 0..<50 {
            let pose = randomHeadPose()
            let back = PCVRPose(pose.matrix)
            XCTAssertTrue(back.isClose(to: pose, metres: 1e-5, radians: 1e-4))
            let identity = pose * pose.inverse
            XCTAssertTrue(identity.isClose(to: .identity, metres: 1e-5, radians: 1e-3))
            let point = SIMD3(random(-2...2), random(-2...2), random(-2...2))
            XCTAssertLessThan(simd_distance(pose.inverse.transformPoint(pose.transformPoint(point)), point), 1e-5)
        }
    }

    func testCompositionMatchesMatrixProduct() {
        let a = randomHeadPose(), b = PCVRPose(rotation: randomRotation(maxAngle: 0.2), position: SIMD3(0.032, 0, 0))
        let composed = (a * b).matrix, product = a.matrix * b.matrix
        for column in 0..<4 {
            XCTAssertLessThan(simd_distance(composed[column], product[column]), 1e-5)
        }
    }

    func testFieldOfViewNDCMapsEdgesToUnitSquare() {
        let fov = headsetFOV, t = fov.tangents
        assertClose(fov.ndc(ofEyePoint: SIMD3(t.x, 0, -1)).map { SIMD2($0.x, 0) }, SIMD2(-1, 0))
        assertClose(fov.ndc(ofEyePoint: SIMD3(t.y, 0, -1)).map { SIMD2($0.x, 0) }, SIMD2(1, 0))
        assertClose(fov.ndc(ofEyePoint: SIMD3(0, t.z, -1)).map { SIMD2(0, $0.y) }, SIMD2(0, 1))
        assertClose(fov.ndc(ofEyePoint: SIMD3(0, t.w, -1)).map { SIMD2(0, $0.y) }, SIMD2(0, -1))
        XCTAssertNil(fov.ndc(ofEyePoint: SIMD3(0, 0, 1)), "a point behind the eye has no NDC")
        let roundTrip = fov.ndcFromTangent * fov.tangentFromNDC
        for column in 0..<3 {
            XCTAssertLessThan(simd_distance(roundTrip[column], matrix_identity_float3x3[column]), 1e-6)
        }
    }

    func testFieldOfViewUsesOpenXRSignedAngles() {
        // XrFovf: radians, left and down negative.
        let fov = PCVRFieldOfView(angleLeft: -.pi / 4, angleRight: .pi / 6, angleUp: .pi / 5, angleDown: -.pi / 3)
        let t = fov.tangents
        XCTAssertEqual(t.x, -1, accuracy: 1e-6)
        XCTAssertEqual(t.y, tan(Float.pi / 6), accuracy: 1e-6)
        XCTAssertEqual(t.w, -tan(Float.pi / 3), accuracy: 1e-5)
        XCTAssertEqual(headsetFOV.angleLeft, atan(-1.05), accuracy: 1e-6)
        XCTAssertLessThan(headsetFOV.angleDown, 0)
        // The view axis sits off centre in an asymmetric frustum.
        assertClose(fov.ndc(ofEyePoint: SIMD3(0, 0, -1)),
                    SIMD2(-(t.y + t.x) / (t.y - t.x), -(t.z + t.w) / (t.z - t.w)))
    }

    func testFieldOfViewRecoveredFromProjection() {
        let projection = headsetFOV.projectionMatrix(near: 0.1, far: 100)
        let recovered = PCVRFieldOfView(projection: projection)
        XCTAssertLessThan(simd_reduce_max(simd_abs(recovered.tangents - headsetFOV.tangents)), 1e-5)
    }

    func testProjectionMatrixAgreesWithNDC() {
        let projection = headsetFOV.projectionMatrix(near: 0.1, far: 100)
        let point = SIMD3<Float>(0.3, -0.2, -1.7)
        let clip = projection * SIMD4(point, 1)
        assertClose(SIMD2(clip.x, clip.y) / clip.w, headsetFOV.ndc(ofEyePoint: point))
        XCTAssertEqual(clip.z / clip.w, 0.94212, accuracy: 1e-4, "forward depth, near 0 / far 1")
    }

    func testOverscanWidensEveryEdge() {
        let wide = headsetFOV.expanded(by: 0.1)
        XCTAssertEqual(wide.tangents.x, headsetFOV.tangents.x * 1.1, accuracy: 1e-5)
        XCTAssertEqual(wide.tangents.w, headsetFOV.tangents.w * 1.1, accuracy: 1e-5)
        XCTAssertLessThan(wide.angleLeft, headsetFOV.angleLeft, "wider means further from the axis")
        XCTAssertEqual(headsetFOV.expanded(by: -1), headsetFOV, "negative overscan is ignored")
    }

    // MARK: Homography

    func testIdenticalPosesMapEveryPixelToItself() {
        let eye = PCVREyeView(pose: randomHeadPose(), fieldOfView: headsetFOV)
        for mode in [PCVRReprojectionMode.none, .rotation, .rotationAndTranslation(planeDistance: 1.5)] {
            let h = PCVRReprojection.sourceFromDisplay(render: eye, display: eye, mode: mode)
            for ndc in [SIMD2<Float>(0, 0), SIMD2(0.9, -0.7), SIMD2(-1, 1)] {
                assertClose(PCVRReprojection.sourceNDC(forDisplayNDC: ndc, through: h), ndc)
            }
        }
    }

    func testDifferentFrustaAtTheSamePoseRemapByAngle() {
        // The host renders an overscanned frustum; with no motion, a display
        // pixel must sample the same direction in the wider frame.
        let pose = randomHeadPose()
        let display = PCVREyeView(pose: pose, fieldOfView: headsetFOV)
        let render = PCVREyeView(pose: pose, fieldOfView: headsetFOV.expanded(by: 0.15))
        let h = PCVRReprojection.sourceFromDisplay(render: render, display: display, mode: .rotation)
        let world = pose.transformPoint(SIMD3(0.4, 0.3, -1))
        assertClose(PCVRReprojection.sourceNDC(forDisplayNDC: project(world, into: display)!, through: h),
                    project(world, into: render))
    }

    func testRotationIsExactForAnyDepth() {
        for _ in 0..<100 {
            let renderPose = randomHeadPose()
            // Rotation only: both eyes share an origin.
            let displayPose = PCVRPose(rotation: randomRotation(maxAngle: 0.15) * renderPose.rotation,
                                       position: renderPose.position)
            let render = PCVREyeView(pose: renderPose, fieldOfView: headsetFOV)
            let display = PCVREyeView(pose: displayPose, fieldOfView: headsetFOV)
            let h = PCVRReprojection.sourceFromDisplay(render: render, display: display, mode: .rotation)
            let world = renderPose.transformPoint(SIMD3(random(-0.5...0.5), random(-0.5...0.5), -random(0.3...20)))
            guard let displayNDC = project(world, into: display), let renderNDC = project(world, into: render) else { continue }
            assertClose(PCVRReprojection.sourceNDC(forDisplayNDC: displayNDC, through: h), renderNDC)
        }
    }

    func testTranslationIsExactOnTheProxyPlane() {
        for _ in 0..<200 {
            let renderPose = randomHeadPose()
            let displayPose = perturbed(renderPose, angle: 0.1, distance: 0.03)
            let render = PCVREyeView(pose: renderPose, fieldOfView: headsetFOV)
            let display = PCVREyeView(pose: displayPose, fieldOfView: headsetFOV)
            let distance = random(0.5...4)
            let h = PCVRReprojection.sourceFromDisplay(render: render, display: display,
                                                       mode: .rotationAndTranslation(planeDistance: distance))
            // A point on the plane `distance` metres ahead of the render eye.
            let world = renderPose.transformPoint(SIMD3(random(-0.6...0.6) * distance, random(-0.6...0.6) * distance, -distance))
            guard let displayNDC = project(world, into: display), let renderNDC = project(world, into: render) else { continue }
            assertClose(PCVRReprojection.sourceNDC(forDisplayNDC: displayNDC, through: h), renderNDC, accuracy: 2e-4)
        }
    }

    func testTranslationErrorGrowsOffThePlane() {
        // Pure sideways translation: on the plane the mapping is exact; nearer
        // content lands short and farther content over-shoots, by baseline ×
        // (1/d − 1/D) in tangent units.
        let renderPose = PCVRPose(rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), position: SIMD3(0, 1.6, 0))
        let displayPose = PCVRPose(rotation: renderPose.rotation, position: renderPose.position + SIMD3(0.02, 0, 0))
        let fov = PCVRFieldOfView(tangentLeft: -1, tangentRight: 1, tangentUp: 1, tangentDown: -1)
        let render = PCVREyeView(pose: renderPose, fieldOfView: fov)
        let display = PCVREyeView(pose: displayPose, fieldOfView: fov)
        let h = PCVRReprojection.sourceFromDisplay(render: render, display: display,
                                                   mode: .rotationAndTranslation(planeDistance: 2))
        func error(atDepth depth: Float) -> Float {
            let world = renderPose.transformPoint(SIMD3(0, 0, -depth))
            let mapped = PCVRReprojection.sourceNDC(forDisplayNDC: project(world, into: display)!, through: h)!
            return mapped.x - project(world, into: render)!.x
        }
        XCTAssertEqual(error(atDepth: 2), 0, accuracy: 1e-5)
        // fov tangent 1 → NDC = tangent, so the expected error is baseline × (1/d − 1/D).
        XCTAssertEqual(error(atDepth: 0.5), -0.02 * (1 / 0.5 - 1 / 2), accuracy: 1e-4)
        XCTAssertEqual(error(atDepth: 50), -0.02 * (1 / 50 - 1 / 2), accuracy: 1e-4)
    }

    func testRotationModeIgnoresTranslation() {
        // Content at infinity: a translated display eye sees the same direction.
        let renderPose = randomHeadPose()
        let displayPose = PCVRPose(rotation: renderPose.rotation, position: renderPose.position + SIMD3(0.05, 0.02, -0.03))
        let render = PCVREyeView(pose: renderPose, fieldOfView: headsetFOV)
        let display = PCVREyeView(pose: displayPose, fieldOfView: headsetFOV)
        let h = PCVRReprojection.sourceFromDisplay(render: render, display: display, mode: .rotation)
        assertClose(PCVRReprojection.sourceNDC(forDisplayNDC: SIMD2(0.3, -0.2), through: h), SIMD2(0.3, -0.2))
    }

    func testNoneModeIgnoresMotionEntirely() {
        let renderPose = randomHeadPose()
        let render = PCVREyeView(pose: renderPose, fieldOfView: headsetFOV)
        let display = PCVREyeView(pose: perturbed(renderPose, angle: 0.3, distance: 0.1), fieldOfView: headsetFOV)
        let h = PCVRReprojection.sourceFromDisplay(render: render, display: display, mode: .none)
        assertClose(PCVRReprojection.sourceNDC(forDisplayNDC: SIMD2(0.5, 0.5), through: h), SIMD2(0.5, 0.5))
    }

    func testRayMissingThePlaneIsRejected() {
        // Turned 120° away: the display's centre ray points behind the render eye.
        let renderPose = PCVRPose(rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), position: SIMD3(0, 1.6, 0))
        let displayPose = PCVRPose(rotation: simd_quatf(angle: 2.1, axis: SIMD3(0, 1, 0)), position: renderPose.position)
        let render = PCVREyeView(pose: renderPose, fieldOfView: headsetFOV)
        let display = PCVREyeView(pose: displayPose, fieldOfView: headsetFOV)
        for mode in [PCVRReprojectionMode.rotation, .rotationAndTranslation(planeDistance: 2)] {
            let h = PCVRReprojection.sourceFromDisplay(render: render, display: display, mode: mode)
            XCTAssertNil(PCVRReprojection.sourceNDC(forDisplayNDC: .zero, through: h))
        }
    }

    // MARK: Depth plane

    func testDisplayPlaneContainsTheProxyPlanePoints() {
        for _ in 0..<50 {
            let renderPose = randomHeadPose()
            let displayPose = perturbed(renderPose, angle: 0.1, distance: 0.03)
            let render = PCVREyeView(pose: renderPose, fieldOfView: headsetFOV)
            let display = PCVREyeView(pose: displayPose, fieldOfView: headsetFOV)
            let distance = random(0.5...4)
            let plane = PCVRReprojection.displayPlane(render: render, display: display,
                                                      mode: .rotationAndTranslation(planeDistance: distance))
            let world = renderPose.transformPoint(SIMD3(random(-1...1), random(-1...1), -distance))
            let inDisplay = displayPose.inverse.transformPoint(world)
            XCTAssertEqual(simd_dot(SIMD3(plane.x, plane.y, plane.z), inDisplay), plane.w, accuracy: 1e-4)
        }
        let flat = PCVRReprojection.displayPlane(render: PCVREyeView(pose: .identity, fieldOfView: headsetFOV),
                                                 display: PCVREyeView(pose: .identity, fieldOfView: headsetFOV),
                                                 mode: .rotation)
        XCTAssertEqual(flat, SIMD4(0, 0, -1, PCVRReprojection.rotationOnlyPresentationDepth))
    }

    // MARK: Shaders

    /// The shaders compile from source at run time (see `PCVRReceiver`), so a
    /// typo would otherwise first show up as a black space on a headset.
    func testReceiverShadersCompileAndRun() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let receiver = try PCVRReceiver(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 64, height: 32, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 32, height: 32, mipmapped: false)
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        descriptor.width = 32
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let depth = try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor))
        let eye = PCVREyeView(pose: .identity, fieldOfView: headsetFOV)
        let frame = PCVRDecodedFrame(frameNumber: 1, texture: source,
                                     renderPose: PCVRRenderPose(poseSequence: 1, spaceEpoch: 0, displayTime: 0, eyes: PCVRStereo(left: eye, right: eye)),
                                     arrivalTime: 0)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let viewport = MTLViewport(originX: 0, originY: 0, width: 32, height: 32, znear: 0, zfar: 1)
        try receiver.encode(frame: frame, targets: [
            PCVRReceiverTarget(eye: 0, colorTexture: target, depthTexture: depth, viewport: viewport, display: eye,
                               displayProjection: headsetFOV.projectionMatrix(near: 0.1, far: 100)),
            PCVRReceiverTarget(eye: 1, colorTexture: target, viewport: viewport, display: eye),
        ], options: PCVRReceiverOptions(), commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, String(describing: commandBuffer.error))
    }

    #if DEBUG
    /// The fake remote's scene shader and label atlas, built the way Shell A builds them.
    func testFakeRemoteSceneCompiles() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        XCTAssertNoThrow(try PCVRFakeRemote(device: device, mailbox: PCVRFrameMailbox()))
    }
    #endif

    func testEyeRectsStayInsideTheirHalf() {
        let device = MTLCreateSystemDefaultDevice()!
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 200, height: 100, mipmapped: false)
        let texture = device.makeTexture(descriptor: descriptor)!
        let left = PCVRReceiver.eyeRect(eye: 0, texture: texture)
        let right = PCVRReceiver.eyeRect(eye: 1, texture: texture)
        XCTAssertEqual(left.x, 0.0025, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(left.x + left.z, 0.5 - 0.0025 + 1e-6)
        XCTAssertGreaterThanOrEqual(right.x, 0.5 + 0.0025 - 1e-6)
        XCTAssertLessThanOrEqual(right.x + right.z, 1 - 0.0025 + 1e-6)
    }
}

/// Deterministic randomness, so a failing case fails the same way every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        // SplitMix64.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
#endif
