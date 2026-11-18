import Foundation
import Metal
import StreamWire
import XCTest
import simd
@testable import Longwave

#if FOVEATED_ENABLED
/// Opt-in: replays one Shell A capture (`pcvrShellCapture`, an LWCAP1 blob
/// from `scripts/pcvr-capture/lwcap.py fetch`) through `PCVRDepthWarper`'s
/// compute path, from the frame's render pose to the display pose the headset
/// warped it to, with and without `refinesEdges`, and writes each result as raw
/// BGRA for `lwcap.py replay-png`. Skipped unless
/// `TEST_RUNNER_PCVR_CAPTURE=/path/frame-N.lwcap`; the output goes beside it
/// (`TEST_RUNNER_PCVR_CAPTURE_OUT` overrides).
final class PCVRCaptureReplayTests: XCTestCase {
    struct Section { var format: String; var width: Int; var height: Int; var bytesPerRow: Int; var data: Data }

    static func read(_ url: URL) throws -> (header: [String: Any], sections: [String: Section]) {
        let data = try Data(contentsOf: url)
        guard data.count > 12, data.prefix(6) == Data("LWCAP1".utf8) else { throw CocoaError(.fileReadCorruptFile) }
        let length = Int(data[8]) | Int(data[9]) << 8 | Int(data[10]) << 16 | Int(data[11]) << 24
        let header = try XCTUnwrap(try JSONSerialization.jsonObject(with: data.subdata(in: 12..<(12 + length))) as? [String: Any])
        var sections: [String: Section] = [:]
        for s in header["sections"] as? [[String: Any]] ?? [] {
            let offset = 12 + length + (s["offset"] as? Int ?? 0)
            let count = s["length"] as? Int ?? 0
            sections[s["name"] as? String ?? ""] = Section(
                format: s["format"] as? String ?? "", width: s["width"] as? Int ?? 0, height: s["height"] as? Int ?? 0,
                bytesPerRow: s["bytesPerRow"] as? Int ?? 0, data: data.subdata(in: offset..<(offset + count)))
        }
        return (header, sections)
    }

    static func pose(_ json: Any?) throws -> PCVRPose {
        let p = try XCTUnwrap(json as? [String: Any])
        let r = try XCTUnwrap(p["rotation"] as? [Double]), t = try XCTUnwrap(p["position"] as? [Double])
        return PCVRPose(rotation: simd_quatf(ix: Float(r[0]), iy: Float(r[1]), iz: Float(r[2]), r: Float(r[3])),
                        position: SIMD3(Float(t[0]), Float(t[1]), Float(t[2])))
    }

    static func view(_ json: Any?) throws -> PCVREyeView {
        let v = try XCTUnwrap(json as? [String: Any])
        let t = try XCTUnwrap(v["tangents"] as? [Double]).map(Float.init)
        return PCVREyeView(pose: try pose(v["pose"]),
                           fieldOfView: PCVRFieldOfView(tangentLeft: t[0], tangentRight: t[1], tangentUp: t[2], tangentDown: t[3]))
    }

    /// The frame's foveation from its per-eye constants (a, b, r, L).
    static func foveation(_ json: Any?) throws -> PCVRFoveation? {
        guard let f = json as? [String: Any], let eyes = f["eyes"] as? [[String: Any]], eyes.count == 2,
              let render = f["renderEye"] as? [Int] else { return nil }
        func axis(_ eye: Int, _ name: String) throws -> (size: Float, ratio: Float, centre: Float) {
            let c = try XCTUnwrap(eyes[eye][name] as? [Double]).map(Float.init)
            return (c[1] - c[0], c[2], (c[0] + c[1]) / 2)
        }
        let lx = try axis(0, "x"), ly = try axis(0, "y"), rx = try axis(1, "x"), ry = try axis(1, "y")
        let warp = CentreEdgeWarp(centreSizeX: lx.size, centreSizeY: ly.size, edgeRatioX: lx.ratio, edgeRatioY: ly.ratio)
        let side = FoveationSideData(parameterEpoch: 1, leftCentre: NormalizedPoint(x: lx.centre, y: ly.centre),
                                     rightCentre: NormalizedPoint(x: rx.centre, y: ry.centre))
        return PCVRFoveation(parameters: FoveationParameters(epoch: 1, warp: .centreEdge(warp)), frame: side,
                             renderEye: PixelSize(width: UInt16(render[0]), height: UInt16(render[1])))
    }

