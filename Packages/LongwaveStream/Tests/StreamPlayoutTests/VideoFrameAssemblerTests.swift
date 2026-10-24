import StreamFEC
import StreamPlayout
import StreamWire
import XCTest

private let ms: UInt64 = 1_000_000
private let shardSize = 64

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// An access unit whose bytes name its frame, so a mix-up shows.
private func accessUnit(_ number: UInt32, length: Int) -> [UInt8] {
    (0..<length).map { UInt8(truncatingIfNeeded: Int(number) &* 31 &+ $0) }
}

private func sharded(_ number: UInt32, length: Int = 300, flags: VideoShardFlags = [], distance: UInt16 = 1,
                     policy: FECPolicy = .initial, streamID: UInt32 = 0) -> ShardedVideoFrame {
    let payload = try! FramePayload.encode(sideData: SideData(), accessUnit: accessUnit(number, length: length))
    let info = VideoFrameInfo(streamID: streamID, frameNumber: number, captureTime: UInt64(number) * 16 * ms,
                              flags: flags, referenceDistance: flags.contains(.key) ? 0 : distance)
    return try! ShardedVideoFrame(payload: payload, info: info, shardSize: shardSize, policy: policy)
}

private func shards(_ frame: ShardedVideoFrame) -> [(header: VideoShardHeader, data: ArraySlice<UInt8>)] {
    (0..<frame.count).map(frame.shard)
}

private extension VideoAssemblyEvent {
    var frame: AssembledVideoFrame? { if case .frame(let f) = self { f } else { nil } }
}

final class VideoFrameAssemblerTests: XCTestCase {
    private func feed(_ assembler: inout VideoFrameAssembler, _ items: some Sequence<(header: VideoShardHeader, data: ArraySlice<UInt8>)>,
                      now: UInt64) -> [VideoAssemblyEvent] {
        items.flatMap { assembler.receive($0.header, data: $0.data, now: now) }
    }

    private func checkPayload(_ frame: AssembledVideoFrame?, _ number: UInt32, length: Int = 300,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(frame?.frameNumber, number, file: file, line: line)
        XCTAssertEqual(frame.map { Array($0.payload.accessUnit) }, accessUnit(number, length: length), file: file, line: line)
    }

    func testCleanLinkDeliversEachFrameOnItsLastDataShard() {
        var assembler = VideoFrameAssembler(streamID: 0)
        let key = shards(sharded(10, flags: [.key]))
        let block = key[0].header
        // Every data shard but the last delivers nothing; the last completes it.
        let dataShards = Int(block.dataShards)
        XCTAssertTrue(feed(&assembler, key.prefix(dataShards - 1), now: 0).isEmpty)
        let events = feed(&assembler, key[(dataShards - 1)...], now: 1)
        XCTAssertEqual(events.count, 1, "parity after completion adds nothing")
        let frame = events[0].frame
        checkPayload(frame, 10)
        XCTAssertEqual(frame?.referenceChainIntact, true)
        XCTAssertEqual(frame?.recoveredShards, 0)
        XCTAssertEqual(frame?.captureTime, 160 * ms)
        // The frame was delivered on its last data shard, so its parity counts as late.
        XCTAssertEqual(assembler.statistics.lateShards, Int(block.parityShards))
        XCTAssertEqual(assembler.statistics.duplicateShards, 0)

        let next = feed(&assembler, shards(sharded(11)), now: 2).compactMap(\.frame)
        checkPayload(next.first, 11)
        XCTAssertEqual(next.first?.referenceChainIntact, true)
        XCTAssertEqual(assembler.pendingFrameCount, 0)
        XCTAssertEqual(assembler.bufferedBytes, 0)
    }

    func testLossWithinParityIsRebuilt() {
        var assembler = VideoFrameAssembler(streamID: 0)
        var items = shards(sharded(1, length: 2000, flags: [.key]))
        let parity = Int(items[0].header.parityShards)
        // Lose as many data shards as there is parity.
        items.removeSubrange(0..<parity)
        let frame = feed(&assembler, items, now: 0).compactMap(\.frame).first
        checkPayload(frame, 1, length: 2000)
        XCTAssertEqual(frame?.recoveredShards, parity)
        XCTAssertEqual(assembler.statistics.recoveredShards, parity)
    }

    func testReorderedShardsAndFramesComeOutInOrder() {
        var assembler = VideoFrameAssembler(streamID: 0)
        var rng = SplitMix64(state: 9)
        var items: [(header: VideoShardHeader, data: ArraySlice<UInt8>)] = []
        items += shards(sharded(0, flags: [.key]))
        for n in 1...5 as ClosedRange<UInt32> { items += shards(sharded(n)) }
        // Frame 0's first shard leads, so the assembler starts at 0; the rest are shuffled.
        let rest = items[1...].shuffled(using: &rng)
        let frames = feed(&assembler, [items[0]] + rest, now: 0).compactMap(\.frame)
        XCTAssertEqual(frames.map(\.frameNumber), [0, 1, 2, 3, 4, 5])
        XCTAssertTrue(frames.allSatisfy(\.referenceChainIntact))
    }

