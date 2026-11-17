// The game's own image motion for a PCVR frame (`MotionField`, section 4.8),
// from a motion search between this frame and the previous one: what the
// headset needs to carry that motion on in the display frames that repeat
// this one (docs/PCVR_MOTION_EXTRAPOLATION.md).
//
// The search (NVENC's motion-estimation-only mode, `lw_motion`) runs on a
// smaller copy of both eyes side by side and returns one vector per block of
// that copy: the content at `p` was at `p + v` in the previous picture,
// quarter pixels. That motion has two parts. One is the head's: between two
// frames the wearer turned, and every static thing in the picture moved with
// that turn. The headset's warp already moves each frame from its render pose
// to the display pose, so this part must not be carried on again. The other is
// the game's own (cars, the camera of a vehicle, walking): that part is what a
// repeated frame lacks. So the head's share, the move a still world at
// infinity makes when the eye turns from the previous render orientation to
// this one, is subtracted per block. The head's translation is left in: over
// one 45 Hz frame it is a few millimetres, a pixel or two of parallax at a
// metre.
//
// Vectors are then cleaned by a 3x3 median of the known blocks around each
// (the search's stray vectors in flat or repeating texture would otherwise
// warble in place) and quantised to `scale` render pixels a unit.
import Foundation
import StreamWire

public enum MotionFieldBuilder {
    /// The search's output, both eyes side by side in one picture.
    public struct Search {
        public var gridWidth: Int
        public var gridHeight: Int
        /// Search-picture pixels per block side.
        public var block: Int
        /// Per block x then y, quarter pixels of the search picture.
        public var vectors: [Int16]
        /// 0 where the block had no inter vector.
        public var known: [UInt8]
        /// One eye of the search picture (it holds two side by side).
        public var eye: PixelSize

        public init(gridWidth: Int, gridHeight: Int, block: Int, vectors: [Int16], known: [UInt8], eye: PixelSize) {
            self.gridWidth = gridWidth
            self.gridHeight = gridHeight
            self.block = block
            self.vectors = vectors
            self.known = known
            self.eye = eye
        }
    }

    /// Motion under this many pixels of the search picture is taken as still:
    /// searched against the turned previous picture, a still synthetic scene
    /// left 96% of blocks within it (pcvr-codec-bench --mode motion, 2026-11-17),
    /// and at 4x to the render eye the rest would shimmer by a few pixels.
    public static let noiseFloor: Float = 1

    /// The search picture's eye for a render eye: a quarter per axis, rounded
    /// up to whole 8-pixel blocks so no block straddles the two eyes.
    public static func searchEye(forRender eye: PixelSize, divisor: Int = 4) -> PixelSize {
        func scaled(_ v: UInt16) -> UInt16 { UInt16(max(8, (Int(v) / divisor + 7) & ~7)) }
        return PixelSize(width: scaled(eye.width), height: scaled(eye.height))
    }

    /// What went into a field, for diagnostics: mean lengths over the known
    /// cells (render pixels) of the motion the search measured, the share the
    /// head's turn explains, and what is left, before cleaning.
    public struct Diagnostics: Sendable {
        public var cells = 0
        public var measured: Double = 0
        public var head: Double = 0
        public var residual: Double = 0
        /// Cells with motion that the previous field didn't confirm, sent still.
        public var unconfirmed = 0
        /// Per cell, both eyes (left then right, rows top first): the
        /// measured and the residual motion, nil where unknown.
        public var measuredCells: [SIMD2<Float>?] = []
        public var residualCells: [SIMD2<Float>?] = []
    }

    /// The field for this frame, or nil when the two frames can't be compared
    /// (no time between them).
    public static func field(search: Search, renderEye: PixelSize, current: RenderPose, previous: RenderPose,
                             cellSize: Int = PCVRProfile.motionCellSize,
                             scale: Float = PCVRProfile.motionScale) -> MotionField? {
        build(search: search, renderEye: renderEye, current: current, previous: previous, cellSize: cellSize,
              scale: scale)?.field
    }