    private func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, device: any MTLDevice,
                         usage: MTLTextureUsage = .shaderRead) throws -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = usage
        d.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }

    private func load(_ url: URL, device: any MTLDevice) throws
        -> (source: PCVRDepthWarper.FillSource, targets: PCVRStereo<PCVREyeView>) {
        let (header, sections) = try Self.read(url)
        let streamSection = try XCTUnwrap(sections["stream.colour"])
        let stream = try texture(.bgra8Unorm_srgb, streamSection.width, streamSection.height, device: device)
        streamSection.data.withUnsafeBytes {
            stream.replace(region: MTLRegionMake2D(0, 0, streamSection.width, streamSection.height), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: streamSection.bytesPerRow)
        }
        let depthSection = try XCTUnwrap(sections["depth.luma"])
        let depthTexture = try texture(.r8Unorm, depthSection.width, depthSection.height, device: device)
        depthSection.data.withUnsafeBytes {
            depthTexture.replace(region: MTLRegionMake2D(0, 0, depthSection.width, depthSection.height), mipmapLevel: 0,
                                 withBytes: $0.baseAddress!, bytesPerRow: depthSection.bytesPerRow)
        }
        let d = try XCTUnwrap(header["depth"] as? [String: Any])
        let far = d["far"] as? Double ?? -1
        var depth = PCVRDepthMap(texture: depthTexture, near: Float(d["near"] as? Double ?? 0.25),
                                 far: far < 0 ? .infinity : Float(far))
        depth.valueScale = Float(d["valueScale"] as? Double ?? 1)
        depth.valueOffset = Float(d["valueOffset"] as? Double ?? 0)

        let renderEyes = try XCTUnwrap(header["renderEyes"] as? [Any])
        let eyes = PCVRStereo(left: try Self.view(renderEyes[0]), right: try Self.view(renderEyes[1]))
        let number = UInt32(header["frameNumber"] as? Int ?? 1)
        let arrival = header["arrivalTime"] as? Double ?? 0
        let frame = PCVRDecodedFrame(streamEpoch: 0, frameNumber: number, texture: stream,
                                     renderPose: PCVRRenderPose(poseSequence: number, spaceEpoch: 0, displayTime: arrival, eyes: eyes),
                                     foveation: try Self.foveation(header["foveation"]), arrivalTime: arrival)
        let views = try XCTUnwrap(header["views"] as? [[String: Any]])
        return (.init(frame: frame, depth: depth),
                PCVRStereo(left: try Self.view(views[0]["display"]), right: try Self.view(views[min(1, views.count - 1)]["display"])))
    }

    func testReplayACapture() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["PCVR_CAPTURE"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_PCVR_CAPTURE to an LWCAP1 blob")
        }
        let url = URL(fileURLWithPath: path)
        let out = URL(fileURLWithPath: environment["PCVR_CAPTURE_OUT"] ?? url.deletingPathExtension().path + "-replay")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let (source, views) = try load(url, device: device)
        let frame = source.frame
        // PCVR_CAPTURE_SHIFT: metres to move both display eyes sideways (eye
        // space x), to see what a larger miss than the captured one does.
        let extra = Float(environment["PCVR_CAPTURE_SHIFT"] ?? "") ?? 0
        let nudge = PCVRPose(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), position: [extra, 0, 0])
        let targets = views.map { $0.pose * nudge }
        let render = frame.renderSize
        for refine in [false, true] {
            let warper = try PCVRDepthWarper(device: device)
            warper.refinesEdges = refine
            let output = try texture(.bgra8Unorm_srgb, render.width, render.height, device: device, usage: [.shaderRead, .shaderWrite])
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            try warper.encode(frame: frame, depth: source.depth, targets: targets, planeDistance: 50, into: output,
                              commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertEqual(commandBuffer.status, .completed, String(describing: commandBuffer.error))
            var bytes = [UInt8](repeating: 0, count: render.width * render.height * 4)
            bytes.withUnsafeMutableBytes {
                output.getBytes($0.baseAddress!, bytesPerRow: render.width * 4,
                                from: MTLRegionMake2D(0, 0, render.width, render.height), mipmapLevel: 0)
            }
            let name = "replay-\(refine ? "refined" : "plain")\(extra != 0 ? "-shift\(extra)" : "")-\(render.width)x\(render.height).bgra"
            try Data(bytes).write(to: out.appendingPathComponent(name))
        }
    }

    /// Replay a sequence through Shell A's fragment path with the same history
    /// admission policy as the headset. Count diagnostic colours around gaps.
    func testReplayBackgroundHistory() throws {
        guard let path = ProcessInfo.processInfo.environment["PCVR_BACKGROUND_REPLAY"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_PCVR_BACKGROUND_REPLAY to a directory of chronologically named LWCAP1 frames")
        }
        let directory = URL(fileURLWithPath: path)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lwcap" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThan(files.count, 4)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let warper = try PCVRDepthWarper(device: device)
        warper.tintsFills = true
        var history = PCVRBackgroundHistory()
        var recent: [PCVRDepthWarper.FillSource] = []
        var totals = SIMD3<Int>.zero
        var peak = 0
        for url in files {
            try autoreleasepool {
                let (source, views) = try load(url, device: device)
                let frame = source.frame
                let w = frame.texture.width / 2, h = frame.texture.height
                let target = PCVRReceiverTarget(eye: 0,
                    colorTexture: try texture(.bgra8Unorm, w, h, device: device, usage: .renderTarget),
                    depthTexture: nil, depthClearValue: 0,
                    viewport: MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1),
                    display: views.left, displayProjection: matrix_identity_float4x4)
                func render(_ archive: PCVRDepthWarper.BackgroundSources?, buffer: any MTLCommandBuffer) throws -> [UInt8] {
                    try warper.encode(frame: frame, depth: source.depth, views: [target], planeDistance: 50,
                                      fills: recent, background: archive, commandBuffer: buffer)
                    buffer.commit()
                    buffer.waitUntilCompleted()
                    XCTAssertEqual(buffer.status, .completed, String(describing: buffer.error))
                    var pixels = [UInt8](repeating: 0, count: w * h * 4)
                    pixels.withUnsafeMutableBytes {
                        target.colorTexture.getBytes($0.baseAddress!, bytesPerRow: w * 4,
                                                     from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
                    }
                    return pixels
                }
                history.expire(for: frame)
                let buffer = try XCTUnwrap(queue.makeCommandBuffer())
                if history.shouldSample(frame) {
                    history.remember(try warper.backgroundSnapshot(source, commandBuffer: buffer))
                }
                if let archive = history.pair(for: frame) {
                    let baseline = try render(nil, buffer: try XCTUnwrap(queue.makeCommandBuffer()))
                    let filled = try render(archive, buffer: buffer)
                    var recovered = 0
                    for i in stride(from: 0, to: baseline.count, by: 4) {
                        guard baseline[i] == 255, baseline[i + 1] == 0, baseline[i + 2] == 255 else { continue }
                        totals.x += 1
                        if filled[i] == 0, filled[i + 1] == 255, filled[i + 2] == 0 { recovered += 1 }
                    }
                    totals.y += recovered
                    totals.z += 1
                    if recovered > peak {
                        peak = recovered
                        try Data(baseline).write(to: directory.appendingPathComponent("baseline-\(w)x\(h).bgra"))
                        try Data(filled).write(to: directory.appendingPathComponent("background-\(w)x\(h).bgra"))
                    }
                } else {
                    buffer.commit()
                    buffer.waitUntilCompleted()
                    XCTAssertEqual(buffer.status, .completed)
                }
                recent.insert(source, at: 0)
                if recent.count > PCVRDepthWarper.fillFrames { recent.removeLast() }
            }
        }
        print("Background replay: \(totals.y) of \(totals.x) otherwise-unfilled pixels recovered across \(totals.z) frames; peak \(peak).")
        XCTAssertGreaterThan(totals.z, 0)
    }
}
#endif