    func testCompletedFrameWaitsBehindAnIncompleteOne() {
        var assembler = VideoFrameAssembler(streamID: 0)
        let first = shards(sharded(0, flags: [.key]))
        XCTAssertTrue(feed(&assembler, first.prefix(1), now: 0).isEmpty)
        XCTAssertTrue(feed(&assembler, shards(sharded(1)), now: 1).isEmpty, "frame 1 waits for frame 0")
        let frames = feed(&assembler, first.dropFirst(), now: 2).compactMap(\.frame)
        XCTAssertEqual(frames.map(\.frameNumber), [0, 1])
    }

    func testLossBeyondParityIsListedThenRecoveredByResend() {
        var assembler = VideoFrameAssembler(streamID: 0)
        let items = shards(sharded(0, length: 2000, flags: [.key], policy: .none))
        let k = Int(items[0].header.dataShards)
        // Shards 3 and 7 are lost; no parity to cover them.
        let kept = items.enumerated().filter { $0.offset != 3 && $0.offset != 7 }.map(\.element)
        XCTAssertTrue(feed(&assembler, kept, now: 0).isEmpty)

        XCTAssertEqual(assembler.missingShards(now: 1 * ms), [], "inside the reorder window, it may just be late")
        XCTAssertEqual(assembler.missingShards(now: 2 * ms),
                       [MissingShards(frameNumber: 0, scope: .shards(block: 0, needed: 2, dataIndices: [3, 7]))])
        XCTAssertEqual(k, 32)

        XCTAssertTrue(assembler.receive(items[3].header, data: items[3].data, now: 3 * ms).isEmpty)
        let frame = assembler.receive(items[7].header, data: items[7].data, now: 3 * ms).first?.frame
        checkPayload(frame, 0, length: 2000)
        XCTAssertEqual(assembler.missingShards(now: 4 * ms), [])
    }

    func testFrameGivenUpAfterTimeoutAndChainBreaks() {
        var assembler = VideoFrameAssembler(streamID: 0)
        _ = feed(&assembler, shards(sharded(0, flags: [.key])), now: 0)
        let partial = shards(sharded(1))
        _ = feed(&assembler, partial.prefix(1), now: 1 * ms)
        // 2 and 3 complete but sit behind 1.
        XCTAssertTrue(feed(&assembler, shards(sharded(2)) + shards(sharded(3, distance: 3)), now: 2 * ms).isEmpty)
        XCTAssertTrue(assembler.poll(now: 100 * ms).isEmpty, "not yet: 100 ms after its first shard")

        let events = assembler.poll(now: 101 * ms)
        guard events.count == 3, case .lost(1, 1, .timedOut) = events[0] else {
            return XCTFail("expected frame 1 lost then 2 and 3, got \(events)")
        }
        XCTAssertEqual(events[1].frame?.frameNumber, 2)
        XCTAssertEqual(events[1].frame?.referenceChainIntact, false, "2 predicts from the lost 1")
        XCTAssertEqual(events[2].frame?.frameNumber, 3)
        XCTAssertEqual(events[2].frame?.referenceChainIntact, true, "3 predicts from 0, which arrived")
        XCTAssertEqual(assembler.statistics.framesLost, 1)
        XCTAssertEqual(assembler.bufferedBytes, 0)

        let lateBefore = assembler.statistics.lateShards
        let late = assembler.receive(partial[1].header, data: partial[1].data, now: 102 * ms)
        XCTAssertTrue(late.isEmpty)
        XCTAssertEqual(assembler.statistics.lateShards, lateBefore + 1)
    }

    func testAFrameThatNeverShowedIsAGapThenLost() {
        var assembler = VideoFrameAssembler(streamID: 0)
        _ = feed(&assembler, shards(sharded(0, flags: [.key])), now: 0)
        XCTAssertTrue(feed(&assembler, shards(sharded(2, distance: 2)), now: 10 * ms).isEmpty)
        XCTAssertEqual(assembler.missingShards(now: 12 * ms), [MissingShards(frameNumber: 1, scope: .wholeFrame)])
        let events = assembler.poll(now: 110 * ms)
        guard case .lost(1, 1, .timedOut) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(events.last?.frame?.frameNumber, 2)
        XCTAssertEqual(events.last?.frame?.referenceChainIntact, true)
    }

