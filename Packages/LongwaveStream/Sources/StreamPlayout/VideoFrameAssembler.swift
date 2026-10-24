// StreamPlayout: the receive side of v3 media (NATIVE_V3_PROTOCOL.md sections
// 4.2, 5 and 6.3). This file is the frame assembler: shards in, whole frames
// out in decode order, with FEC recovery, a reorder window, NACK candidates and
// the reference check that tells a decoder whether a frame's chain is intact.
// Foundation-free, like StreamWire; time is the receiver's monotonic clock in
// nanoseconds, passed in, so tests and the simulator drive it.

import StreamFEC
import StreamWire

/// A frame whose every block arrived or was rebuilt.
public struct AssembledVideoFrame: Sendable {
    public var streamID: UInt32
    public var frameNumber: UInt32
    public var captureTime: UInt64
    /// The shard flags without `.lastBlock`, which is per block.
    public var flags: VideoShardFlags
    public var referenceDistance: UInt16
    public var payload: FramePayload.Decoded
    /// Whether every frame this one depends on, back to an intra frame, was
    /// delivered intact. A decoder in game mode drops a frame without it (and
    /// asks for invalidation); desktop mode decodes through and smears briefly.
    public var referenceChainIntact: Bool
    /// Data shards FEC rebuilt for this frame (0 on a clean link).
    public var recoveredShards: Int
    /// Receiver time of the frame's first and completing shard.
    public var firstArrival: UInt64
    public var completedAt: UInt64

    public var referenceFrame: UInt32? {
        referenceDistance == 0 ? nil : frameNumber &- UInt32(referenceDistance)
    }
}

/// What the assembler hands the decoder, strictly in frame-number order.
public enum VideoAssemblyEvent: Sendable {
    case frame(AssembledVideoFrame)
    /// `count` frames from `first` on will never arrive: given up after the
    /// timeout, skipped by a jump far ahead, or (count 1) unusable because the
    /// reassembled payload didn't parse.
    case lost(first: UInt32, count: UInt32, reason: LossReason)

    public enum LossReason: Sendable, Equatable {
        case timedOut
        case skippedAhead
        case malformedPayload
    }
}

/// Shards worth asking the host for again (section 4.2, NACK). Built by
/// `missingShards(now:)`; encoding it and pacing re-requests is the
/// transport's job.
public struct MissingShards: Sendable, Equatable {
    public enum Scope: Sendable, Equatable {
        /// No shard of the frame arrived, so its layout is unknown.
        case wholeFrame
        /// No shard of this block arrived.
        case wholeBlock(UInt8)
        /// The block's layout is known: `needed` more shards of any kind
        /// complete it. `dataIndices` are the missing data shards, the
        /// cheapest to resend (no parity to compute).
        case shards(block: UInt8, needed: Int, dataIndices: [UInt8])
    }

    public var frameNumber: UInt32
    public var scope: Scope

    public init(frameNumber: UInt32, scope: Scope) {
        self.frameNumber = frameNumber
        self.scope = scope
    }
}

/// Counters for the stats overlay and tests.
public struct VideoAssemblyStatistics: Sendable, Equatable {
    public var shardsAccepted = 0
    public var duplicateShards = 0
    /// For a frame already delivered or given up. On a clean link this is
    /// mostly parity, which arrives after its frame completed on the data alone.
    public var lateShards = 0
    /// Disagreed with earlier shards of the same frame or block.
    public var inconsistentShards = 0
    /// Refused because buffering them would pass `maxBufferedBytes`.
    public var shardsDroppedForMemory = 0
    public var recoveredShards = 0
    public var framesDelivered = 0
    public var framesLost = 0
}