    public static func build(search: Search, renderEye: PixelSize, current: RenderPose, previous: RenderPose,
                             cellSize: Int = PCVRProfile.motionCellSize, scale: Float = PCVRProfile.motionScale,
                             keepCells: Bool = false, turnRemoved: Bool = false,
                             floor: Float = noiseFloor, history: MotionField? = nil)
        -> (field: MotionField, diagnostics: Diagnostics)? {
        guard current.displayTime > previous.displayTime, search.block > 0, cellSize > 0,
              search.vectors.count >= search.gridWidth * search.gridHeight * 2,
              search.known.count >= search.gridWidth * search.gridHeight else { return nil }
        let micros = (current.displayTime - previous.displayTime) / 1000
        guard micros > 0, micros <= UInt64(UInt32.max) else { return nil }
        let columns = (Int(renderEye.width) + cellSize - 1) / cellSize
        let rows = (Int(renderEye.height) + cellSize - 1) / cellSize
        guard cellSize <= 255, columns * rows <= MotionField.maxBlocksPerEye else { return nil }
        // Render pixels per search pixel, and per quarter of one.
        let sx = Float(renderEye.width) / Float(search.eye.width), sy = Float(renderEye.height) / Float(search.eye.height)
        var vectors = [Int8](repeating: 0, count: 4 * columns * rows)
        var diagnostics = Diagnostics()
        for eye in 0..<2 {
            let now = eye == 0 ? current.left : current.right
            let before = eye == 0 ? previous.left : previous.right
            let turn = Rotation(from: now.pose.orientation, to: before.pose.orientation)
            // Residual motion per output cell, render pixels; nil where unknown.
            var cells = [SIMD2<Float>?](repeating: nil, count: columns * rows)
            /// Per cell, where its content was in the previous frame's render eye (the turn's share).
            var origins = [SIMD2<Float>](repeating: .zero, count: columns * rows)
            var measuredCells = [SIMD2<Float>?](repeating: nil, count: keepCells ? columns * rows : 0)
            for row in 0..<rows {
                for column in 0..<columns {
                    let p = SIMD2<Float>((Float(column) + 0.5) * Float(cellSize), (Float(row) + 0.5) * Float(cellSize))
                    // The search block under the cell's centre.
                    let bx = eye * (Int(search.eye.width) / search.block) + min(Int(p.x / sx) / search.block,
                                                                              Int(search.eye.width) / search.block - 1)
                    let by = min(Int(p.y / sy) / search.block, search.gridHeight - 1)
                    let b = by * search.gridWidth + bx
                    guard b >= 0, b < search.gridWidth * search.gridHeight, search.known[b] != 0 else { continue }
                    let measured = SIMD2<Float>(Float(search.vectors[b * 2]) / 4 * sx, Float(search.vectors[b * 2 + 1]) / 4 * sy)
                    // Where the turn puts this cell's content in the previous picture: a cell
                    // whose content was outside it (coming into view at an edge) has nothing
                    // there to match, and the search's vector for it is noise.
                    let turned = headMotion(at: p, renderEye: renderEye, now: now.fieldOfView, before: before.fieldOfView,
                                            turn: turn)
                    guard let turned, (0..<Float(renderEye.width)).contains(p.x + turned.x),
                          (0..<Float(renderEye.height)).contains(p.y + turned.y) else { continue }
                    // Searched against the previous picture already turned to this
                    // pose (`previousFromCurrent`): the search's vector is the game's.
                    let head: SIMD2<Float>? = turnRemoved ? .zero : turned
                    origins[row * columns + column] = p + turned
                    let residual = measured - (head ?? .zero)
                    cells[row * columns + column] = residual
                    diagnostics.cells += 1
                    diagnostics.measured += length(measured)
                    diagnostics.head += length(head ?? .zero)
                    diagnostics.residual += length(residual)
                    if keepCells { measuredCells[row * columns + column] = measured }
                }
            }
            if keepCells {
                diagnostics.measuredCells += measuredCells
                diagnostics.residualCells += cells
            }
            for row in 0..<rows {
                for column in 0..<columns {
                    let at = (eye * columns * rows + row * columns + column) * 2
                    guard let v = median(cells, column: column, row: row, columns: columns, rows: rows) else {
                        vectors[at] = MotionField.unknown
                        vectors[at + 1] = 0
                        continue
                    }
                    func quantised(_ value: Float) -> Int8 { Int8(min(max((value / scale).rounded(), -127), 127)) }
                    // Under the search's precision (a pixel of its picture): still. And motion
                    // the previous frame didn't have where this content was is taken as
                    // the search's noise (road markings and other repeating texture warped in
                    // place, headset 2026-11-17): real motion carries on from frame to frame.
                    var still = (v.x / sx) * (v.x / sx) + (v.y / sy) * (v.y / sy) < floor * floor
                    if !still, let history,
                       !agrees(v, history: history, eye: eye, at: origins[row * columns + column] + v, cellSize: cellSize) {
                        still = true
                        diagnostics.unconfirmed += 1
                    }
                    vectors[at] = still ? 0 : quantised(v.x)
                    vectors[at + 1] = still ? 0 : quantised(v.y)
                }
            }
        }
        if diagnostics.cells > 0 {
            let n = Double(diagnostics.cells)
            diagnostics.measured /= n
            diagnostics.head /= n
            diagnostics.residual /= n
        }
        let field = MotionField(cellSize: UInt8(min(cellSize, 255)), columns: UInt16(columns), rows: UInt16(rows),
                                renderSize: renderEye, interval: UInt32(micros), scale: scale, vectors: vectors)
        return (field, diagnostics)
    }

