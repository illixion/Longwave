import Foundation
import StreamWire

/// A QP offset for each 32x32 CTB of a PCVR wire picture (two warped eyes side
/// by side), by angle from its eye's warp centre: `foveaQP` out to
/// `foveaRadius` degrees, ramping to `edgeQP` at `edgeRadius` and beyond.
/// NVENC adds it to the QP its rate control picks (NV_ENC_QP_MAP_DELTA), so
/// the bits move from where the eye can't resolve them to where it looks.
///
/// Measured on pcvr-codec-bench (2026-11-09, a recorded head shake, 100
/// Mbit/s): -10/+10 at 8°/30° took the gaze from 32.5 to 40.4 dB (SSIM 0.973
/// to 0.993), and the encode got faster. The edge side of it is a trade: the
/// periphery is also seen (a side box 25° off the gaze), and +10 there doubled the
/// block-edge excess of the compressed edges against no map at all (1.07 against
/// 0.59 at 70 Mbit/s; the wearer saw blocky sides). -10/+3 keeps the gaze within
/// 0.6 dB of +10 on a good link and takes 24 % of the blockiness back.
public struct FovealQPMap: Sendable, Equatable {
    public var foveaQP: Int
    public var edgeQP: Int
    public var foveaRadius: Double
    public var edgeRadius: Double

    public init(foveaQP: Int = -10, edgeQP: Int = 3, foveaRadius: Double = 8, edgeRadius: Double = 30) {
        self.foveaQP = foveaQP
        self.edgeQP = edgeQP
        self.foveaRadius = foveaRadius
        self.edgeRadius = edgeRadius
    }

    public var isEnabled: Bool { foveaQP != 0 || edgeQP != 0 }

    /// CTBs across and down for a picture.
    public static func size(width: Int, height: Int) -> (width: Int, height: Int) {
        ((width + 31) / 32, (height + 31) / 32)
    }

    /// The offsets, raster order, for a picture of two `wireEye`s side by side
    /// warped by `maps` from eyes with these fields of view.
    public func offsets(maps: StereoCentreEdgeMapping, fieldsOfView: (left: FieldOfView, right: FieldOfView),
                        wireEye: PixelSize) -> [Int8] {
        let width = Int(wireEye.width) * 2, height = Int(wireEye.height)
        let size = Self.size(width: width, height: height)
        var map = [Int8](repeating: 0, count: size.width * size.height)
        func tangents(_ f: FieldOfView) -> [Double] {
            [tan(Double(f.angleLeft)), tan(Double(f.angleRight)), tan(Double(f.angleUp)), tan(Double(f.angleDown))]
        }
        let t = [tangents(fieldsOfView.left), tangents(fieldsOfView.right)]
        let mappings = [maps.left, maps.right]
        func direction(_ u: Double, _ v: Double, _ t: [Double]) -> [Double] {
            let d = [t[0] + u * (t[1] - t[0]), t[2] - v * (t[2] - t[3]), -1]
            let n = (d[0] * d[0] + d[1] * d[1] + 1).squareRoot()
            return d.map { $0 / n }
        }
        let centres = (0..<2).map { direction(Double(mappings[$0].x.effectiveCentre), Double(mappings[$0].y.effectiveCentre), t[$0]) }
        let span = max(edgeRadius - foveaRadius, 1e-3)
        let eyeWidth = Double(wireEye.width), eyeHeight = Double(wireEye.height)
        for cy in 0..<size.height {
            let wv = Float(min((Double(cy) + 0.5) * 32 / eyeHeight, 1))
            for cx in 0..<size.width {
                let px = (Double(cx) + 0.5) * 32
                let eye = px >= eyeWidth ? 1 : 0
                let wu = Float(min(max((px - Double(eye) * eyeWidth) / eyeWidth, 0), 1))
                guard let uv = mappings[eye].renderUV(forWire: NormalizedPoint(x: wu, y: wv)) else { continue }
                let d = direction(Double(uv.x), Double(uv.y), t[eye]), c = centres[eye]
                let angle = acos(min(1, d[0] * c[0] + d[1] * c[1] + d[2] * c[2])) * 180 / .pi
                let f = min(max((angle - foveaRadius) / span, 0), 1)
                let offset = (Double(foveaQP) * (1 - f) + Double(edgeQP) * f).rounded()
                map[cy * size.width + cx] = Int8(max(-51, min(51, offset)))
            }
        }
        return map
    }
}
