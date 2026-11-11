// The receive side of a client's microphone (capability `microphone`): audio
// shards in from the network thread, samples out on an audio device's render
// thread, with a small jitter cushion between them.
//
// The rules are the macOS Companion's `MicrophoneRelay`/`JitterBuffer`, which
// carry the same headset microphone into BlackHole: a cushion that starts at
// 40 ms, grows by 20 ms on each underrun up to 160 ms, and is trimmed back
// whenever it holds more than 60 ms over its target, because every queued
// sample is latency in someone's voice chat. A lost packet of up to 100 ms is
// filled with silence so what follows keeps its timing; a longer gap is a
// stall and the cushion primes again. Late or repeated packets are dropped.
//
// Mono. Lock-guarded and allocation-free on the render side, so a render
// thread that cannot await anything can pull from it.

import Foundation

public final class MicrophonePlayout: @unchecked Sendable {
    public struct Health: Equatable, Sendable {
        public var targetSeconds: Double
        public var bufferedSeconds: Double
        public var underruns: Int
        public var trimmedFrames: Int
        public var lostFrames: Int
        public var latePackets: Int
    }

    static let baseTarget = 0.04
    static let maxTarget = 0.16
    static let trimSlack = 0.06
    static let maxGapFill = 0.1

    public let sampleRate: Int
    private let lock = NSLock()
    private var storage: [Float]
    private var readIndex = 0
    private var count = 0
    private var targetSeconds = MicrophonePlayout.baseTarget
    private var priming = true
    private var expected: UInt64?
    private var underruns = 0
    private var trimmedFrames = 0
    private var lostFrames = 0
    private var latePackets = 0

    public init(sampleRate: Int) {
        self.sampleRate = max(8_000, sampleRate)
        storage = [Float](repeating: 0, count: self.sampleRate)   // one second
    }

    /// Network side: one packet's samples, starting at the sender's sample
    /// index `firstSample`. `discontinuity`: the sender restarted its count.
    public func receive(firstSample: UInt64, discontinuity: Bool, samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if let expected, !discontinuity {
            if firstSample < expected {
                latePackets += 1
                return
            }
            let gap = firstSample - expected
            if gap > 0 {
                lostFrames += Int(min(gap, UInt64(Int.max)))
                if gap <= UInt64(Double(sampleRate) * Self.maxGapFill) {
                    for _ in 0..<Int(gap) { push(0) }
                }
            }
        }
        expected = firstSample + UInt64(samples.count)
        for sample in samples { push(sample) }
        trimIfNeeded()
    }

    /// Render side: fills `destination` (mono), silence where nothing is ready.
    public func render(into destination: UnsafeMutableBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        let wanted = destination.count
        if priming {
            guard count >= Int(targetSeconds * Double(sampleRate)) else {
                for i in 0..<wanted { destination[i] = 0 }
                return
            }
            priming = false
        }
        let available = min(count, wanted)
        for i in 0..<available {
            destination[i] = storage[(readIndex + i) % storage.count]
        }
        readIndex = (readIndex + available) % storage.count
        count -= available
        if available < wanted {
            for i in available..<wanted { destination[i] = 0 }
            underruns += 1
            priming = true
            targetSeconds = min(Self.maxTarget, targetSeconds + 0.02)
        }
    }

    /// The counters since the last call, and the cushion now.
    public func takeHealth() -> Health {
        lock.lock()
        defer { lock.unlock() }
        let health = Health(targetSeconds: targetSeconds, bufferedSeconds: Double(count) / Double(sampleRate),
                            underruns: underruns, trimmedFrames: trimmedFrames, lostFrames: lostFrames,
                            latePackets: latePackets)
        underruns = 0
        trimmedFrames = 0
        lostFrames = 0
        latePackets = 0
        return health
    }

    // Under the lock.
    private func push(_ sample: Float) {
        if count == storage.count {
            readIndex = (readIndex + 1) % storage.count
            count -= 1
        }
        storage[(readIndex + count) % storage.count] = sample
        count += 1
    }

    // Under the lock.
    private func trimIfNeeded() {
        let limit = Int((targetSeconds + Self.trimSlack) * Double(sampleRate))
        guard !priming, count > limit else { return }
        let drop = count - Int(targetSeconds * Double(sampleRate))
        readIndex = (readIndex + drop) % storage.count
        count -= drop
        trimmedFrames += drop
    }
}