    private static func length(_ v: SIMD2<Float>) -> Double { Double((v.x * v.x + v.y * v.y).squareRoot()) }

    /// Whether the previous field had about this motion (within 40% of it, or
    /// 3 pixels) at `point` of `eye`'s previous render image, in the cell there
    /// or one beside it.
    static func agrees(_ v: SIMD2<Float>, history: MotionField, eye: Int, at point: SIMD2<Float>, cellSize: Int) -> Bool {
        let columns = Int(history.columns), rows = Int(history.rows)
        guard Int(history.cellSize) == cellSize, columns > 0, rows > 0 else { return true }
        let cx = Int((point.x / Float(cellSize)).rounded(.down)), cy = Int((point.y / Float(cellSize)).rounded(.down))
        let tolerance = max(3, 0.4 * Float(length(v)))
        for dy in -1...1 {
            for dx in -1...1 {
                let x = cx + dx, y = cy + dy
                guard x >= 0, x < columns, y >= 0, y < rows else { continue }
                let at = (eye * columns * rows + y * columns + x) * 2
                guard history.vectors[at] != MotionField.unknown else { continue }
                let h = SIMD2(Float(history.vectors[at]), Float(history.vectors[at + 1])) * history.scale
                if length(h - v) <= Double(tolerance) { return true }
            }
        }
        return false
    }

    /// Where the point at render pixel `p` of this frame's eye was in the
    /// previous frame's, for a still world at infinity, minus `p`: the motion
    /// the turn alone explains (nil if it was behind the previous eye).
    static func headMotion(at p: SIMD2<Float>, renderEye: PixelSize, now: FieldOfView, before: FieldOfView,
                           turn: Rotation) -> SIMD2<Float>? {
        let w = Float(renderEye.width), h = Float(renderEye.height)
        let l = tan(now.angleLeft), r = tan(now.angleRight), u = tan(now.angleUp), d = tan(now.angleDown)
        // Eye space: x right, y up, -z forward (OpenXR).
        let ray = SIMD3<Float>(l + p.x / w * (r - l), u - p.y / h * (u - d), -1)
        let old = turn.apply(ray)
        guard old.z < -1e-4 else { return nil }
        let tx = old.x / -old.z, ty = old.y / -old.z
        let l0 = tan(before.angleLeft), r0 = tan(before.angleRight), u0 = tan(before.angleUp), d0 = tan(before.angleDown)
        let q = SIMD2<Float>((tx - l0) / (r0 - l0) * w, (u0 - ty) / (u0 - d0) * h)
        return q - p
    }

