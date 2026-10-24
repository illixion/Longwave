// StreamFEC: forward error correction for v3 media (NATIVE_V3_PROTOCOL.md
// sections 4.2 and 7.1). Systematic Cauchy Reed-Solomon over GF(2^8) from the
// vendored cm256, plus the block layout that turns one frame payload into
// shards. Foundation-free, like StreamWire.

import CCM256

/// Why an FEC call failed. Parameters out of range are caller bugs; a codec
/// failure means cm256 refused inputs that passed validation.
public enum FECError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case invalidParameters(String)
    /// Fewer than `dataShards` shards are present, so nothing can be rebuilt.
    case notEnoughShards(present: Int, needed: Int)
    case codecFailure(Int32)

    public var description: String {
        switch self {
        case .invalidParameters(let what): "FEC parameters invalid: \(what)"
        case .notEnoughShards(let present, let needed): "FEC needs \(needed) shards, has \(present)"
        case .codecFailure(let code): "cm256 failed with \(code)"
        }
    }
}

/// cm256's tables are built once per process; Swift runs a global's
/// initializer exactly once, on first use, from whichever thread gets there.
private let cm256Status: Int32 = cm256_init_(CM256_VERSION)

/// One Reed-Solomon block: `dataShards` shards of `shardSize` bytes protected by
/// `parityShards` parity shards. Any `dataShards` of the `dataShards +
/// parityShards` shards rebuild the data.
///
/// Data lives in one contiguous buffer of `dataShards * shardSize` bytes, shard
/// `i` at offset `i * shardSize`, which is how both the sharder and the frame
/// assembler hold a block.
public struct ReedSolomonCode: Sendable, Hashable {
    /// cm256's limit. The v3 shard header allows 255 (`VideoShardHeader.maxShardsPerBlock`).
    public static let maxTotalShards = 256

    public let dataShards: Int
    public let parityShards: Int
    public let shardSize: Int

    public init(dataShards: Int, parityShards: Int, shardSize: Int) throws(FECError) {
        guard dataShards >= 1 else { throw .invalidParameters("dataShards") }
        guard parityShards >= 0 else { throw .invalidParameters("parityShards") }
        guard dataShards + parityShards <= Self.maxTotalShards else { throw .invalidParameters("totalShards") }
        guard shardSize >= 1, shardSize <= Int(Int32.max) / Self.maxTotalShards else {
            throw .invalidParameters("shardSize")
        }
        guard cm256Status == 0 else { throw .codecFailure(cm256Status) }
        self.dataShards = dataShards
        self.parityShards = parityShards
        self.shardSize = shardSize
    }

    public var dataLength: Int { dataShards * shardSize }
    public var parityLength: Int { parityShards * shardSize }

    private var params: cm256_encoder_params {
        cm256_encoder_params(OriginalCount: Int32(dataShards), RecoveryCount: Int32(parityShards),
                             BlockBytes: Int32(shardSize))
    }

    /// Computes the parity shards for `data` (`dataLength` bytes) into
    /// `parity` (`parityLength` bytes), shard `j` at offset `j * shardSize`.
    public func encodeParity(of data: UnsafeRawBufferPointer, into parity: UnsafeMutableRawBufferPointer) throws(FECError) {
        guard data.count == dataLength, let dataBase = data.baseAddress else { throw .invalidParameters("data.count") }
        guard parity.count == parityLength else { throw .invalidParameters("parity.count") }
        guard parityShards > 0 else { return }
        let params = params
        let shardSize = shardSize
        let status = withUnsafeTemporaryAllocation(of: cm256_block.self, capacity: dataShards) { blocks -> Int32 in
            for i in 0..<blocks.count {
                // cm256 only reads originals; its struct just isn't const.
                blocks[i] = cm256_block(Block: UnsafeMutableRawPointer(mutating: dataBase + i * shardSize),
                                        Index: UInt8(i))
            }
            return cm256_encode(params, blocks.baseAddress, parity.baseAddress)
        }
        guard status == 0 else { throw .codecFailure(status) }
    }

