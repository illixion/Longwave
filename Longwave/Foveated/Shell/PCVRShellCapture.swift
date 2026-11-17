//  PCVRShellCapture.swift
//
//  Diagnostics: the next few display frames of Shell A exactly as the render
//  loop saw them, for replay and comparison off the headset
//  (`scripts/pcvr-capture/`). Per display frame it keeps:
//  - the stream frame it showed (decoded BGRA, both eyes at wire size), its
//    render pose, foveation constants and frame number;
//  - the depth picture paired with it (8-bit luma as decoded, the HUD-mark
//    chroma when there is one) and the number of the frame that depth came with;
//  - each view's display pose and frustum, and what the warp handed the
//    compositor for it: the drawable's colour and depth, in the drawable's
//    physical (rate-mapped) pixels, with the rate map's screen-to-physical
//    lookup per axis.
//  The drawable is what the system compositor reprojects once more, so a fault
//  visible in it is ours; one absent from it is the compositor's.

#if FOVEATED_ENABLED && os(visionOS)
import CompositorServices
import Foundation
import Metal
import os
import simd

nonisolated final class PCVRShellCapture: @unchecked Sendable {
    static let shared = PCVRShellCapture()

    /// One image copied off the GPU.
    struct Section {
        var name: String
        var format: String
        var width: Int
        var height: Int
        var bytesPerRow: Int
        var buffer: (any MTLBuffer)?
        var data: Data?
    }

    /// One display frame. Filled on the render thread; read once `isComplete`.
    final class Frame: @unchecked Sendable {
        var meta: [String: Any] = [:]
        var sections: [Section] = []
        private let completion = OSAllocatedUnfairLock(initialState: false)
        var isComplete: Bool { completion.withLock { $0 } }
        func complete() { completion.withLock { $0 = true } }

        /// `LWCAP1\0\0`, the JSON header's length (UInt32, little endian), the
        /// header, then each section's rows packed in header order.
        func blob() -> Data {
            var offset = 0
            var described: [[String: Any]] = []
            var payloads: [Data] = []
            for section in sections {
                let bytes: Data
                if let data = section.data {
                    bytes = data
                } else if let buffer = section.buffer {
                    bytes = Data(bytes: buffer.contents(), count: section.bytesPerRow * section.height)
                } else {
                    continue
                }
                described.append(["name": section.name, "format": section.format, "width": section.width,
                                  "height": section.height, "bytesPerRow": section.bytesPerRow,
                                  "offset": offset, "length": bytes.count])
                offset += bytes.count
                payloads.append(bytes)
            }
            var header = meta
            header["sections"] = described
            let json = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) ?? Data("{}".utf8)
            var out = Data("LWCAP1\0\0".utf8)
            var length = UInt32(json.count).littleEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(json)
            for payload in payloads { out.append(payload) }
            return out
        }
    }

    private struct State {
        var remaining = 0
        var stride = 1
        var skipped = 0
        var frames: [Frame] = []
        var started: Date?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Asks for the next `count` display frames, one every `stride`; drops any earlier capture.
    func request(count: Int, stride: Int) {
        state.withLock { $0 = State(remaining: count, stride: max(stride, 1), skipped: 0, frames: [], started: Date()) }
    }

    var frames: [Frame] { state.withLock { $0.frames } }
    var remaining: Int { state.withLock { $0.remaining } }

    func clear() { state.withLock { $0 = State() } }

    /// The render thread's per-frame check: a frame to fill, or nil (cheap).
    func next() -> Frame? {
        state.withLock { s in
            guard s.remaining > 0 else { return nil }
            if s.skipped + 1 < s.stride {
                s.skipped += 1
                return nil
            }
            s.skipped = 0
            s.remaining -= 1
            let frame = Frame()
            s.frames.append(frame)
            return frame
        }
    }

    // MARK: Encoding helpers (render thread)

    /// Copies `texture` (slice `slice`) into a new shared buffer on `blit`.
    /// Nil for a texture the GPU may not copy from (framebuffer-only) or a
    /// format this capture does not name.
    static func copy(_ texture: any MTLTexture, slice: Int = 0, name: String, region: MTLRegion? = nil,
                     blit: any MTLBlitCommandEncoder, device: any MTLDevice) -> Section? {
        guard !texture.isFramebufferOnly, let (format, pixelBytes) = describe(texture.pixelFormat) else { return nil }
        let region = region ?? MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                         size: MTLSize(width: texture.width, height: texture.height, depth: 1))
        let bytesPerRow = region.size.width * pixelBytes
        guard let buffer = device.makeBuffer(length: bytesPerRow * region.size.height, options: .storageModeShared) else {
            return nil
        }
        blit.copy(from: texture, sourceSlice: slice, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size,
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * region.size.height)
        return Section(name: name, format: format, width: region.size.width, height: region.size.height,
                       bytesPerRow: bytesPerRow, buffer: buffer)
    }

    private static func describe(_ format: MTLPixelFormat) -> (String, Int)? {
        switch format {
        case .bgra8Unorm: ("bgra8", 4)
        case .bgra8Unorm_srgb: ("bgra8_srgb", 4)
        case .rgba8Unorm: ("rgba8", 4)
        case .rgba16Float: ("rgba16f", 8)
        case .depth32Float: ("depth32f", 4)
        case .r32Float: ("r32f", 4)
        case .r8Unorm: ("r8", 1)
        case .rg8Unorm: ("rg8", 2)
        default: nil
        }
    }

    static func json(_ pose: PCVRPose) -> [String: Any] {
        let q = pose.rotation.vector
        return ["rotation": [q.x, q.y, q.z, q.w].map(Double.init),
                "position": [pose.position.x, pose.position.y, pose.position.z].map(Double.init)]
    }

    static func json(_ view: PCVREyeView) -> [String: Any] {
        let t = view.fieldOfView.tangents
        return ["pose": json(view.pose), "tangents": [t.x, t.y, t.z, t.w].map(Double.init)]
    }

    static func json(_ v: SIMD4<Float>) -> [Double] { [v.x, v.y, v.z, v.w].map(Double.init) }

    static func json(_ m: simd_float4x4) -> [Double] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { json($0) }
    }

    /// A rate map's screen-to-physical lookup at pixel centres, per axis
    /// (Compositor Services' maps are separable), as float32 sections.
    static func rateMapSections(_ map: any MTLRasterizationRateMap, view: Int) -> [Section] {
        let size = map.screenSize
        guard size.width > 0, size.height > 0 else { return [] }
        var xs = [Float](), ys = [Float]()
        xs.reserveCapacity(size.width)
        ys.reserveCapacity(size.height)
        for x in 0..<size.width {
            xs.append(map.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: Float(x) + 0.5, y: 0.5), layer: 0).x)
        }
        for y in 0..<size.height {
            ys.append(map.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: 0.5, y: Float(y) + 0.5), layer: 0).y)
        }
        func section(_ name: String, _ values: [Float]) -> Section {
            Section(name: name, format: "f32", width: values.count, height: 1, bytesPerRow: values.count * 4,
                    data: values.withUnsafeBufferPointer { Data(buffer: $0) })
        }
        return [section("view\(view).rateX", xs), section("view\(view).rateY", ys)]
    }
}
#endif
