import Foundation
import CoreMedia
import RAVECamera

/// The RTP-facing shape of `RAVEH264Encoder` (RAVESDK's `RAVECamera`): the
/// session tuning — realtime, no B-frames, 1 s GOP — lives in the package,
/// shared with Raven's screen-share extension. What this adds is what RTP
/// wants and a WebCodecs decoder does not: each access unit split into raw
/// NAL units (RFC 6184 payloads them one at a time), with SPS/PPS prepended
/// in-band ahead of every IDR so readers that join mid-stream, and publishers
/// coming back from a reconnect, decode without an out-of-band SDP refresh.
///
/// Runs entirely on the capture callback thread and VideoToolbox's output
/// thread, like the encoder it wraps.
final class BroadcastVideoEncoder: @unchecked Sendable {

    /// Fired once when SPS/PPS first become available (and again if they
    /// change) — gates RTSP ANNOUNCE, which embeds them in the SDP.
    nonisolated(unsafe) var onParameterSets: ((_ sps: Data, _ pps: Data) -> Void)?
    /// One access unit: raw NALs (SPS/PPS prepended on keyframes), PTS,
    /// keyframe flag. Fires on the VideoToolbox output thread.
    nonisolated(unsafe) var onEncodedFrame: ((_ nalUnits: [Data], _ pts: CMTime, _ keyframe: Bool) -> Void)?
    nonisolated(unsafe) var onError: ((String) -> Void)?

    private let encoder: RAVEH264Encoder
    private nonisolated(unsafe) var parameterSets: RAVEH264Encoder.ParameterSets?

    nonisolated init(bitrate: Int, frameRate: Int = 30) {
        encoder = RAVEH264Encoder(configuration: .init(bitrate: bitrate, frameRate: frameRate))
        encoder.onParameterSets = { [weak self] sets in
            guard let self else { return }
            self.parameterSets = sets
            self.onParameterSets?(sets.sps, sets.pps)
        }
        encoder.onAccessUnit = { [weak self] unit in
            guard let self else { return }
            var nalUnits = RAVEAVCC.nalUnits(fromAVCC: unit.data,
                                             nalUnitLengthSize: self.parameterSets?.nalUnitLengthSize ?? 4)
            guard !nalUnits.isEmpty else { return }
            if unit.isKeyframe, let sets = self.parameterSets {
                nalUnits.insert(contentsOf: [sets.sps, sets.pps], at: 0)
            }
            self.onEncodedFrame?(nalUnits, unit.presentationTime, unit.isKeyframe)
        }
        encoder.onError = { [weak self] message in
            self?.onError?(message)
        }
    }

    nonisolated func encode(_ sampleBuffer: CMSampleBuffer) {
        encoder.encode(sampleBuffer)
    }

    nonisolated func invalidate() {
        encoder.invalidate()
        parameterSets = nil
    }
}
