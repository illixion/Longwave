#if FOVEATED_ENABLED
import Foundation
import Metal
import StreamWire
import UIKit
import XCTest
import simd
@testable import Longwave

extension PCVRWarpBenchTests {
    struct ResidualSample: Codable {
        var scenario: String
        var displayHz: Int
        var frame: Int
        var stage: String
        var region: String
        var metrics: PCVRResidualMetrics
        var gpuMs: Double?
        var image: String?
    }
    struct ResidualReport: Codable {
        var schema = 1
        var width = PCVRWarpBenchTests.width
        var height = PCVRWarpBenchTests.height
        var sourceHz = 60
        var samples: [ResidualSample]
        var scenarios: [ResidualCase]
        var traces: [ResidualTrace]
        var peakMetalBytes: Int
        var motion: String
        var notes = [
            "Deterministic synthetic room and motion, not a recording of the wearer.",
            "Sampling stage has no HEVC: it isolates centre/edge packing and resampling.",
            "Depth block noise is synthetic; 10-bit/float are hypothetical precision controls.",
            "Late mesh uses the production eye-mesh builder and equivalent material math; it does not emulate RealityKit temporal AA or system reprojection.",
            "GPU times and memory describe this Mac/simulator, not headset thermal performance.",
            "GPU timing: sampling is fixture packing only; warp is the production warper; late-mesh is mesh build plus proxy draw. Reference rendering, analysis-only unwarp, scoring and PNG work are excluded.",
            "Temporal error is change in truth-relative error in landmark-centred crops, not optical-flow alignment."
        ]
    }
    struct ResidualTrace: Codable {
        var scenario: String
        var displayHz: Int
        var frame: Int
        var sourceTime: Double
        var warpTime: Double
        var displayTime: Double
    }
    struct ResidualCase: Codable {
        var name: String
        var bits: Int
        var noise: Int = 0
        var overscan: Float = 1.02
        var lagMs: Double = 8
        var depthOffset: Int = 0
        var poseAgeMs: Double = 80
        var sourceHz: Double = 60
    }
    struct ResidualRegion {
        var name: String
        var centre: SIMD3<Float>
        var width: Int
        var height: Int
    }

