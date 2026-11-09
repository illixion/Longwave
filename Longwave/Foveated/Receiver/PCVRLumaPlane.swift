#if FOVEATED_ENABLED
import Foundation

/// Packs a decoded 8-bit luma plane without a redundant zero-initialization
/// pass. The caller owns and locks the source for the duration of this copy.
nonisolated enum PCVRLumaPlane {
    static func copy(base: UnsafeRawPointer, width: Int, height: Int, stride: Int) -> [UInt8] {
        guard width > 0, height > 0, stride >= width else { return [] }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else { return [] }
        return Array(unsafeUninitializedCapacity: count) { destination, initializedCount in
            let out = destination.baseAddress!
            if stride == width {
                memcpy(out, base, count)
            } else {
                for y in 0..<height {
                    memcpy(out + y * width, base + y * stride, width)
                }
            }
            initializedCount = count
        }
    }
}
#endif