    func testAKeyFrameRestoresTheChain() {
        var assembler = VideoFrameAssembler(streamID: 0)
        // Joining mid-stream: the first frame seen predicts from one never seen.
        let first = feed(&assembler, shards(sharded(50)), now: 0).compactMap(\.frame)
        XCTAssertEqual(first.first?.referenceChainIntact, false)
        let key = feed(&assembler, shards(sharded(51, flags: [.key])) + shards(sharded(52)), now: 1).compactMap(\.frame)
        XCTAssertEqual(key.map(\.referenceChainIntact), [true, true])
    }

    func testRecoveryFrameFromALongTermReference() {
        var assembler = VideoFrameAssembler(streamID: 0, configuration: .init(referenceHistory: 4))
        _ = feed(&assembler, shards(sharded(0, flags: [.key, .longTermReference])), now: 0)
        for n in 1...20 as ClosedRange<UInt32> { _ = feed(&assembler, shards(sharded(n)), now: UInt64(n)) }
        // Frame 21 recovers from the LTR, 21 frames back, long out of the 4-frame history.
        let frame = feed(&assembler, shards(sharded(21, flags: [.recovery], distance: 21)), now: 30).first?.frame
        XCTAssertEqual(frame?.referenceChainIntact, true)
        // An ordinary frame that far back is forgotten, so its chain counts as broken.
        let stale = feed(&assembler, shards(sharded(22, distance: 10)), now: 31).first?.frame
        XCTAssertEqual(stale?.referenceChainIntact, false)
    }

    func testFarJumpGivesUpTheGapInOneEvent() {
        var assembler = VideoFrameAssembler(streamID: 0, configuration: .init(maxFramesAhead: 10))
        _ = feed(&assembler, shards(sharded(0, flags: [.key])), now: 0)
        _ = feed(&assembler, shards(sharded(1)).prefix(1), now: 0)
        let events = feed(&assembler, shards(sharded(100, flags: [.key])), now: 1)
        guard case .lost(1, 89, .skippedAhead) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(assembler.nextFrame, 90)
        XCTAssertEqual(assembler.pendingFrameCount, 1, "frame 1's partial is dropped with the gap")
        // 90...99 are still awaited, so 100 waits for them or their timeout.
        XCTAssertEqual(events.count, 1)
        let rest = assembler.poll(now: 1 + 100 * ms)
        guard case .lost(90, 10, .timedOut)? = rest.first else { return XCTFail("\(rest)") }
        XCTAssertEqual(rest.last?.frame?.frameNumber, 100)
    }

    func testFrameNumbersWrap() {
        var assembler = VideoFrameAssembler(streamID: 0)
        let numbers: [UInt32] = [UInt32.max - 1, UInt32.max, 0, 1]
        var delivered: [UInt32] = []
        delivered += feed(&assembler, shards(sharded(numbers[0], flags: [.key])), now: 0).compactMap(\.frame).map(\.frameNumber)
        for n in numbers.dropFirst() {
            let frames = feed(&assembler, shards(sharded(n)), now: 1).compactMap(\.frame)
            XCTAssertEqual(frames.first?.referenceChainIntact, true)
            delivered += frames.map(\.frameNumber)
        }
        XCTAssertEqual(delivered, numbers)
    }

    func testInconsistentShardsAreRefused() {
        var assembler = VideoFrameAssembler(streamID: 0)
        let items = shards(sharded(0, length: 2000, flags: [.key]))
        _ = assembler.receive(items[0].header, data: items[0].data, now: 0)

        var otherTime = items[1].header
        otherTime.captureTime += 1
        var otherDistance = items[1].header
        otherDistance.flags = []
        otherDistance.referenceDistance = 4
        for header in [otherTime, otherDistance] {
            XCTAssertTrue(assembler.receive(header, data: items[1].data, now: 0).isEmpty)
        }
        XCTAssertTrue(assembler.receive(items[1].header, data: items[1].data.dropLast(), now: 0).isEmpty)
        var otherStream = items[1].header
        otherStream.streamID = 9
        XCTAssertTrue(assembler.receive(otherStream, data: items[1].data, now: 0).isEmpty)
        XCTAssertEqual(assembler.statistics.inconsistentShards, 4)

        // The genuine frame still completes.
        let frame = feed(&assembler, items.dropFirst(), now: 1).compactMap(\.frame).first
        checkPayload(frame, 0, length: 2000)
    }

