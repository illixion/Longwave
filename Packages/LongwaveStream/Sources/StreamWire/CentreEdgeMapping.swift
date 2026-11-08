// Reference sampling equations for v3's centre/edge warp. No platform or GPU
// dependencies: the encoder and receiver must use these same coordinates.

/// One render axis compressed around a full-density centre interval.
/// The centre interval is shifted inside 0...1, preserving its entire width.
/// Coordinates are texture edges, not pixel indices; sample at pixel centres.
public struct CentreEdgeAxisMapping: Sendable, Hashable {
    public let effectiveCentre: Float
    /// Wire/render dimension ratio needed to preserve centre pixel density.
    /// Align actual dimensions to the codec separately, then report them.
    public let wireScale: Float
    private let lower: Double
    private let upper: Double
    private let ratio: Double
    private let scale: Double

    public init?(centreSize: Float, edgeRatio: Float, centre: Float) {
        guard centreSize.isFinite, centreSize > 0, centreSize <= 1,
              edgeRatio.isFinite, edgeRatio >= 1,
              centre.isFinite, (0...1).contains(centre) else { return nil }
        let size = Double(centreSize), r = Double(edgeRatio)
        let c = min(max(Double(centre), size / 2), 1 - size / 2)
        let start = c - size / 2, end = c + size / 2
        // Refuse a centre too narrow for the reference arithmetic to represent.
        guard end > start else { return nil }
        lower = start
        upper = end
        ratio = r
        scale = size + (1 - size) / r
        wireScale = Float(scale)
        effectiveCentre = Float(c)
    }

    /// The four numbers both GPU passes evaluate the maps from, as a shader
    /// vector: the centre interval's start `a` and end `b` in render UV, the
    /// edge ratio `r` and the packed length `L` (`wireScale`). The host's warp
    /// and the headset's unwarp take exactly these, so neither re-derives them.
    public var constants: SIMD4<Float> {
        SIMD4(Float(lower), Float(upper), Float(ratio), Float(scale))
    }

    /// Receiver sampling: where an unwarped render UV reads the wire texture.
    public func wireCoordinate(forRender coordinate: Float) -> Float? {
        guard coordinate.isFinite, (0...1).contains(coordinate) else { return nil }
        let x = Double(coordinate)
        let packed: Double
        if x < lower { packed = x / ratio }
        else if x <= upper { packed = lower / ratio + x - lower }
        else { packed = lower / ratio + upper - lower + (x - upper) / ratio }
        return Float(min(max(packed / scale, 0), 1))
    }

    /// Host sampling: where a packed wire UV reads the original render texture.
    public func renderCoordinate(forWire coordinate: Float) -> Float? {
        guard coordinate.isFinite, (0...1).contains(coordinate) else { return nil }
        let packed = Double(coordinate) * scale
        let left = lower / ratio, end = left + upper - lower
        let x: Double
        if packed < left { x = packed * ratio }
        else if packed <= end { x = lower + packed - left }
        else { x = upper + (packed - end) * ratio }
        return Float(min(max(x, 0), 1))
    }
}

extension CentreEdgeWarp {
    /// The wire size of an eye rendered at `render`: each axis times its
    /// packed length `L`, rounded to `alignment` pixels (at least one block).
    /// Density in the centre is then within half a block of full; the maps
    /// work in UVs, so they hold for whatever size is reported.
    public func wireSize(forRender render: PixelSize, alignment: Int) -> PixelSize? {
        guard let x = CentreEdgeAxisMapping(centreSize: centreSizeX, edgeRatio: edgeRatioX, centre: 0.5),
              let y = CentreEdgeAxisMapping(centreSize: centreSizeY, edgeRatio: edgeRatioY, centre: 0.5),
              alignment > 0, render.isNonZero else { return nil }
        func aligned(_ dimension: UInt16, _ scale: Float) -> UInt16 {
            let blocks = max(1, (Float(dimension) * scale / Float(alignment)).rounded())
            return UInt16(min(Float(dimension), blocks * Float(alignment)))
        }
        return PixelSize(width: aligned(render.width, x.wireScale), height: aligned(render.height, y.wireScale))
    }
}

