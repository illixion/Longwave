// A stand-in for NVENC's CBR rate control, for the parts of the bench that
// don't need pictures (rate control, recovery, refresh changes): each frame
// gets its share of the bitrate, a key frame as much as the VBV holds, and the
// QP is whatever that share buys for how much the picture changed.
import Foundation

public final class ModelEncoder: BenchEncoder {
    /// Bits a frame needs at QP 22, still and while the head turns at 100°/s.
    public var stillBits = 200_000.0
    public var movingBits = 2_400_000.0
    public var keyBits = 6_000_000.0
    /// The VBV in frames (`--vbv-frames`).
    public var vbvFrames = 4.0
    /// Rebuild with a key frame when the stream rate changes (the host today),
    /// or reconfigure the rate in place.
    public var keyOnRateChange = true
    /// Turn rate in degrees per second at a run time.
    public var turnRate: (Double) -> Double = { _ in 0 }
    public private(set) var configuredHz: Double?
    public private(set) var rebuilds = 0

    public init() {}

    public func encode(_ request: FrameRequest) throws -> EncodedFrame {
        var key = request.forceKey
        if configuredHz != request.hz {
            if configuredHz != nil {
                rebuilds += 1
                if keyOnRateChange { key = true }
            }
            configuredHz = request.hz
        }
        let share = Double(request.bitrate) / request.hz
        let rate = turnRate(request.time)
        let needed = key ? keyBits : stillBits + (movingBits - stillBits) * min(rate / 100, 2)
        // CBR spends its share; a key frame may take the whole VBV.
        let spent = min(needed, share * (key ? vbvFrames : 1.2))
        let qp = Int(max(10, min(51, 22 + 6 * log2(needed / max(spent, 1)))).rounded())
        return EncodedFrame(size: Int(spent / 8), isKey: key, encodeSeconds: 0.004 + spent / 8 / 400_000_000, qp: qp)
    }
}