/// Reassembles one video stream.
///
/// Not thread-safe: one owner (the stream's receive loop) calls it.
public struct VideoFrameAssembler: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// How long a frame may lack shards before they count as missing rather
        /// than reordered (section 4.2: max(2 ms, a quarter frame interval)).
        public var reorderWindow: UInt64
        /// How long after its first shard (or, for a frame that never showed,
        /// after a later frame's first shard) a frame is given up.
        public var giveUpAfter: UInt64
        /// A shard this many frames past the next frame to deliver makes the
        /// assembler give up everything before it at once instead of waiting.
        public var maxFramesAhead: UInt32
        /// Ceiling on bytes held in unfinished frames.
        public var maxBufferedBytes: Int
        /// Frames remembered for the reference check. Long-term references are
        /// kept apart, so they outlive this window.
        public var referenceHistory: Int

        public init(reorderWindow: UInt64 = 2_000_000, giveUpAfter: UInt64 = 100_000_000,
                    maxFramesAhead: UInt32 = 600, maxBufferedBytes: Int = 64 << 20, referenceHistory: Int = 1024) {
            self.reorderWindow = reorderWindow
            self.giveUpAfter = giveUpAfter
            self.maxFramesAhead = maxFramesAhead
            self.maxBufferedBytes = maxBufferedBytes
            self.referenceHistory = referenceHistory
        }
    }

    public let streamID: UInt32
    public var configuration: Configuration
    public private(set) var statistics = VideoAssemblyStatistics()
    /// The next frame to deliver; nil until the first shard arrives.
    public private(set) var nextFrame: UInt32?
    public private(set) var bufferedBytes = 0

    private var pending: [UInt32: PendingFrame] = [:]
    private var chain: ReferenceChain

    public init(streamID: UInt32, configuration: Configuration = Configuration()) {
        self.streamID = streamID
        self.configuration = configuration
        chain = ReferenceChain(capacity: configuration.referenceHistory)
    }

    /// Frames started and not yet delivered or given up.
    public var pendingFrameCount: Int { pending.count }

    // MARK: Receiving

    /// Takes one shard (a slice of a decrypted datagram; it is copied) and
    /// returns whatever can now be delivered, in order.
    public mutating func receive(_ header: VideoShardHeader, data: ArraySlice<UInt8>, now: UInt64) -> [VideoAssemblyEvent] {
        guard header.streamID == streamID, !data.isEmpty else {
            statistics.inconsistentShards += 1
            return []
        }
        var events: [VideoAssemblyEvent] = []
        let number = header.frameNumber
        if let next = nextFrame {
            if number != next, !SerialNumber.isNewer(number, than: next) {
                statistics.lateShards += 1
                return []
            }
            if number &- next > configuration.maxFramesAhead {
                // Too far ahead to wait for the gap: give it up in one event.
                let newNext = number &- configuration.maxFramesAhead
                giveUp(upTo: newNext, reason: .skippedAhead, into: &events)
            }
        } else {
            nextFrame = number
        }

        var frame = pending[number] ?? PendingFrame(header: header, firstArrival: now)
        switch frame.add(header, data: data, now: now, budget: configuration.maxBufferedBytes - bufferedBytes) {
        case .accepted(let addedBytes, let recovered):
            bufferedBytes += addedBytes
            statistics.shardsAccepted += 1
            statistics.recoveredShards += recovered
        case .duplicate:
            statistics.duplicateShards += 1
        case .inconsistent:
            statistics.inconsistentShards += 1
        case .overBudget:
            statistics.shardsDroppedForMemory += 1
        }
        pending[number] = frame
        drain(now: now, into: &events)
        return events
    }

    /// Gives up frames whose time ran out. Call on a timer (each frame
    /// interval is plenty) as well as after receiving.
    public mutating func poll(now: UInt64) -> [VideoAssemblyEvent] {
        var events: [VideoAssemblyEvent] = []
        drain(now: now, into: &events)
        return events
    }

    /// Forgets everything: a new stream epoch, a new format with an IDR, or a
    /// subscription restart. The next shard starts the count again.
    public mutating func reset() {
        pending.removeAll()
        bufferedBytes = 0
        nextFrame = nil
        chain = ReferenceChain(capacity: configuration.referenceHistory)
    }

    // MARK: Missing shards

    /// What is still missing from frames older than the reorder window and not
    /// yet given up, oldest first. Gaps (frame numbers with no shard at all)
    /// between the next frame and the newest one seen are included.
    public func missingShards(now: UInt64) -> [MissingShards] {
        guard let next = nextFrame, let newest = newestPendingFrame else { return [] }
        var result: [MissingShards] = []
        var number = next
        while true {
            if let frame = pending[number] {
                if frame.isComplete == false, now &- frame.firstArrival >= configuration.reorderWindow {
                    result += frame.missing(frameNumber: number)
                }
            } else if let known = firstArrivalAfter(number), now &- known >= configuration.reorderWindow {
                result.append(MissingShards(frameNumber: number, scope: .wholeFrame))
            }
            if number == newest { break }
            number &+= 1
        }
        return result
    }

    // MARK: Delivery

    private var newestPendingFrame: UInt32? {
        pending.keys.max { SerialNumber.isNewer($1, than: $0) }
    }

    private func oldestPendingFrame(after number: UInt32) -> UInt32? {
        pending.keys.lazy.filter { SerialNumber.isNewer($0, than: number) }.min { SerialNumber.isNewer($1, than: $0) }
    }

    /// When we first knew `number` should exist even though none of its shards
    /// came: the earliest first arrival among frames after it.
    private func firstArrivalAfter(_ number: UInt32) -> UInt64? {
        pending.lazy.filter { SerialNumber.isNewer($0.key, than: number) }.map(\.value.firstArrival).min()
    }

    private mutating func drain(now: UInt64, into events: inout [VideoAssemblyEvent]) {
        while let next = nextFrame {
            if let frame = pending[next] {
                if frame.isComplete {
                    pending[next] = nil
                    bufferedBytes -= frame.bufferedBytes
                    deliver(frame, number: next, now: now, into: &events)
                    nextFrame = next &+ 1
                    continue
                }
                guard now &- frame.firstArrival >= configuration.giveUpAfter else { return }
            } else {
                // A run of frames none of whose shards came: give up the whole
                // run, up to the oldest frame that did, in one event.
                guard let known = firstArrivalAfter(next), now &- known >= configuration.giveUpAfter,
                      let end = oldestPendingFrame(after: next) else { return }
                giveUp(upTo: end, reason: .timedOut, into: &events)
                continue
            }
            giveUp(upTo: next &+ 1, reason: .timedOut, into: &events)
        }
    }

    private mutating func deliver(_ frame: PendingFrame, number: UInt32, now: UInt64,
                                  into events: inout [VideoAssemblyEvent]) {
        let decoded: FramePayload.Decoded
        do {
            decoded = try FramePayload.decode(frame.concatenatedData())
        } catch {
            chain.record(number, intact: false, longTerm: false)
            statistics.framesLost += 1
            events.append(.lost(first: number, count: 1, reason: .malformedPayload))
            return
        }
        let intact = chain.isIntact(frameNumber: number, referenceDistance: frame.referenceDistance)
        chain.record(number, intact: intact, longTerm: frame.flags.contains(.longTermReference))
        statistics.framesDelivered += 1
        events.append(.frame(AssembledVideoFrame(
            streamID: streamID, frameNumber: number, captureTime: frame.captureTime, flags: frame.flags,
            referenceDistance: frame.referenceDistance, payload: decoded, referenceChainIntact: intact,
            recoveredShards: frame.recoveredShards, firstArrival: frame.firstArrival, completedAt: now)))
    }

    /// Gives up every frame from `nextFrame` up to (not including) `end`, in
    /// one event.
    private mutating func giveUp(upTo end: UInt32, reason: VideoAssemblyEvent.LossReason,
                                 into events: inout [VideoAssemblyEvent]) {
        guard let next = nextFrame, end != next else { return }
        let count = end &- next
        var number = next
        while number != end {
            if let frame = pending.removeValue(forKey: number) { bufferedBytes -= frame.bufferedBytes }
            chain.record(number, intact: false, longTerm: false)
            number &+= 1
        }
        statistics.framesLost += Int(count)
        events.append(.lost(first: next, count: count, reason: reason))
        nextFrame = end
    }
}

