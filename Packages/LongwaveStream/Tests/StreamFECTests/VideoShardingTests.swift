import StreamFEC
import StreamWire
import XCTest

final class FECPolicyTests: XCTestCase {
    /// Permille keeps the ceiling exact where a Double ratio would not
    /// (30 × 0.1 is 3.0000000000000004).
    func testParityCeilingIsExact() {
        let policy = FECPolicy(ratioPermille: 100, minimumParity: 0)
        XCTAssertEqual(policy.parityShards(forDataShards: 30), 3)
        XCTAssertEqual(policy.parityShards(forDataShards: 31), 4)
        XCTAssertEqual(policy.parityShards(forDataShards: 10), 1)
    }

    func testMinimumParityProtectsSmallFrames() {
        XCTAssertEqual(FECPolicy.initial.parityShards(forDataShards: 3), 2)
        XCTAssertEqual(FECPolicy.initial.parityShards(forDataShards: 100), 10)
        XCTAssertEqual(FECPolicy.none.parityShards(forDataShards: 100), 0)
    }

    func testPolicyThatCannotFitOneShardIsRejected() {
        XCTAssertThrowsError(try FECPolicy(ratioPermille: 0, minimumParity: 255).validate())
        XCTAssertNoThrow(try FECPolicy(ratioPermille: 0, minimumParity: 254).validate())
    }
}

final class VideoBlockLayoutTests: XCTestCase {
    private func checkInvariants(_ layout: VideoBlockLayout, payloadLength: Int, policy: FECPolicy,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(layout.totalDataShards, (payloadLength + layout.shardSize - 1) / layout.shardSize,
                       file: file, line: line)
        XCTAssertEqual(layout.blocks.reduce(0) { $0 + $1.dataShards }, layout.totalDataShards, file: file, line: line)
        var next = 0
        for block in layout.blocks {
            XCTAssertEqual(block.firstShard, next, file: file, line: line)
            next += block.dataShards
            XCTAssertLessThanOrEqual(block.dataShards + block.parityShards, 255, file: file, line: line)
            XCTAssertEqual(block.parityShards, policy.parityShards(forDataShards: block.dataShards), file: file, line: line)
        }
        let sizes = layout.blocks.map(\.dataShards)
        XCTAssertLessThanOrEqual(sizes.max()! - sizes.min()!, 1, "blocks are as even as possible", file: file, line: line)
        XCTAssertEqual(sizes, sizes.sorted(by: >), "larger blocks first", file: file, line: line)
        // Minimal: one block fewer would not fit.
        let fewer = layout.blocks.count - 1
        if fewer >= 1 {
            let largest = (layout.totalDataShards + fewer - 1) / fewer
            XCTAssertGreaterThan(largest + policy.parityShards(forDataShards: largest), 255, file: file, line: line)
        }
    }

    func testSmallFrameIsOneBlock() throws {
        let layout = try VideoBlockLayout(payloadLength: 700, shardSize: 1144, policy: .initial)
        XCTAssertEqual(layout.blocks, [.init(firstShard: 0, dataShards: 1, parityShards: 2)])
        XCTAssertEqual(layout.paddedLength, 1144)
    }

    /// A Retina refinement frame (section 4.2 cites 470-850 KB): ~743 shards
    /// at 1144 bytes. With 10% parity, three blocks of 248 don't fit (248 + 25),
    /// so it takes four.
    func testLargeDesktopFrameSplitsEvenly() throws {
        let length = 850_000
        let layout = try VideoBlockLayout(payloadLength: length, shardSize: 1144, policy: .initial)
        XCTAssertEqual(layout.totalDataShards, 744)
        XCTAssertEqual(layout.blocks.map(\.dataShards), [186, 186, 186, 186])
        checkInvariants(layout, payloadLength: length, policy: .initial)
    }

    func testInvariantsAcrossSizesAndPolicies() throws {
        var rng = SplitMix64(seed: 4)
        let policies = [FECPolicy.initial, .none, FECPolicy(ratioPermille: 500, minimumParity: 2),
                        FECPolicy(ratioPermille: 50, minimumParity: 2)]
        for _ in 0..<400 {
            let size = [1144, 1396, 64].randomElement(using: &rng)!
            // Up to ~2,500 KB at real shard sizes; small shards stay well under
            // the 255-block limit (tested on its own below).
            let length = Int.random(in: 1...(size == 64 ? 600_000 : 3_000_000), using: &rng)
            let policy = policies.randomElement(using: &rng)!
            let layout = try VideoBlockLayout(payloadLength: length, shardSize: size, policy: policy)
            checkInvariants(layout, payloadLength: length, policy: policy)
        }
    }

