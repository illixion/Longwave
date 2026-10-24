import StreamFEC
import XCTest

/// A small deterministic generator, so a failing case replays exactly.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func randomBytes(_ count: Int, _ rng: inout SplitMix64) -> [UInt8] {
    (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
}

final class ReedSolomonTests: XCTestCase {
    /// Drops the data shards in `lost`, rebuilds from the parity shards in
    /// `parityUsed`, and checks the data comes back byte for byte.
    private func roundTrip(code: ReedSolomonCode, data original: [UInt8], parity: [UInt8], lost: [Int],
                           parityUsed: [Int], file: StaticString = #filePath, line: UInt = #line) throws {
        let size = code.shardSize
        var data = original
        var present = [Bool](repeating: true, count: code.dataShards)
        for i in lost {
            present[i] = false
            for b in i * size..<(i + 1) * size { data[b] = 0xEE }
        }
        let shards = parityUsed.map { (index: $0, shard: parity[$0 * size..<($0 + 1) * size]) }
        try code.reconstruct(data: &data, present: present, parity: shards)
        XCTAssertEqual(data, original, "lost \(lost) via parity \(parityUsed)", file: file, line: line)
    }

    /// The property the design tests against whatever library is underneath:
    /// any k of the k + m shards rebuild the data. Exhaustive for small blocks.
    func testAnyKOfKPlusMReconstructsSmallBlocks() throws {
        var rng = SplitMix64(seed: 1)
        for (k, m) in [(1, 1), (1, 2), (2, 2), (3, 2), (5, 3), (8, 4)] {
            let code = try ReedSolomonCode(dataShards: k, parityShards: m, shardSize: 37)
            let data = randomBytes(code.dataLength, &rng)
            let parity = try code.parity(of: data)
            // Every subset of data shards to lose, up to m of them, with every
            // choice of which parity shards stand in.
            for mask in 0..<(1 << k) where mask.nonzeroBitCount <= m {
                let lost = (0..<k).filter { mask & (1 << $0) != 0 }
                for parityMask in 0..<(1 << m) where parityMask.nonzeroBitCount == lost.count {
                    let used = (0..<m).filter { parityMask & (1 << $0) != 0 }
                    try roundTrip(code: code, data: data, parity: parity, lost: lost, parityUsed: used)
                }
            }
        }
    }

    /// Full-size blocks, as a desktop frame's are: random losses up to m.
    func testLargeBlocksReconstructFromRandomLosses() throws {
        var rng = SplitMix64(seed: 2)
        for (k, m) in [(200, 55), (232, 23), (128, 128)] {
            let code = try ReedSolomonCode(dataShards: k, parityShards: m, shardSize: 1144)
            let data = randomBytes(code.dataLength, &rng)
            let parity = try code.parity(of: data)
            for _ in 0..<5 {
                let lostCount = Int.random(in: 1...m, using: &rng)
                let lost = Array((0..<k).shuffled(using: &rng).prefix(lostCount))
                let used = Array((0..<m).shuffled(using: &rng).prefix(lostCount))
                try roundTrip(code: code, data: data, parity: parity, lost: lost, parityUsed: used)
            }
        }
    }

    /// The Windows host links the same cm256, and both ends have to agree on
    /// the Cauchy matrix byte for byte. This pins it: swapping the codec for
    /// another RS implementation breaks interop and this test.
    func testGoldenParity() throws {
        let code = try ReedSolomonCode(dataShards: 3, parityShards: 2, shardSize: 4)
        let data: [UInt8] = [0x00, 0x01, 0x02, 0x03, 0x10, 0x20, 0x30, 0x40, 0xFF, 0xFE, 0xFD, 0xFC]
        // cm256's first parity row is all ones, so parity shard 0 is the XOR of
        // the data shards (00^10^ff = ef, ...), a check that needs no library.
        XCTAssertEqual(hexString(try code.parity(of: data)), "efdfcfbf" + "c5893411")
    }

    func testNothingMissingIsANoOp() throws {
        let code = try ReedSolomonCode(dataShards: 2, parityShards: 1, shardSize: 3)
        var data: [UInt8] = [1, 2, 3, 4, 5, 6]
        try code.reconstruct(data: &data, present: [true, true], parity: [])
        XCTAssertEqual(data, [1, 2, 3, 4, 5, 6])
    }

    func testDuplicateAndSurplusParityAreIgnored() throws {
        var rng = SplitMix64(seed: 3)
        let code = try ReedSolomonCode(dataShards: 4, parityShards: 3, shardSize: 16)
        let original = randomBytes(code.dataLength, &rng)
        let parity = try code.parity(of: original)
        var data = original
        for b in 16..<32 { data[b] = 0 }
        let shard = { (j: Int) in (index: j, shard: parity[j * 16..<(j + 1) * 16]) }
        try code.reconstruct(data: &data, present: [true, false, true, true], parity: [shard(2), shard(2), shard(0)])
        XCTAssertEqual(data, original)
    }

    func testTooFewShardsIsReported() throws {
        let code = try ReedSolomonCode(dataShards: 4, parityShards: 2, shardSize: 8)
        var data = [UInt8](repeating: 0, count: 32)
        let parity = try code.parity(of: data)
        XCTAssertThrowsError(try code.reconstruct(data: &data, present: [false, false, false, true],
                                                  parity: [(0, parity[0..<8]), (1, parity[8..<16])])) {
            XCTAssertEqual($0 as? FECError, .notEnoughShards(present: 3, needed: 4))
        }
    }

    func testParametersAreChecked() {
        XCTAssertThrowsError(try ReedSolomonCode(dataShards: 0, parityShards: 1, shardSize: 8))
        XCTAssertThrowsError(try ReedSolomonCode(dataShards: 200, parityShards: 57, shardSize: 8))
        XCTAssertThrowsError(try ReedSolomonCode(dataShards: 1, parityShards: 1, shardSize: 0))
        XCTAssertNoThrow(try ReedSolomonCode(dataShards: 200, parityShards: 56, shardSize: 8))
        XCTAssertNoThrow(try ReedSolomonCode(dataShards: 3, parityShards: 0, shardSize: 8))
    }

    func testWrongSizedParityShardIsRejected() throws {
        let code = try ReedSolomonCode(dataShards: 2, parityShards: 1, shardSize: 8)
        var data = [UInt8](repeating: 0, count: 16)
        XCTAssertThrowsError(try code.reconstruct(data: &data, present: [true, false],
                                                  parity: [(0, ArraySlice(repeating: 0, count: 7))]))
    }
}

func hexString(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
}