// MARK: - One frame in progress

private struct PendingFrame: Sendable {
    let captureTime: UInt64
    /// Without `.lastBlock`.
    let flags: VideoShardFlags
    let referenceDistance: UInt16
    let firstArrival: UInt64
    /// Every shard of a frame is the same size; the first accepted one fixes it.
    private(set) var shardSize: Int?
    var blocks: [PendingBlock?]
    var completeBlocks = 0
    var bufferedBytes = 0
    var recoveredShards = 0

    init(header: VideoShardHeader, firstArrival: UInt64) {
        captureTime = header.captureTime
        flags = header.flags.subtracting(.lastBlock)
        referenceDistance = header.referenceDistance
        self.firstArrival = firstArrival
        blocks = Array(repeating: nil, count: Int(header.blockCount))
    }

    var isComplete: Bool { completeBlocks == blocks.count }

    enum AddResult {
        case accepted(addedBytes: Int, recovered: Int)
        case duplicate
        case inconsistent
        case overBudget
    }

    mutating func add(_ header: VideoShardHeader, data: ArraySlice<UInt8>, now: UInt64, budget: Int) -> AddResult {
        guard header.captureTime == captureTime, header.flags.subtracting(.lastBlock) == flags,
              header.referenceDistance == referenceDistance, Int(header.blockCount) == blocks.count else {
            return .inconsistent
        }
        if let shardSize, shardSize != data.count { return .inconsistent }
        let index = Int(header.block)
        var block: PendingBlock
        var added = 0
        if let existing = blocks[index] {
            block = existing
            guard block.dataShards == Int(header.dataShards), block.parityShards == Int(header.parityShards) else {
                return .inconsistent
            }
        } else {
            let bytes = Int(header.dataShards) * data.count
            guard bytes <= budget else { return .overBudget }
            block = PendingBlock(dataShards: Int(header.dataShards), parityShards: Int(header.parityShards),
                                 shardSize: data.count)
            added = bytes
        }
        if block.isComplete { return .duplicate }
        let parityBytes = header.isParity ? data.count : 0
        guard added + parityBytes <= budget else { return .overBudget }
        guard block.store(shardIndex: Int(header.shardIndex), data: data) else { return .duplicate }
        added += parityBytes
        shardSize = data.count

        var recovered = 0
        if block.canComplete {
            let released = block.parityBytes
            recovered = block.complete()
            added -= released
            completeBlocks += 1
            recoveredShards += recovered
        }
        blocks[index] = block
        bufferedBytes += added
        return .accepted(addedBytes: added, recovered: recovered)
    }

