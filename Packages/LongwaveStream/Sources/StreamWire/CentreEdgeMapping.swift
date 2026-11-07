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