    func testFrameNeedingMoreThan255BlocksIsRejected() {
        // 255 blocks of at most 255 shards each, at 1 byte a shard.
        XCTAssertThrowsError(try VideoBlockLayout(payloadLength: 255 * 255 + 1, shardSize: 1, policy: .none))
        XCTAssertNoThrow(try VideoBlockLayout(payloadLength: 255 * 255, shardSize: 1, policy: .none))
    }
}

final class ShardedVideoFrameTests: XCTestCase {
    private let info = VideoFrameInfo(streamID: 7, frameNumber: 0xFFFF_FFFE, captureTime: 123_456_789,
                                      flags: [.discardable], referenceDistance: 1)

    func testShardsCarryHeadersAndDataInSendingOrder() throws {
        var rng = SplitMix64(seed: 5)
        let accessUnit = randomBytes(600_000, &rng)
        let payload = try FramePayload.encode(sideData: SideData(), accessUnit: accessUnit)
        let shardSize = DatagramLayout.videoShardDataCapacity(udpPayload: DatagramLayout.defaultUDPPayload)
        let frame = try ShardedVideoFrame(payload: payload, info: info, shardSize: shardSize, policy: .initial)
        let layout = frame.layout
        XCTAssertEqual(frame.count, layout.totalDataShards + layout.totalParityShards)

        var data: [UInt8] = []
        var n = 0
        for (blockIndex, block) in layout.blocks.enumerated() {
            for shardIndex in 0..<(block.dataShards + block.parityShards) {
                let (header, bytes) = frame.shard(n)
                n += 1
                XCTAssertNoThrow(try header.validate())
                XCTAssertEqual(Int(header.block), blockIndex)
                XCTAssertEqual(Int(header.blockCount), layout.blocks.count)
                XCTAssertEqual(Int(header.shardIndex), shardIndex)
                XCTAssertEqual(Int(header.dataShards), block.dataShards)
                XCTAssertEqual(Int(header.parityShards), block.parityShards)
                XCTAssertEqual(header.frameNumber, info.frameNumber)
                XCTAssertEqual(header.captureTime, info.captureTime)
                XCTAssertEqual(header.referenceDistance, 1)
                XCTAssertEqual(header.flags.contains(.lastBlock), blockIndex == layout.blocks.count - 1)
                XCTAssertTrue(header.flags.contains(.discardable))
                XCTAssertEqual(bytes.count, shardSize)
                if !header.isParity { data += bytes }
            }
        }
        XCTAssertEqual(Array(data.prefix(payload.count)), payload)
        XCTAssertTrue(data.dropFirst(payload.count).allSatisfy { $0 == 0 })
        let decoded = try FramePayload.decode(data)
        XCTAssertEqual(Array(decoded.accessUnit), accessUnit)
    }

    func testParityRebuildsADroppedDataShard() throws {
        let payload = try FramePayload.encode(sideData: SideData(), accessUnit: [UInt8](repeating: 0xAB, count: 5000))
        let frame = try ShardedVideoFrame(payload: payload, info: info, shardSize: 1144, policy: .initial)
        let block = frame.layout.blocks[0]
        let code = try ReedSolomonCode(dataShards: block.dataShards, parityShards: block.parityShards, shardSize: 1144)
        var data: [UInt8] = []
        var parity: [(index: Int, shard: ArraySlice<UInt8>)] = []
        for n in 0..<frame.count {
            let (header, bytes) = frame.shard(n)
            if header.isParity {
                parity.append((Int(header.shardIndex) - block.dataShards, bytes))
            } else {
                data += header.shardIndex == 2 ? [UInt8](repeating: 0, count: 1144) : Array(bytes)
            }
        }
        var present = [Bool](repeating: true, count: block.dataShards)
        present[2] = false
        try code.reconstruct(data: &data, present: present, parity: parity)
        XCTAssertEqual(Array(data.prefix(payload.count)), payload)
    }

    func testLastBlockFlagFromTheCallerIsRefused() {
        var info = info
        info.flags.insert(.lastBlock)
        XCTAssertThrowsError(try ShardedVideoFrame(payload: [0, 0, 0, 2, 0, 0], info: info, shardSize: 64,
                                                   policy: .initial))
    }
}
