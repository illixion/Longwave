import Foundation
import os

/// A fixed pool of preallocated PCM buffers that decouples the Core Audio
/// realtime thread from the network stack without allocating on it.
///
/// The IOProc must not call `malloc`: the allocator takes locks, and a
/// realtime thread blocked on one overruns its deadline — at which point Core
/// Audio drops the buffer outright. That is a hole punched in the stream at
/// the *source*, before any network is involved, so it shows up identically
/// on the TCP and UDP paths and correlates with system load rather than with
/// link quality. The previous path allocated twice per callback: once for the
/// int24 blob it built as a `Data`, and once for the `DispatchQueue.async`
/// closure context used to hand it off.
///
/// Instead the IOProc writes int24 samples straight into a slot it already
/// owns and signals a semaphore (`semaphore_signal` — wait-free, no
/// allocation). A dedicated consumer thread wakes, copies the slot out into a
/// `Data` — an ordinary allocation, on an ordinary thread — and hands it to
/// the network layer.
///
/// Single producer (the IOProc), single consumer. If every slot is in flight
/// the producer drops the buffer rather than blocking: that only happens when
/// the network side is more than `slotCount` buffers behind, and a dropped
/// 10 ms buffer beats stalling the audio device for everything on the Mac.
final class AudioFrameRing: @unchecked Sendable {

    private struct Cursor: Sendable {
        var write = 0
        var read = 0
        var filled = 0
        var dropped = 0
    }

    private let slotCount: Int
    private let slotCapacity: Int
    private let storage: UnsafeMutableRawPointer
    private let lengths: UnsafeMutablePointer<Int>
    private let cursor = OSAllocatedUnfairLock(initialState: Cursor())
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let running = OSAllocatedUnfairLock(initialState: false)

    /// Drop bookkeeping for the consumer thread's throttled reporting. The
    /// producer can't log: `Logger` allocates, and it runs on the realtime
    /// thread.
    private var reportedDrops = 0
    private var lastDropLogNanos: UInt64 = 0

    private let log = Logger(subsystem: "pro.longwave.companion", category: "AudioFrameRing")

    /// - Parameters:
    ///   - slotCount: buffers in flight before the producer starts dropping.
    ///   - slotCapacity: bytes per buffer; must fit the largest IOProc
    ///     payload, so size it from the device's pinned IO buffer size with
    ///     headroom.
    init(slotCount: Int = 16, slotCapacity: Int) {
        self.slotCount = max(2, slotCount)
        self.slotCapacity = max(1, slotCapacity)
        storage = .allocate(byteCount: self.slotCount * self.slotCapacity, alignment: 16)
        lengths = .allocate(capacity: self.slotCount)
        lengths.initialize(repeating: 0, count: self.slotCount)
    }

    deinit {
        stop()
        storage.deallocate()
        lengths.deinitialize(count: slotCount)
        lengths.deallocate()
    }

    /// Number of buffers the producer had to drop because the consumer was
    /// too far behind. Non-zero means the network side isn't keeping up.
    var droppedCount: Int { cursor.withLock { $0.dropped } }

    /// Starts the consumer thread. `handler` is invoked once per buffer, in
    /// order, off the realtime thread.
    func start(_ handler: @escaping @Sendable (Data) -> Void) {
        let wasRunning = running.withLock { state -> Bool in
            defer { state = true }
            return state
        }
        guard !wasRunning else { return }

        let thread = Thread { [weak self] in
            self?.consume(handler)
        }
        thread.name = "pro.longwave.companion.audio-ring"
        // QoS only — deliberately *not* `threadPriority`. Setting an explicit
        // thread priority on an `NSThread` resets its quality-of-service to
        // the default class, which would demote the one thread standing
        // between a captured buffer and the socket to ordinary work. When it
        // gets descheduled the ring backs up and then drops, which reaches
        // the listener as a hole in the audio.
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops the consumer thread and waits for it to exit, so the caller can
    /// safely drop the last reference.
    func stop() {
        let wasRunning = running.withLock { state -> Bool in
            defer { state = false }
            return state
        }
        guard wasRunning else { return }
        ready.signal()
        // Bounded: the consumer only ever blocks in `ready.wait()` or inside
        // one handler call, and neither can outlast this.
        _ = finished.wait(timeout: .now() + 2)
    }

    /// Producer side — safe to call from the Core Audio realtime thread.
    ///
    /// Claims a free slot, hands it to `fill`, and publishes whatever `fill`
    /// reports writing. Returns false when the ring is full (buffer dropped)
    /// or `fill` produced nothing.
    @discardableResult
    func write(_ fill: (UnsafeMutableRawBufferPointer) -> Int) -> Bool {
        let slot = cursor.withLock { c -> Int? in
            guard c.filled < slotCount else {
                c.dropped += 1
                return nil
            }
            return c.write
        }
        guard let slot else { return false }

        let written = fill(
            UnsafeMutableRawBufferPointer(start: storage + slot * slotCapacity, count: slotCapacity)
        )
        guard written > 0 else { return false }
        lengths[slot] = written

        cursor.withLock { c in
            c.write = (c.write + 1) % slotCount
            c.filled += 1
        }
        ready.signal()
        return true
    }

    // MARK: - Consumer

    private func consume(_ handler: @Sendable (Data) -> Void) {
        defer { finished.signal() }
        while true {
            ready.wait()
            guard running.withLock({ $0 }) else { return }

            let slot = cursor.withLock { c -> Int? in
                guard c.filled > 0 else { return nil }
                return c.read
            }
            guard let slot else { continue }

            // The allocation the realtime thread isn't allowed to make.
            handler(Data(bytes: storage + slot * slotCapacity, count: lengths[slot]))

            let dropped = cursor.withLock { c -> Int in
                c.read = (c.read + 1) % slotCount
                c.filled -= 1
                return c.dropped
            }
            reportDropsIfNeeded(dropped)
        }
    }

    /// Surfaces producer-side drops from the consumer thread, throttled.
    /// A drop here is audio that never reached the network at all, so it
    /// presents to the listener exactly like a network dropout and has to be
    /// distinguishable from one.
    private func reportDropsIfNeeded(_ dropped: Int) {
        guard dropped > reportedDrops else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastDropLogNanos > 5_000_000_000 else { return }
        lastDropLogNanos = now
        reportedDrops = dropped
        log.error("Audio frame ring overflowed — \(dropped) captured buffers dropped before the network saw them")
    }
}
