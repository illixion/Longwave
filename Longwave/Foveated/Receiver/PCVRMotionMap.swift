#if FOVEATED_ENABLED
import Foundation
import Metal
import StreamWire

/// The game's own motion in a frame (`MotionField`, NATIVE_V3_PROTOCOL.md
/// section 4.8), as a texture the depth warp samples: per block of each eye,
/// where the block's content was one `interval` earlier, in render pixels,
/// both eyes side by side (`rg16Float`, unknown blocks still). The warp moves a
/// repeated display frame on along it (`PCVRMotionShift`), what Oculus called
/// asynchronous spacewarp: a game held at 45 fps on a 90 Hz display otherwise
/// shows each picture twice, and everything that moves in the game itself
/// steps every 22 ms and doubles on the retina, while the head's own turns,
/// which the warp corrects, are smooth (docs/PCVR_MOTION_EXTRAPOLATION.md).
nonisolated struct PCVRMotionMap: @unchecked Sendable {
    let texture: any MTLTexture
    let columns: Int
    let rows: Int
    let cellSize: Int
    /// The render eye the blocks tile.
    let renderSize: SIMD2<Float>
    /// Seconds from the previous frame's render time to this one's.
    let interval: TimeInterval
    /// Blocks that had motion, and their mean length in render pixels.
    let knownBlocks: Int
    let meanPixels: Float

    init?(field: MotionField, device: any MTLDevice) {
        let columns = Int(field.columns), rows = Int(field.rows)
        guard columns > 0, rows > 0, field.vectors.count == 4 * columns * rows else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: 2 * columns, height: rows,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        // Texel (eye * columns + column, row) from vectors[(eye * rows * columns + row * columns + column) * 2].
        var values = [Float16](repeating: 0, count: 2 * columns * rows * 2)
        var known = 0
        var total: Float = 0
        for eye in 0..<2 {
            for row in 0..<rows {
                for column in 0..<columns {
                    let from = (eye * rows * columns + row * columns + column) * 2
                    guard field.vectors[from] != MotionField.unknown else { continue }
                    let x = Float(field.vectors[from]) * field.scale, y = Float(field.vectors[from + 1]) * field.scale
                    let to = (row * 2 * columns + eye * columns + column) * 2
                    values[to] = Float16(x)
                    values[to + 1] = Float16(y)
                    known += 1
                    total += (x * x + y * y).squareRoot()
                }
            }
        }
        values.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, 2 * columns, rows), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: 2 * columns * 4)
        }
        texture.label = "PCVR motion"
        self.texture = texture
        self.columns = columns
        self.rows = rows
        cellSize = Int(field.cellSize)
        renderSize = SIMD2(Float(field.renderSize.width), Float(field.renderSize.height))
        interval = TimeInterval(field.interval) / 1_000_000
        knownBlocks = known
        meanPixels = known > 0 ? total / Float(known) : 0
    }
}

/// How far a display frame carries its frame's motion on: `amount` intervals
/// (0 on the frame's first display, 0.5 on its repeat at 45 on 90).
nonisolated struct PCVRMotionShift: @unchecked Sendable {
    let map: PCVRMotionMap
    let amount: Float

    /// The shift for a display frame `sinceFirstShown` seconds after the
    /// frame was first displayed, at most one interval ahead (beyond the next
    /// frame's time the guess is worth less than the stall it hides); nil when
    /// there is nothing to move.
    static func forDisplay(map: PCVRMotionMap?, sinceFirstShown: TimeInterval) -> PCVRMotionShift? {
        guard let map, map.interval > 0, sinceFirstShown > 0.001 else { return nil }
        let amount = Float(min(sinceFirstShown / map.interval, 1))
        return PCVRMotionShift(map: map, amount: amount)
    }

    /// The warp's per-eye constants: render pixels to render UV, scaled by the
    /// amount (xy); and where the eye's blocks are in the texture: its x
    /// offset, render UV to texture UV per axis, and the half texel kept off
    /// the other eye's blocks.
    func constants(eye: Int) -> (uv: SIMD4<Float>, rect: SIMD4<Float>) {
        let tiled = SIMD2(Float(map.columns * map.cellSize), Float(map.rows * map.cellSize))
        return (SIMD4(amount / map.renderSize.x, amount / map.renderSize.y, 0, 0),
                SIMD4(Float(eye) * 0.5, 0.5 * map.renderSize.x / tiled.x, map.renderSize.y / tiled.y,
                      0.5 / Float(2 * map.columns)))
    }
}
#endif