    /// The median of each axis over the known cells in the 3x3 around one;
    /// unknown when the cell itself is.
    private static func median(_ cells: [SIMD2<Float>?], column: Int, row: Int, columns: Int, rows: Int) -> SIMD2<Float>? {
        guard cells[row * columns + column] != nil else { return nil }
        var xs: [Float] = [], ys: [Float] = []
        xs.reserveCapacity(9)
        ys.reserveCapacity(9)
        for y in max(row - 1, 0)...min(row + 1, rows - 1) {
            for x in max(column - 1, 0)...min(column + 1, columns - 1) {
                guard let v = cells[y * columns + x] else { continue }
                xs.append(v.x)
                ys.append(v.y)
            }
        }
        xs.sort()
        ys.sort()
        return SIMD2(xs[xs.count / 2], ys[ys.count / 2])
    }

    /// The homography that turns the previous picture to this frame's render
    /// orientation, per eye (left, then right, 9 values each, row-major): from a
    /// pixel of this frame's `eye`-sized eye to the previous picture's pixel
    /// showing the same direction (a still world at infinity). Searching the
    /// frame against the previous picture turned so leaves only the game's
    /// own motion, and a block the search can't place (flat or repeating
    /// texture) reads as still, which for the world it is.
    public static func previousFromCurrent(eye: PixelSize, current: RenderPose, previous: RenderPose) -> [Float] {
        var out: [Float] = []
        for e in 0..<2 {
            let now = e == 0 ? current.left : current.right, before = e == 0 ? previous.left : previous.right
            let w = Float(eye.width), h = Float(eye.height)
            let l = tan(now.fieldOfView.angleLeft), r = tan(now.fieldOfView.angleRight)
            let u = tan(now.fieldOfView.angleUp), d = tan(now.fieldOfView.angleDown)
            let l0 = tan(before.fieldOfView.angleLeft), r0 = tan(before.fieldOfView.angleRight)
            let u0 = tan(before.fieldOfView.angleUp), d0 = tan(before.fieldOfView.angleDown)
            // Pixel to ray in this eye: (l + x (r - l) / w, u - y (u - d) / h, -1).
            let a: [[Float]] = [[(r - l) / w, 0, l], [0, -(u - d) / h, u], [0, 0, -1]]
            let turn = Rotation(from: now.pose.orientation, to: before.pose.orientation)
            let m: [[Float]] = [[turn.m.0.x, turn.m.0.y, turn.m.0.z], [turn.m.1.x, turn.m.1.y, turn.m.1.z],
                                [turn.m.2.x, turn.m.2.y, turn.m.2.z]]
            // Ray in the previous eye to its pixel (homogeneous, w = -z).
            let kx = w / (r0 - l0), ky = h / (u0 - d0)
            let b: [[Float]] = [[kx, 0, kx * l0], [0, -ky, -ky * u0], [0, 0, -1]]
            func product(_ x: [[Float]], _ y: [[Float]]) -> [[Float]] {
                (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(Float(0)) { $0 + x[i][$1] * y[$1][j] } } }
            }
            out += product(b, product(m, a)).flatMap { $0 }
        }
        return out
    }

    /// The rotation taking a direction in one eye's space to the same world
    /// direction in another's: `before⁻¹ · now`.
    struct Rotation {
        var m: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) // rows

        init(from now: Quaternion, to before: Quaternion) {
            let a = Self.matrix(now), b = Self.matrix(before)
            // before⁻¹ = transpose(b); rows of bᵀ·a.
            func column(_ m: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), _ i: Int) -> SIMD3<Float> {
                SIMD3(m.0[i], m.1[i], m.2[i])
            }
            let bt = (column(b, 0), column(b, 1), column(b, 2))
            func row(_ r: SIMD3<Float>) -> SIMD3<Float> {
                SIMD3((r * column(a, 0)).sum(), (r * column(a, 1)).sum(), (r * column(a, 2)).sum())
            }
            m = (row(bt.0), row(bt.1), row(bt.2))
        }

        func apply(_ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3((m.0 * v).sum(), (m.1 * v).sum(), (m.2 * v).sum())
        }

        static func matrix(_ q: Quaternion) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
            let n = (q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w).squareRoot()
            let x = q.x / n, y = q.y / n, z = q.z / n, w = q.w / n
            return (SIMD3(1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)),
                    SIMD3(2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)),
                    SIMD3(2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)))
        }
    }
}