    /// Deterministic fixture exercising sampling, pixel warp and late mesh as
    /// separate stages. Opt-in via scripts/bench-pcvr-residuals.sh.
    func testResidualStages() throws {
        let full = ProcessInfo.processInfo.environment["PCVR_RESIDUAL_PROFILE"] == "full"
        let frames = Int(ProcessInfo.processInfo.environment["PCVR_RESIDUAL_FRAMES"] ?? "") ?? (full ? 8 : 3)
        guard (2...24).contains(frames) else { throw XCTSkip("residual frames must be 2...24") }
        let rates = full ? [50, 60, 90, 120] : [60]
        let cases = full ? [
            ResidualCase(name: "8bit", bits: 8),
            ResidualCase(name: "8bit-block-noise", bits: 8, noise: 1),
            ResidualCase(name: "10bit", bits: 10),
            ResidualCase(name: "float-depth", bits: 0),
            ResidualCase(name: "wide-overscan", bits: 8, overscan: 1.30),
            ResidualCase(name: "no-late-miss", bits: 8, lagMs: 0),
            ResidualCase(name: "wrong-depth-control", bits: 8, depthOffset: -2),
            ResidualCase(name: "long-pipeline", bits: 8, poseAgeMs: 140),
            ResidualCase(name: "half-rate-source", bits: 8, sourceHz: 30)
        ] : [ResidualCase(name: "8bit", bits: 8), ResidualCase(name: "float-depth", bits: 0), ResidualCase(name: "no-late-miss", bits: 8, lagMs: 0)]
        let trajectory = try ProcessInfo.processInfo.environment["PCVR_BENCH_TRAJECTORY"].map {
            try Trajectory(contentsOf: URL(fileURLWithPath: $0))
        }
        func pose(_ time: Double) -> PCVRPose {
            guard let trajectory else { return Self.residualPose(time) }
            return Self.head * (trajectory.poses[0].inverse * trajectory.pose(at: trajectory.times[0] + time))
        }
        let regions = [
            ResidualRegion(name: "circle", centre: [0.75, 1.55, -1.8], width: 320, height: 320),
            ResidualRegion(name: "left-grid", centre: [-2.9, 1.0, -2.5], width: 256, height: 192),
            ResidualRegion(name: "right-grid", centre: [2, 1.0, -2.4], width: 256, height: 192),
            ResidualRegion(name: "floor", centre: [0.4, 0, -1.2], width: 256, height: 192)
        ]
        let library = try device.makeLibrary(source: "#include <metal_stdlib>\nusing namespace metal;\n" + PCVRFoveationShader.source + "\n" + Self.residualShader, options: nil)
        let pack = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "residualPack")))
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "residualMeshVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "residualMeshFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        descriptor.depthAttachmentPixelFormat = .depth32Float
        let meshPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual
        depthDescriptor.isDepthWriteEnabled = true
        let depthState = try XCTUnwrap(device.makeDepthStencilState(descriptor: depthDescriptor))
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        let sampler = try XCTUnwrap(device.makeSamplerState(descriptor: samplerDescriptor))
        let unwarper = try PCVRUnwarp(device: device)
        let warper = try PCVRDepthWarper(device: device)
        let builder = try PCVREyeMeshBuilder(device: device)
        let grid = PCVREyeMesh.Grid(columns: 256, rows: 200)
        let indices = grid.indices
        let indexBuffer = try XCTUnwrap(indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        var samples: [ResidualSample] = []
        var traces: [ResidualTrace] = []
        var peakAllocated = 0

        for config in cases {
            for rate in rates {
                var previous: [String: [Float]] = [:]
                var warpMetrics: [String: PCVRResidualMetrics] = [:]
                for number in 0..<frames {
                    try autoreleasepool {
                        // Both rates and frame age are explicit, independent of
                        // wall-clock execution speed and simulator scheduling.
                        let time = 0.12 + Double(number) / Double(rate)
                        let sourceTime = floor((time - config.poseAgeMs / 1000) * config.sourceHz) / config.sourceHz
                        traces.append(ResidualTrace(scenario: config.name, displayHz: rate, frame: number, sourceTime: sourceTime,
                            warpTime: time - config.lagMs / 1000, displayTime: time))
                        let renderEyes = Self.eyes(head: pose(sourceTime), overscan: config.overscan)
                        let warpEyes = Self.eyes(head: pose(time - config.lagMs / 1000), overscan: config.overscan)
                        let displayEyes = Self.eyes(head: pose(time), overscan: config.overscan)
                        let source = try render(renderEyes, readDepth: false)
                        let warpTruth = try render(warpEyes, readDepth: false)
                        let displayTruth = try render(displayEyes, readDepth: false)
                        let depthSource = config.depthOffset == 0 ? source : try render(
                            Self.eyes(head: pose(sourceTime + Double(config.depthOffset) / config.sourceHz), overscan: config.overscan), readDepth: false)
                        let depth = try hostDepthGPU(depthSource, divisor: 1, bits: config.bits, noise: config.noise)
                        let shape = CentreEdgeWarp(centreSizeX: 0.3, centreSizeY: 0.3, edgeRatioX: 3.5, edgeRatioY: 3.5)
                        let renderSize = PixelSize(width: UInt16(Self.width), height: UInt16(Self.height))
                        let wire = try XCTUnwrap(shape.wireSize(forRender: renderSize, alignment: 16))
                        let centres = renderEyes.map { Self.residualUV([0.75, 1.55, -1.8], in: $0) }
                        let mapping = try XCTUnwrap(PCVRFoveation(parameters: FoveationParameters(epoch: 1, warp: .centreEdge(shape)),
                            frame: FoveationSideData(parameterEpoch: 1,
                                leftCentre: NormalizedPoint(x: centres.left.x, y: centres.left.y),
                                rightCentre: NormalizedPoint(x: centres.right.x, y: centres.right.y)), renderEye: renderSize))
                        let packed = try residualTexture(.rgba16Float, width: Int(wire.width) * 2, height: Int(wire.height))
                        var maps = (0..<2).flatMap { eye -> [SIMD4<Float>] in
                            let c = mapping.constants(eye: eye); return [c.x, c.y]
                        }
                        let packBuffer = try XCTUnwrap(queue.makeCommandBuffer())
                        let encoder = try XCTUnwrap(packBuffer.makeComputeCommandEncoder())
                        encoder.setComputePipelineState(pack)
                        encoder.setTexture(source.colour, index: 0)
                        encoder.setTexture(packed, index: 1)
                        encoder.setSamplerState(sampler, index: 0)
                        encoder.setBytes(&maps, length: MemoryLayout<SIMD4<Float>>.stride * maps.count, index: 0)
                        encoder.dispatchThreads(MTLSize(width: packed.width, height: packed.height, depth: 1),
                                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                        encoder.endEncoding()
                        try residualFinish(packBuffer)
                        let frame = PCVRDecodedFrame(streamEpoch: 1, frameNumber: UInt32(number), texture: packed,
                            renderPose: PCVRRenderPose(poseSequence: UInt32(number), spaceEpoch: 0, displayTime: sourceTime, eyes: renderEyes),
                            foveation: mapping, arrivalTime: sourceTime)
                        let sampled = try residualUnpack(frame, using: unwarper)
                        let warped = try residualTexture(.rgba16Float, width: packed.width, height: packed.height)
                        let depthWidth = min(1296, depth.texture.width)
                        let warpedDepth = try residualTexture(.r16Float, width: depthWidth,
                            height: max(1, depth.texture.height * depthWidth / depth.texture.width))
                        let warpBuffer = try XCTUnwrap(queue.makeCommandBuffer())
                        try warper.encode(frame: frame, depth: depth, targets: warpEyes.map(\.pose), planeDistance: 50,
                            into: warped, warpedDepth: warpedDepth, commandBuffer: warpBuffer)
                        try residualFinish(warpBuffer)
                        let warpedFrame = PCVRDecodedFrame(streamEpoch: 1, frameNumber: UInt32(number), texture: warped,
                            renderPose: PCVRRenderPose(poseSequence: UInt32(number), spaceEpoch: 0, displayTime: time, eyes: warpEyes),
                            foveation: mapping, arrivalTime: time)
                        let expanded = try residualUnpack(warpedFrame, using: unwarper)
                        let meshResult = try residualMesh(frame: warpedFrame, depth: PCVRDepthMap(texture: warpedDepth, near: depth.near, far: depth.far),
                            display: displayEyes, builder: builder, grid: grid, indices: indexBuffer,
                            indexCount: indices.count, pipeline: meshPipeline, depthState: depthState, sampler: sampler)
                        let stages: [(String, any MTLTexture, Rendered, PCVRStereo<PCVREyeView>, Double?)] = [
                            ("sampling", sampled, source, renderEyes, Self.residualMs(packBuffer)),
                            ("warp", expanded, warpTruth, warpEyes, Self.residualMs(warpBuffer)),
                            ("late-mesh-proxy", meshResult.0, displayTruth, displayEyes, meshResult.1)
                        ]
                        for (stage, texture, truth, eyes, ms) in stages {
                            _ = try scoreGPU(warped: texture, truth: truth, truthEye: eyes.left, source: source, sourceEye: renderEyes.left, readSummary: false)
                            let classification = try XCTUnwrap(lastScoreMap)
                            for region in regions {
                                let uv = Self.residualUV(region.centre, in: eyes.left)
                                // Fail loudly if a fixture no longer contains its landmark.
                                guard (0...1).contains(uv.x), (0...1).contains(uv.y) else { continue }
                                let x = min(max(Int(uv.x * Float(Self.width)) - region.width / 2, 0), Self.width - region.width)
                                let y = min(max(Int(uv.y * Float(Self.height)) - region.height / 2, 0), Self.height - region.height)
                                let reference = residualCrop(truth.colour, x: x, y: y, width: region.width, height: region.height)
                                let actual = residualCrop(texture, x: x, y: y, width: region.width, height: region.height)
                                var labels = [Float](repeating: 0, count: region.width * region.height * 2)
                                labels.withUnsafeMutableBytes { classification.getBytes($0.baseAddress!, bytesPerRow: region.width * 8,
                                    from: MTLRegionMake2D(x, y, region.width, region.height), mipmapLevel: 0) }
                                let key = stage + ":" + region.name
                                let (metric, errors) = PCVRResidualMetrics.evaluate(truth: reference, actual: actual, width: region.width,
                                    classification: stride(from: 1, to: labels.count, by: 2).map { labels[$0] }, previousError: previous[key])
                                previous[key] = errors
                                if stage == "warp" { warpMetrics[region.name] = metric }
                                if config.lagMs == 0, stage == "late-mesh-proxy", let before = warpMetrics[region.name] {
                                    XCTAssertLessThan(abs(metric.mae - before.mae), 0.002, "zero late miss must reproduce the warped image")
                                }
                                XCTAssertTrue(metric.mae.isFinite && metric.p95.isFinite)
                                let name = "\(config.name)-\(rate)-\(number)-\(stage)-\(region.name).png"
                                let save = number == 0 || number == frames - 1
                                if save { try residualImage(reference, actual, width: region.width, height: region.height, name: name) }
                                samples.append(ResidualSample(scenario: config.name, displayHz: rate, frame: number, stage: stage,
                                    region: region.name, metrics: metric, gpuMs: ms, image: save ? name : nil))
                            }
                        }
                        peakAllocated = max(peakAllocated, device.currentAllocatedSize)
                    }
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ResidualReport(samples: samples, scenarios: cases, traces: traces, peakMetalBytes: peakAllocated, motion: trajectory == nil ? "synthetic-sine-v1" : "recorded")).write(to: directory.appendingPathComponent("residual-report.json"))
        print("Residual harness: \(samples.count) region samples; peak tracked Metal allocation \(peakAllocated) bytes")
    }

    static func residualPose(_ t: Double) -> PCVRPose {
        let phase = Float(t * 2 * .pi * 1.4)
        var pose = Self.head
        pose.position += SIMD3(0.025 * sin(phase), 0.012 * sin(phase * 1.7), 0.006 * cos(phase))
        pose.rotation = simd_quatf(angle: 0.07 * sin(phase), axis: [0,1,0]) * Self.head.rotation
        return pose
    }
    static func residualUV(_ point: SIMD3<Float>, in eye: PCVREyeView) -> SIMD2<Float> {
        let p = eye.pose.matrix.inverse * SIMD4(point, 1), t = eye.fieldOfView.tangents
        return SIMD2((p.x / -p.z - t.x) / (t.y - t.x), (t.z - p.y / -p.z) / (t.z - t.w))
    }
    func residualTexture(_ format: MTLPixelFormat, width: Int, height: Int) throws -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.storageMode = format == .depth32Float ? .private : .shared
        d.usage = format == .depth32Float ? .renderTarget : [.shaderRead, .shaderWrite, .renderTarget]
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }
    func residualFinish(_ buffer: any MTLCommandBuffer) throws {
        buffer.commit(); buffer.waitUntilCompleted()
        guard buffer.status == .completed else { throw buffer.error ?? NSError(domain: "PCVRResidualHarness", code: 1) }
    }
    static func residualMs(_ b: any MTLCommandBuffer) -> Double? {
        b.gpuEndTime > b.gpuStartTime ? (b.gpuEndTime - b.gpuStartTime) * 1000 : nil
    }
    func residualUnpack(_ frame: PCVRDecodedFrame, using unwarper: PCVRUnwarp) throws -> any MTLTexture {
        let out = try residualTexture(.rgba16Float, width: Self.width * 2, height: Self.height)
        let b = try XCTUnwrap(queue.makeCommandBuffer())
        try unwarper.encode(frame: frame, into: out, commandBuffer: b)
        try residualFinish(b)
        return out
    }
    func residualMesh(frame: PCVRDecodedFrame, depth: PCVRDepthMap, display: PCVRStereo<PCVREyeView>,
                      builder: PCVREyeMeshBuilder, grid: PCVREyeMesh.Grid, indices: any MTLBuffer, indexCount: Int,
                      pipeline: any MTLRenderPipelineState, depthState: any MTLDepthStencilState,
                      sampler: any MTLSamplerState) throws -> (any MTLTexture, Double?) {
        let out = try residualTexture(.rgba16Float, width: 2 * Self.width, height: Self.height)
        let z = try residualTexture(.depth32Float, width: out.width, height: out.height)
        let b = try XCTUnwrap(queue.makeCommandBuffer())
        let vertices = try (0..<2).map { _ in try XCTUnwrap(device.makeBuffer(length: grid.vertexCount * PCVREyeMesh.vertexStride)) }
        for eye in 0..<2 {
            let placement = PCVREyeMeshBuilder.Eye(frame: frame, eye: eye, grid: grid, distance: 50, flipV: true, share: .render)
            try builder.encode(placement, eyeIndex: eye, depth: depth, grid: grid, into: vertices[eye], commandBuffer: b)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1)
        pass.depthAttachment.texture = z
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        let e = try XCTUnwrap(b.makeRenderCommandEncoder(descriptor: pass))
        e.setRenderPipelineState(pipeline)
        e.setDepthStencilState(depthState)
        e.setCullMode(.none)
        e.setFragmentTexture(frame.texture, index: 0)
        e.setFragmentSamplerState(sampler, index: 0)
        for eye in 0..<2 {
            var matrix = display[eye].fieldOfView.projectionMatrix(near: 0.01, far: 100) * display[eye].pose.matrix.inverse
            e.setVertexBuffer(vertices[eye], offset: 0, index: 0)
            e.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            e.setViewport(MTLViewport(originX: Double(eye * Self.width), originY: 0, width: Double(Self.width),
                                      height: Double(Self.height), znear: 0, zfar: 1))
            e.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
        }
        e.endEncoding()
        try residualFinish(b)
        return (out, Self.residualMs(b))
    }
    func residualCrop(_ texture: any MTLTexture, x: Int, y: Int, width: Int, height: Int) -> [Float] {
        var bytes = [Float16](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 8,
            from: MTLRegionMake2D(x, y, width, height), mipmapLevel: 0) }
        return Array(unsafeUninitializedCapacity: width * height * 3) { out, initialized in
            for i in 0..<(width * height) {
                for c in 0..<3 { (out.baseAddress! + i * 3 + c).initialize(to: Float(bytes[i * 4 + c])) }
            }
            initialized = width * height * 3
        }
    }
    func residualImage(_ truth: [Float], _ actual: [Float], width: Int, height: Int, name: String) throws {
        let total = width * 3
        var bytes = [UInt8](repeating: 255, count: total * height * 4)
        for y in 0..<height { for x in 0..<width { for c in 0..<3 {
            let i = (y * width + x) * 3 + c
            let dst = (y * total + x) * 4 + c
            bytes[dst] = UInt8(min(max(truth[i], 0), 1) * 255)
            bytes[dst + width * 4] = UInt8(min(max(actual[i], 0), 1) * 255)
            bytes[dst + width * 8] = UInt8(min(abs(truth[i] - actual[i]) * 4, 1) * 255)
        } } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cg = try XCTUnwrap(CGImage(width: total, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: total * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        try XCTUnwrap(UIImage(cgImage: cg).pngData()).write(to: directory.appendingPathComponent(name))
    }
    static let residualShader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void residualPack(texture2d<float, access::sample> source [[texture(0)]],
                             texture2d<float, access::write> out [[texture(1)]],
                             constant float4 *maps [[buffer(0)]], sampler s [[sampler(0)]],
                             uint2 p [[thread_position_in_grid]]) {
        if (p.x >= out.get_width() || p.y >= out.get_height()) return;
        uint w = out.get_width() / 2, eye = p.x / w;
        float2 wire = (float2(p.x - eye * w, p.y) + 0.5) / float2(w, out.get_height());
        float2 uv = pcvrRenderUV(wire, maps[eye * 2], maps[eye * 2 + 1]);
        float2 size = float2(source.get_width(), source.get_height());
        float2 at = float2((uv.x + eye) * 0.5, uv.y);
        at = clamp(at, float2(eye * 0.5 + 0.5 / size.x, 0.5 / size.y), float2((eye + 1) * 0.5 - 0.5 / size.x, 1 - 0.5 / size.y));
        out.write(source.sample(s, at), p);
    }
    struct MeshVertex { packed_float3 position; packed_float2 uv; packed_float2 depth; };
    struct MeshOut { float4 position [[position]]; float2 uv; float depth; };
    vertex MeshOut residualMeshVertex(uint id [[vertex_id]], device const MeshVertex *v [[buffer(0)]], constant float4x4 &m [[buffer(1)]]) {
        MeshOut o; o.position = m * float4(float3(v[id].position), 1); o.uv = v[id].uv; o.depth = v[id].depth.x; return o;
    }
    fragment float4 residualMeshFragment(MeshOut in [[stage_in]], texture2d<float> image [[texture(0)]], sampler s [[sampler(0)]]) {
        return image.sample(s, in.uv / in.depth);
    }
    """
}
#endif