    func concatenatedData() -> [UInt8] {
        var data: [UInt8] = []
        data.reserveCapacity(blocks.reduce(0) { $0 + ($1?.data.count ?? 0) })
        for block in blocks { data += block!.data }
        return data
    }

    func missing(frameNumber: UInt32) -> [MissingShards] {
        blocks.enumerated().compactMap { index, block in
            guard let block else { return MissingShards(frameNumber: frameNumber, scope: .wholeBlock(UInt8(index))) }
            guard !block.isComplete else { return nil }
            let dataIndices = (0..<block.dataShards).filter { !block.present[$0] }.map { UInt8($0) }
            return MissingShards(frameNumber: frameNumber,
                                 scope: .shards(block: UInt8(index), needed: block.needed, dataIndices: dataIndices))
        }
    }
}

// MARK: - One FEC block in progress

private struct PendingBlock: Sendable {
    let dataShards: Int
    let parityShards: Int
    let shardSize: Int
    var data: [UInt8]
    var present: [Bool]
    var presentData = 0
    var parity: [(index: Int, shard: ArraySlice<UInt8>)] = []
    var isComplete = false

    init(dataShards: Int, parityShards: Int, shardSize: Int) {
        self.dataShards = dataShards
        self.parityShards = parityShards
        self.shardSize = shardSize
        data = [UInt8](repeating: 0, count: dataShards * shardSize)
        present = [Bool](repeating: false, count: dataShards)
    }

    var canComplete: Bool { presentData + parity.count >= dataShards }
    var needed: Int { max(0, dataShards - presentData - parity.count) }
    var parityBytes: Int { parity.count * shardSize }

    /// Stores one shard; false if it was already here.
    mutating func store(shardIndex: Int, data shard: ArraySlice<UInt8>) -> Bool {
        if shardIndex < dataShards {
            guard !present[shardIndex] else { return false }
            data.replaceSubrange(shardIndex * shardSize..<(shardIndex + 1) * shardSize, with: shard)
            present[shardIndex] = true
            presentData += 1
        } else {
            let index = shardIndex - dataShards
            guard !parity.contains(where: { $0.index == index }) else { return false }
            parity.append((index, ArraySlice(Array(shard))))
        }
        return true
    }

    /// Rebuilds missing data from parity; returns how many shards it rebuilt.
    mutating func complete() -> Int {
        let rebuilt = dataShards - presentData
        if rebuilt > 0 {
            // The layout came from validated headers and the shard count was
            // checked, so this only fails on a cm256 bug; treat such a block's
            // data as garbage, which the payload parse then rejects.
            if let code = try? ReedSolomonCode(dataShards: dataShards, parityShards: parityShards, shardSize: shardSize) {
                try? code.reconstruct(data: &data, present: present, parity: parity)
            }
        }
        parity = []
        isComplete = true
        return rebuilt
    }
}

// MARK: - Reference chain

/// Which recent frames were delivered with an intact chain, for the
/// `referenceDistance` check (section 4.2). Bounded: the last `capacity`
/// frames, plus the newest long-term references, which can sit far back.
private struct ReferenceChain: Sendable {
    private var intact: [UInt32: Bool] = [:]
    private var order: [UInt32] = []
    private var head = 0
    private var longTerm: [UInt32] = []
    let capacity: Int
    static let longTermSlots = 16

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func isIntact(frameNumber: UInt32, referenceDistance: UInt16) -> Bool {
        guard referenceDistance != 0 else { return true }
        let reference = frameNumber &- UInt32(referenceDistance)
        return intact[reference] ?? false
    }

    mutating func record(_ number: UInt32, intact value: Bool, longTerm isLongTerm: Bool) {
        intact[number] = value
        if order.count < capacity {
            order.append(number)
        } else {
            let evicted = order[head]
            order[head] = number
            head = (head + 1) % capacity
            if !longTerm.contains(evicted) { intact[evicted] = nil }
        }
        guard isLongTerm, value else { return }
        longTerm.append(number)
        if longTerm.count > Self.longTermSlots {
            let dropped = longTerm.removeFirst()
            if !order.contains(dropped) { intact[dropped] = nil }
        }
    }
}
