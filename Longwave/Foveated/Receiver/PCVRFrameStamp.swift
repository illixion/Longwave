#if FOVEATED_ENABLED
import CoreVideo
import Foundation
import os
import StreamWire

/// The PCVR test scene's stamp (`frame-source-spike scene`, layout in
/// LongwaveStream's spike_test_scene.cpp): in each eye's render image, a row
/// of 18 blocks near the top and another near the bottom, block 0 white,
/// block 17 black, blocks 1-16 the low 16 bits of the pose sequence the frame
/// was rendered from (most significant first, white for 1).
///
/// Read from a decoded picture it tells three faults apart that all look like
/// "the picture jumps for a frame": a picture torn top to bottom (rows
/// differ), eyes from different frames (eyes differ), and a picture paired
/// with another frame's metadata (both agree, but not with `renderPose`).
nonisolated enum PCVRFrameStamp {
    static let blocks = 18
    static let firstU: Float = 0.30
    static let pitch: Float = 0.022
    static let blockWidth: Float = 0.020
    /// Row centres, render V within the eye: top and bottom.
    static let rows: [Float] = [0.0275, 0.9725]

    /// Block `block`'s centre on `row`, as a render UV within the eye.
    static func centre(block: Int, row: Int) -> NormalizedPoint {
        NormalizedPoint(x: firstU + pitch * Float(block) + blockWidth / 2, y: rows[row])
    }

    /// Per eye, per row: the stamped value, or nil where the framing blocks
    /// aren't there (no stamp, or unreadable).
    typealias Reading = [[UInt16?]]

    /// Reads a decoded BGRA picture (both eyes side by side at wire size).
    static func read(_ buffer: CVPixelBuffer, foveation: PCVRFoveation?) -> Reading? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        return read(bytes: UnsafeRawPointer(base), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), foveation: foveation)
    }

    /// The reading from BGRA bytes: each block's centre, mapped through the
    /// eye's foveation (render UV to wire UV) when the frame was warped.
    static func read(bytes: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int,
                     foveation: PCVRFoveation?) -> Reading {
        let eyeWidth = width / 2
        func green(_ x: Int, _ y: Int) -> Int {
            let cx = min(max(x, 0), width - 1), cy = min(max(y, 0), height - 1)
            return Int(bytes.load(fromByteOffset: cy * bytesPerRow + cx * 4 + 1, as: UInt8.self))
        }
        return (0..<2).map { eye in
            let mapping = foveation.map { eye == 0 ? $0.mapping.left : $0.mapping.right }
            return (0..<rows.count).map { row in
                var bits: [Bool] = []
                for block in 0..<blocks {
                    let render = centre(block: block, row: row)
                    var wire = render
                    if let mapping {
                        guard let mapped = mapping.wireUV(forRender: render) else { return nil }
                        wire = mapped
                    }
                    let x = eye * eyeWidth + Int(wire.x * Float(eyeWidth)), y = Int(wire.y * Float(height))
                    // Five taps: the centre and two pixels each way, against codec ringing.
                    let sum = green(x, y) + green(x - 2, y) + green(x + 2, y) + green(x, y - 2) + green(x, y + 2)
                    bits.append(sum > 5 * 128)
                }
                guard bits[0], !bits[blocks - 1] else { return nil }
                return bits[1...16].reduce(UInt16(0)) { $0 << 1 | ($1 ? 1 : 0) }
            }
        }
    }
}

/// Compares decoded frames' stamps with their metadata, when switched on.
/// Thread-safe: the decoder checks on its own thread, a presenter reads the counts.
nonisolated final class PCVRStampChecker: @unchecked Sendable {
    struct Counts: Sendable, Equatable {
        var checked = 0
        /// All four rows agree with the frame's render pose.
        var matching = 0
        /// No stamp found in some row (no test scene, or the picture is damaged there).
        var unreadable = 0
        /// An eye's top and bottom rows differ: the picture is torn.
        var torn = 0
        /// The eyes carry different values: they come from different frames.
        var eyesDiffer = 0
        /// The picture is consistent but was rendered from another pose than its metadata says.
        var poseMismatch = 0
        /// The latest fault, for reading next to the counts.
        var lastProblem: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: (enabled: false, counts: Counts()))

    var isEnabled: Bool {
        get { state.withLock { $0.enabled } }
        set { state.withLock { $0.enabled = newValue } }
    }

    var counts: Counts { state.withLock { $0.counts } }

    func reset() { state.withLock { $0.counts = Counts() } }

    func check(_ buffer: CVPixelBuffer, foveation: PCVRFoveation?, frameNumber: UInt32, poseSequence: UInt32) {
        guard isEnabled, let reading = PCVRFrameStamp.read(buffer, foveation: foveation) else { return }
        record(reading, frameNumber: frameNumber, poseSequence: poseSequence)
    }

    /// Classifies one reading (separate from `check` so it can be tested without a picture).
    func record(_ reading: PCVRFrameStamp.Reading, frameNumber: UInt32, poseSequence: UInt32) {
        let expected = UInt16(truncatingIfNeeded: poseSequence)
        state.withLock { s in
            s.counts.checked += 1
            let values = reading.flatMap { $0 }
            func describe() -> String {
                let text = reading.map { $0.map { $0.map(String.init) ?? "?" }.joined(separator: "/") }.joined(separator: " | ")
                return "frame \(frameNumber): stamps (left top/bottom | right top/bottom) \(text), pose \(expected)"
            }
            if values.contains(where: { $0 == nil }) {
                s.counts.unreadable += 1
                s.counts.lastProblem = "unreadable, " + describe()
            } else if reading.contains(where: { Set($0).count > 1 }) {
                s.counts.torn += 1
                s.counts.lastProblem = "torn, " + describe()
            } else if Set(values).count > 1 {
                s.counts.eyesDiffer += 1
                s.counts.lastProblem = "eyes differ, " + describe()
            } else if values.first! != expected {
                s.counts.poseMismatch += 1
                s.counts.lastProblem = "pose mismatch, " + describe()
            } else {
                s.counts.matching += 1
            }
        }
    }
}
#endif