    func testMemoryCeilingDropsShardsAndTheFrameTimesOut() {
        let items = shards(sharded(0, length: 2000, flags: [.key], policy: .none))
        let k = Int(items[0].header.dataShards)
        var assembler = VideoFrameAssembler(streamID: 0, configuration: .init(maxBufferedBytes: k * shardSize - 1))
        XCTAssertTrue(feed(&assembler, items, now: 0).isEmpty)
        XCTAssertEqual(assembler.statistics.shardsDroppedForMemory, k)
        XCTAssertEqual(assembler.bufferedBytes, 0)
        // Nothing later arrived, so only the tail window says the block is missing.
        XCTAssertEqual(assembler.missingShards(now: 5 * ms), [])
        XCTAssertEqual(assembler.missingShards(now: 6 * ms), [MissingShards(frameNumber: 0, scope: .wholeBlock(0))])
        guard case .lost(0, 1, .timedOut)? = assembler.poll(now: 200 * ms).first else { return XCTFail() }
    }

    func testMalformedPayloadIsLostNotDelivered() {
        var assembler = VideoFrameAssembler(streamID: 0)
        // A data shard of all 0xFF: contentLength is far past the data.
        let header = VideoShardHeader(streamID: 0, frameNumber: 5, captureTime: 1, flags: [.key, .lastBlock], block: 0,
                                      blockCount: 1, shardIndex: 0, dataShards: 1, parityShards: 0, referenceDistance: 0)
        let events = assembler.receive(header, data: ArraySlice(repeating: 0xFF, count: 32), now: 0)
        guard case .lost(5, 1, .malformedPayload)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(assembler.nextFrame, 6)
    }

    func testResetStartsOver() {
        var assembler = VideoFrameAssembler(streamID: 0)
        _ = feed(&assembler, shards(sharded(40, flags: [.key])), now: 0)
        _ = feed(&assembler, shards(sharded(41)).prefix(1), now: 0)
        assembler.reset()
        XCTAssertNil(assembler.nextFrame)
        XCTAssertEqual(assembler.bufferedBytes, 0)
        let frame = feed(&assembler, shards(sharded(3, flags: [.key])), now: 1).first?.frame
        XCTAssertEqual(frame?.frameNumber, 3)
    }

    /// Soak: 300 frames with 15% random shard loss, reordering within a few
    /// frames, and NACK resends of whatever the assembler lists after each
    /// window. Every frame must come out, in order, byte-exact.
    func testRandomLossReorderAndResend() {
        var rng = SplitMix64(state: 42)
        var assembler = VideoFrameAssembler(streamID: 3)
        var all: [UInt32: ShardedVideoFrame] = [:]
        var inFlight: [(at: UInt64, header: VideoShardHeader, data: ArraySlice<UInt8>)] = []
        var delivered: [AssembledVideoFrame] = []
        var lost = 0
        var now: UInt64 = 0
        for n in 0..<300 as Range<UInt32> {
            let frame = sharded(n, length: Int.random(in: 10...4000, using: &rng), flags: n % 60 == 0 ? [.key] : [],
                                streamID: 3)
            all[n] = frame
            for shard in shards(frame) where Double.random(in: 0..<1, using: &rng) >= 0.15 {
                inFlight.append((now + UInt64.random(in: 0...(30 * ms), using: &rng), shard.header, shard.data))
            }
            now += 11 * ms
            inFlight.sort { $0.at < $1.at }
            while let first = inFlight.first, first.at <= now {
                inFlight.removeFirst()
                for event in assembler.receive(first.header, data: first.data, now: first.at) {
                    if let f = event.frame { delivered.append(f) } else { lost += 1 }
                }
            }
            // NACK: resend each listed data shard (or the whole frame) once, losslessly.
            for request in assembler.missingShards(now: now) {
                guard let frame = all[request.frameNumber] else { continue }
                for shard in shards(frame) {
                    switch request.scope {
                    case .wholeFrame: break
                    case .wholeBlock(let block): guard shard.header.block == block else { continue }
                    case .shards(let block, _, let indices):
                        guard shard.header.block == block, indices.contains(shard.header.shardIndex) else { continue }
                    }
                    inFlight.append((now + 3 * ms, shard.header, shard.data))
                }
            }
        }
        for item in inFlight.sorted(by: { $0.at < $1.at }) {
            for event in assembler.receive(item.header, data: item.data, now: item.at) {
                if let f = event.frame { delivered.append(f) } else { lost += 1 }
            }
        }
        XCTAssertEqual(lost, 0)
        XCTAssertEqual(delivered.map(\.frameNumber), Array(0..<300))
        for frame in delivered {
            XCTAssertEqual(Array(frame.payload.accessUnit),
                           accessUnit(frame.frameNumber, length: frame.payload.accessUnit.count))
            XCTAssertTrue(frame.referenceChainIntact)
        }
        XCTAssertGreaterThan(assembler.statistics.recoveredShards, 0)
        XCTAssertEqual(assembler.pendingFrameCount, 0)
        XCTAssertEqual(assembler.bufferedBytes, 0)
    }
}