extension CentreEdgeWarp {
    /// `centre` moved by less than a pixel so the full-density interval copies
    /// render pixels onto wire pixels: each render pixel centre there lands on
    /// a wire pixel centre, and the warp's single tap reads one texel instead
    /// of blending two. Anywhere else the copy is a half-pixel blend of fine
    /// detail, and a centre that follows the gaze changes that blend every
    /// frame (measured on pcvr-codec-bench, 2026-11-09: the warp alone lost
    /// 27-44 dB at the gaze from frame to frame, the codec more on top).
    /// When the wire eye isn't exactly `wireScale` times the render eye the
    /// density isn't 1, but the snapped centre still keeps the sampling
    /// pattern the same from frame to frame.
    public func pixelAlignedCentre(_ centre: NormalizedPoint, renderEye: PixelSize, wireEye: PixelSize) -> NormalizedPoint {
        NormalizedPoint(x: Self.aligned(centre.x, size: centreSizeX, ratio: edgeRatioX, render: Int(renderEye.width), wire: Int(wireEye.width)),
                        y: Self.aligned(centre.y, size: centreSizeY, ratio: edgeRatioY, render: Int(renderEye.height), wire: Int(wireEye.height)))
    }

    static func aligned(_ centre: Float, size: Float, ratio: Float, render: Int, wire: Int) -> Float {
        guard centre.isFinite, size > 0, size < 1, ratio > 1, render > 0, wire > 0 else { return centre }
        let s = Double(size), r = Double(ratio)
        let scale = s + (1 - s) / r
        let c = min(max(Double(centre), s / 2), 1 - s / 2)
        // In the interval a wire pixel coordinate is (x - a (1 - 1/r)) * wire / scale for
        // render UV x and interval start a: whole pixels when a (1 - 1/r) wire / scale is.
        let pixelsPerStart = (1 - 1 / r) * Double(wire) / scale
        let start = (c - s / 2) * pixelsPerStart
        // Round down, so the interval never moves past 1 - size.
        let snapped = start.rounded(.down) / pixelsPerStart
        return Float(min(max(snapped + s / 2, s / 2), 1 - s / 2))
    }
}

/// Per-eye 2D sampling map. UVs in both domains have a top-left origin.
public struct CentreEdgeMapping: Sendable, Hashable {
    public let x: CentreEdgeAxisMapping
    public let y: CentreEdgeAxisMapping

    public init?(warp: CentreEdgeWarp, centre: NormalizedPoint) {
        guard let x = CentreEdgeAxisMapping(centreSize: warp.centreSizeX, edgeRatio: warp.edgeRatioX, centre: centre.x),
              let y = CentreEdgeAxisMapping(centreSize: warp.centreSizeY, edgeRatio: warp.edgeRatioY, centre: centre.y)
        else { return nil }
        self.x = x
        self.y = y
    }

    public func wireUV(forRender uv: NormalizedPoint) -> NormalizedPoint? {
        guard let x = x.wireCoordinate(forRender: uv.x), let y = y.wireCoordinate(forRender: uv.y) else { return nil }
        return NormalizedPoint(x: x, y: y)
    }

    public func renderUV(forWire uv: NormalizedPoint) -> NormalizedPoint? {
        guard let x = x.renderCoordinate(forWire: uv.x), let y = y.renderCoordinate(forWire: uv.y) else { return nil }
        return NormalizedPoint(x: x, y: y)
    }
}

/// Refuses to pair a frame's centres with another format's warp parameters.
public struct StereoCentreEdgeMapping: Sendable, Hashable {
    public let left: CentreEdgeMapping
    public let right: CentreEdgeMapping

    public init?(parameters: FoveationParameters, frame: FoveationSideData) {
        guard parameters.epoch == frame.parameterEpoch, case .centreEdge(let warp) = parameters.warp,
              let left = CentreEdgeMapping(warp: warp, centre: frame.leftCentre),
              let right = CentreEdgeMapping(warp: warp, centre: frame.rightCentre) else { return nil }
        self.left = left
        self.right = right
    }
}
