import Foundation
import CoreMedia
import VideoToolbox

/// What this device's video hardware can actually do, asked of VideoToolbox
/// rather than inferred from the model.
///
/// The desktop stream would rather be 4:2:2 than 4:2:0 — chroma subsampling is
/// what smears coloured text on a coloured background, which is most of what a
/// remote desktop is. But a chroma format the viewer cannot decode *in
/// hardware* is worse than the one it can: software HEVC decode of a Retina
/// desktop at 60 fps costs far more than the fringing it fixes. So the viewer
/// measures itself and tells the host in its hello, and a host that hears
/// nothing sends 4:2:0.
///
/// There is no API that answers "can you hardware-decode HEVC Main 4:2:2 10?" —
/// `VTIsHardwareDecodeSupported` only answers per codec, and says yes for HEVC
/// on anything that decodes plain 4:2:0. So the probe does the only decisive
/// thing available: it builds a real Main42210 format description and asks
/// VideoToolbox for a decompression session that *requires* hardware. If no
/// hardware decoder claims it, the session is refused and the answer is no.
nonisolated enum MacNativeVideoCapability {
    /// Whether this device can decode HEVC Main 4:2:2 10-bit in hardware.
    /// Probed once and cached — creating a decompression session is not free,
    /// and the answer cannot change while the process is alive.
    static var decodesHEVC422InHardware: Bool { probed }

    private static let probed: Bool = probeDetail().requiringHardware == noErr

    /// The probe, broken into the parts a failure could come from. A `false`
    /// capability is only trustworthy if the format description built — a
    /// probe that cannot even describe the stream would refuse 4:2:2 on every
    /// device, silently and forever, and that is indistinguishable from "no
    /// hardware" unless you can see these apart.
    static func probeDetail() -> (
        formatBuilt: Bool,
        requiringHardware: OSStatus,
        withoutRequiringHardware: OSStatus,
        codecReportsHardware: Bool
    ) {
        let codecHardware = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        guard let format = makeProbeFormatDescription() else {
            return (false, -1, -1, codecHardware)
        }
        func create(requireHardware: Bool) -> OSStatus {
            let specification: [CFString: Any] = [
                kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: requireHardware
            ]
            var session: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: format,
                decoderSpecification: specification as CFDictionary,
                imageBufferAttributes: nil,
                outputCallback: nil,
                decompressionSessionOut: &session
            )
            if let session {
                VTDecompressionSessionInvalidate(session)
            }
            return status
        }
        return (true, create(requireHardware: true), create(requireHardware: false), codecHardware)
    }

    // A real VPS/SPS/PPS triplet for HEVC Main 4:2:2 10 (profile_idc 4,
    // chroma_format_idc 2, 10-bit) at 3840×2160 — emitted by VideoToolbox's
    // own hardware encoder, so it is exactly the shape of stream a Mac host
    // would send. 4K rather than something small on purpose: a decoder that
    // takes the profile only at a low level must not pass a probe for a stream
    // it would then choke on.
    private static let probeVPS: [UInt8] = [
        0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00,
        0xbd, 0x08, 0x00, 0x00, 0x03, 0x00, 0x00, 0x99, 0x15, 0xc0, 0x90
    ]
    private static let probeSPS: [UInt8] = [
        0x42, 0x01, 0x01, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0xbd, 0x08, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x99, 0xb0, 0x01, 0xe0, 0x20, 0x02, 0x1c, 0x4d,
        0x88, 0x15, 0xee, 0x45, 0x95, 0x10
    ]
    private static let probePPS: [UInt8] = [
        0x44, 0x01, 0xc0, 0x2c, 0xbd, 0x14, 0xd9
    ]

    private static func makeProbeFormatDescription() -> CMVideoFormatDescription? {
        let parameterSets = [probeVPS, probeSPS, probePPS]
        var format: CMVideoFormatDescription?
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []

        // Nested `withUnsafeBufferPointer` calls, so every parameter set stays
        // pinned while CoreMedia reads all three (the same shape
        // `MacNativeVideoRenderer` uses).
        func pin(_ index: Int) -> OSStatus {
            guard index < parameterSets.count else {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &format
                )
            }
            return parameterSets[index].withUnsafeBufferPointer { buffer in
                pointers.append(buffer.baseAddress!)
                sizes.append(buffer.count)
                return pin(index + 1)
            }
        }
        return pin(0) == noErr ? format : nil
    }
}
