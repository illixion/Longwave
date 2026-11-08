//  PCVRLinkProbe.swift
//
//  What the Wi-Fi link did to the v3 stream, measured where it lands: every
//  datagram's arrival, every colour shard's age (its arrival on the host's
//  clock minus the frame's capture time) and every RTT sample, kept for the
//  last `retention` seconds and summarised on request.
//
//  Why per datagram: the headset's radio stalls in stretches (Longwave's audio
//  receiver measured recurring ~165 ms delivery gaps with the backlog arriving
//  as one burst, AudioStreamManager's `stallMargin` notes), and an average
//  RTT or a frame-rate counter hides both the stall and the burst. A frame's
//  last-shard age minus the session's lowest is the queueing a frame picked
//  up on the way: encode and pacing are in the lowest, so what is above it is
//  the link (or the host falling behind, which `spread` tells apart: a burst
//  after a stall arrives with a small spread and a large age).

#if FOVEATED_ENABLED
import Foundation

nonisolated struct PCVRLinkProbe: Sendable {
    /// Seconds of history kept.
    static let retention: Double = 20
    /// An inter-datagram gap at least this long is recorded as a stall. At 60
    /// frames a second the paced sender is idle up to ~16 ms between frames,
    /// so shorter gaps are the stream's own rhythm.
    static let stallGap: UInt64 = 30_000_000
    /// Gaps at least this long are kept, for the histogram.
    static let recordedGap: UInt64 = 8_000_000

    struct FrameRecord: Sendable {
        var time: UInt64
        var frame: UInt32
        var firstAge: Int64
        var lastAge: Int64
        var shards: Int
        var key: Bool
    }

    private(set) var datagrams = 0
    private var lastDatagram: UInt64?
    /// (arrival of the datagram after the gap, gap), gaps >= `recordedGap`.
    private var gaps: [(time: UInt64, gap: UInt64)] = []
    /// Datagram counts per whole second of local time.
    private var perSecond: [(second: UInt64, count: Int)] = []
    private var frames: [FrameRecord] = []
    private var rtts: [(time: UInt64, rtt: UInt64)] = []
    private var lastRTTCount = 0
    private(set) var nacks = 0
    private(set) var recoveries = 0
    private(set) var keyFrameRequests = 0

    mutating func datagram(at now: UInt64) {
        datagrams += 1
        if let last = lastDatagram, now > last, now - last >= Self.recordedGap {
            gaps.append((now, now - last))
        }
        lastDatagram = now
        let second = now / 1_000_000_000
        if perSecond.last?.second == second {
            perSecond[perSecond.count - 1].count += 1
        } else {
            perSecond.append((second, 1))
        }
        if datagrams % 512 == 0 { trim(now: now) }
    }

    /// A colour shard arrived at local `now`, `remoteNow` on the host's clock.
    mutating func shard(frame: UInt32, captureTime: UInt64, key: Bool, now: UInt64, remoteNow: UInt64?) {
        guard let remoteNow else { return }
        let age = Int64(bitPattern: remoteNow &- captureTime)
        // Frames arrive nearly in order; look back a few.
        for index in frames.indices.reversed().prefix(8) where frames[index].frame == frame {
            frames[index].lastAge = age
            frames[index].shards += 1
            frames[index].key = frames[index].key || key
            return
        }
        frames.append(FrameRecord(time: now, frame: frame, firstAge: age, lastAge: age, shards: 1, key: key))
    }

    mutating func rtt(latest: UInt64?, sampleCount: Int, now: UInt64) {
        guard sampleCount != lastRTTCount, let latest else { return }
        lastRTTCount = sampleCount
        rtts.append((now, latest))
    }

    mutating func noteNack() { nacks += 1 }
    mutating func noteRecovery() { recoveries += 1 }
    mutating func noteKeyFrameRequest() { keyFrameRequests += 1 }

    mutating func reset() { self = PCVRLinkProbe() }

    private mutating func trim(now: UInt64) {
        let horizon = now &- UInt64(Self.retention * 1e9)
        guard now > UInt64(Self.retention * 1e9) else { return }
        gaps.removeAll { $0.time < horizon }
        frames.removeAll { $0.time < horizon }
        rtts.removeAll { $0.time < horizon }
        perSecond.removeAll { $0.second < horizon / 1_000_000_000 }
    }

    // MARK: Report

    static func percentile(_ values: [Double], _ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(q * Double(sorted.count - 1) + 0.5))]
    }

    private static func spread(_ values: [Double]) -> [String: Any] {
        ["p50": percentile(values, 0.5) as Any, "p95": percentile(values, 0.95) as Any,
         "p99": percentile(values, 0.99) as Any, "max": values.max() as Any, "min": values.min() as Any]
    }

    /// The last `seconds` (at most `retention`) up to `now`; `rows` adds one
    /// row per frame.
    func report(seconds: Double, now: UInt64, rows: Bool = false) -> [String: Any] {
        let window = UInt64(min(max(seconds, 0.1), Self.retention) * 1e9)
        let from = now > window ? now - window : 0
        let ms = { (ns: UInt64) in Double(ns) / 1e6 }
        let recentGaps = gaps.filter { $0.time >= from }
        let stalls = recentGaps.filter { $0.gap >= Self.stallGap }
        let recentFrames = frames.filter { $0.time >= from }
        let floor = recentFrames.map(\.lastAge).min() ?? 0
        let lastAges = recentFrames.map { Double($0.lastAge) / 1e6 }
        let excess = recentFrames.map { Double($0.lastAge - floor) / 1e6 }
        let spreads = recentFrames.map { Double($0.lastAge - $0.firstAge) / 1e6 }
        let counts = perSecond.filter { $0.second * 1_000_000_000 >= from }.map(\.count)
        let late = recentFrames.filter { $0.lastAge - floor > 20_000_000 }
        // The frames that came in after a stall: their age above the floor.
        var afterStalls: [Double] = []
        for stall in stalls {
            if let frame = recentFrames.first(where: { $0.time >= stall.time }) {
                afterStalls.append(Double(frame.lastAge - floor) / 1e6)
            }
        }
        var body: [String: Any] = [
            "seconds": Double(window) / 1e9,
            "datagrams": datagrams,
            "datagramsPerSecond": counts.isEmpty ? 0 : Double(counts.reduce(0, +)) / Double(counts.count),
            "gapsMs": [
                "over8": recentGaps.count,
                "over20": recentGaps.filter { $0.gap >= 20_000_000 }.count,
                "over30": stalls.count,
                "over50": recentGaps.filter { $0.gap >= 50_000_000 }.count,
                "over100": recentGaps.filter { $0.gap >= 100_000_000 }.count,
                "max": recentGaps.map { ms($0.gap) }.max() as Any,
            ] as [String: Any],
            "stalls": stalls.suffix(40).map { ["atS": Double($0.time - from) / 1e9, "ms": ms($0.gap)] },
            "frameAgeMs": Self.spread(lastAges),
            "frameExcessMs": Self.spread(excess),
            "frameSpreadMs": Self.spread(spreads),
            "frames": recentFrames.count,
            "framesLateOver20ms": late.count,
            "excessAfterStallMs": Self.spread(afterStalls),
            "rttMs": Self.spread(rtts.filter { $0.time >= from }.map { ms($0.rtt) }),
            "nacks": nacks,
            "recoveries": recoveries,
            "keyFrameRequests": keyFrameRequests,
        ]
        if rows {
            body["columns"] = ["t", "frame", "firstAgeMs", "lastAgeMs", "shards", "key"]
            body["rows"] = recentFrames.map { f -> [Any] in
                [Double(f.time - from) / 1e9, Int(f.frame), Double(f.firstAge) / 1e6, Double(f.lastAge) / 1e6, f.shards, f.key ? 1 : 0]
            }
        }
        return body
    }
}
#endif