    /// Array convenience for `encodeParity(of:into:)`.
    public func parity(of data: [UInt8]) throws(FECError) -> [UInt8] {
        guard data.count == dataLength else { throw .invalidParameters("data.count") }
        var parity = [UInt8](repeating: 0, count: parityLength)
        var failure: FECError?
        data.withUnsafeBytes { data in
            parity.withUnsafeMutableBytes { parity in
                do throws(FECError) { try encodeParity(of: data, into: parity) } catch { failure = error }
            }
        }
        if let failure { throw failure }
        return parity
    }

    /// Fills the missing data shards of `data` from parity.
    ///
    /// - Parameters:
    ///   - data: `dataLength` bytes; shard `i` is valid where `present[i]`.
    ///     Missing shards' bytes are overwritten.
    ///   - present: one flag per data shard.
    ///   - parity: received parity shards as `(index, bytes)`, index in
    ///     `0..<parityShards`, each exactly `shardSize` bytes. Extra ones beyond
    ///     what is needed are ignored.
    public func reconstruct(data: inout [UInt8], present: [Bool],
                            parity: [(index: Int, shard: ArraySlice<UInt8>)]) throws(FECError) {
        guard data.count == dataLength else { throw .invalidParameters("data.count") }
        guard present.count == dataShards else { throw .invalidParameters("present.count") }
        let missing = present.indices.filter { !present[$0] }
        guard !missing.isEmpty else { return }

        var seen = Set<Int>()
        var usable: [(index: Int, shard: ArraySlice<UInt8>)] = []
        for item in parity where usable.count < missing.count {
            guard item.index >= 0, item.index < parityShards else { throw .invalidParameters("parity.index") }
            guard item.shard.count == shardSize else { throw .invalidParameters("parity.shard.count") }
            if seen.insert(item.index).inserted { usable.append(item) }
        }
        guard usable.count == missing.count else {
            throw .notEnoughShards(present: dataShards - missing.count + usable.count, needed: dataShards)
        }

        // cm256 rebuilds in place inside the recovery blocks and relabels each
        // with the original index it now holds, which needn't be the slot it was
        // put in. So the parity goes into scratch, and each rebuilt block is
        // copied to the slot its new index names.
        var scratch = [UInt8](repeating: 0, count: usable.count * shardSize)
        for (n, item) in usable.enumerated() {
            scratch.replaceSubrange(n * shardSize..<(n + 1) * shardSize, with: item.shard)
        }
        let params = params
        let shardSize = shardSize
        let dataShards = dataShards
        var rebuilt: [(from: Int, to: Int)] = []
        rebuilt.reserveCapacity(usable.count)
        let status = data.withUnsafeMutableBytes { data -> Int32 in
            scratch.withUnsafeMutableBytes { scratch -> Int32 in
                withUnsafeTemporaryAllocation(of: cm256_block.self, capacity: dataShards) { blocks -> Int32 in
                    var next = 0
                    for i in 0..<dataShards {
                        if present[i] {
                            blocks[i] = cm256_block(Block: data.baseAddress! + i * shardSize, Index: UInt8(i))
                        } else {
                            blocks[i] = cm256_block(Block: scratch.baseAddress! + next * shardSize,
                                                    Index: UInt8(dataShards + usable[next].index))
                            next += 1
                        }
                    }
                    let status = cm256_decode(params, blocks.baseAddress)
                    guard status == 0 else { return status }
                    var slot = 0
                    for i in 0..<dataShards where !present[i] {
                        rebuilt.append((from: slot, to: Int(blocks[i].Index)))
                        slot += 1
                    }
                    return 0
                }
            }
        }
        guard status == 0 else { throw .codecFailure(status) }
        for move in rebuilt {
            guard move.to < dataShards, !present[move.to] else { throw .codecFailure(-1) }
            data.replaceSubrange(move.to * shardSize..<(move.to + 1) * shardSize,
                                 with: scratch[move.from * shardSize..<(move.from + 1) * shardSize])
        }
    }
}
