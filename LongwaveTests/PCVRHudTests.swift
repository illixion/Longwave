#if FOVEATED_ENABLED && os(visionOS)
import Metal
import simd
import XCTest
@testable import Longwave

final class PCVRHudTests: XCTestCase {
    func testStereoMatteBlendsOverWorldAndIgnoresWorldTransforms() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try PCVRHudRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let picture = try texture(device, width: 8, height: 8, target: false)
        // L/R colour over L/R matte. Left eye is half-alpha premultiplied
        // red. Right eye is opaque green. First two columns are transparent.
        write(picture) { x, y in
            let alpha: UInt8 = x % 4 < 2 ? 0 : (x < 4 ? 128 : 255)
            if y >= 4 { return [alpha, alpha, alpha, 255] }
            return x < 4 ? [188, 0, 0, 255] : [0, 255, 0, 255]
        }
        let fov = PCVRFieldOfView(tangents: SIMD4(-1, 1, 1, -1))
        let a = PCVREyeView(pose: .identity, fieldOfView: fov)
        let frame = PCVRDecodedFrame(streamEpoch: 1, frameNumber: 1, texture: picture,
                                     renderPose: PCVRRenderPose(poseSequence: 0, spaceEpoch: 0, displayTime: 0,
                                                                eyes: .init(left: a, right: a)),
                                     arrivalTime: 0)

        let outputs = try (0..<2).map { _ in try texture(device, width: 4, height: 4, target: true) }
        for output in outputs { write(output) { _, _ in [0, 0, 64, 255] } }
        let moved = PCVRPose(rotation: simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)),
                             position: SIMD3(4, 1, 6))
        let targets = outputs.enumerated().map { eye, texture in
            PCVRReceiverTarget(eye: eye, colorTexture: texture,
                               viewport: MTLViewport(originX: 0, originY: 0, width: 4, height: 4, znear: 0, zfar: 1),
                               display: PCVREyeView(pose: moved, fieldOfView: fov))
        }
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        renderer.encode(frame, targets: targets, commandBuffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertEqual(buffer.status, .completed, "\(String(describing: buffer.error))")
        XCTAssertEqual(pixel(outputs[0], atX: 0), [0, 0, 64, 255])
        XCTAssertEqual(pixel(outputs[1], atX: 0), [0, 0, 64, 255])
        XCTAssertEqual(pixel(outputs[1], atX: 3), [0, 255, 0, 255])
        let blended = pixel(outputs[0], atX: 3)
        XCTAssertLessThanOrEqual(abs(Int(blended[0]) - 128), 1)
        XCTAssertEqual(blended[1], 0)
        XCTAssertLessThanOrEqual(abs(Int(blended[2]) - 32), 1)
    }

    func testFeedExpiresAndRejectsAnOutOfOrderDecode() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let image = try texture(device, width: 8, height: 8, target: false)
        let eye = PCVREyeView(pose: .identity, fieldOfView: PCVRFieldOfView(tangents: SIMD4(-1, 1, 1, -1)))
        let pose = PCVRRenderPose(poseSequence: 0, spaceEpoch: 0, displayTime: 0, eyes: .init(left: eye, right: eye))
        let feed = PCVRHudFeed()
        feed.deliver(PCVRDecodedFrame(streamEpoch: 2, frameNumber: 7, texture: image, renderPose: pose, arrivalTime: 5))
        feed.deliver(PCVRDecodedFrame(streamEpoch: 2, frameNumber: 6, texture: image, renderPose: pose, arrivalTime: 5.1))
        XCTAssertEqual(feed.latest(now: 5.2)?.frameNumber, 7)
        XCTAssertNil(feed.latest(now: 5.4))
        feed.clear()
        XCTAssertNil(feed.latest(now: 5.2))
    }

    private func texture(_ device: any MTLDevice, width: Int, height: Int, target: Bool) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width,
                                                                 height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = target ? .renderTarget : .shaderRead
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func write(_ texture: any MTLTexture, pixels: (Int, Int) -> [UInt8]) {
        let bytes = (0..<texture.height).flatMap { y in (0..<texture.width).flatMap { x in pixels(x, y) } }
        bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: texture.width * 4)
        }
    }

    private func pixel(_ texture: any MTLTexture, atX x: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, 2, 1, 1), mipmapLevel: 0)
        return bytes
    }
}
#endif
