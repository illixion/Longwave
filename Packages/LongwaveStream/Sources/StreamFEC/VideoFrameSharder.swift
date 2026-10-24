import StreamWire

/// The per-frame facts every shard header repeats.
public struct VideoFrameInfo: Sendable, Hashable {
    public var streamID: UInt32
    public var frameNumber: UInt32
    public var captureTime: UInt64
    /// Everything but `.lastBlock`, which the sharder sets per block.
    public var flags: VideoShardFlags
    public var referenceDistance: UInt16

    public init(streamID: UInt32, frameNumber: UInt32, captureTime: UInt64, flags: VideoShardFlags,
                referenceDistance: UInt16) {
        self.streamID = streamID
        self.frameNumber = frameNumber
        self.captureTime = captureTime
        self.flags = flags
        self.referenceDistance = referenceDistance
    }
}

/// One encoded frame cut into shards with their parity, ready to send.
///
/// Shards come block by block, data then parity, which is the order to send
/// them in: a clean link has every data shard before any parity arrives.
/// Each shard's bytes are a slice of storage the value owns, so nothing is
/// copied again until the datagram is written.
public struct ShardedVideoFrame: Sendable {
    public let info: VideoFrameInfo
    public let layout: VideoBlockLayout
    /// The payload, zero-padded to whole shards.
    private let data: [UInt8]
    /// Each block's parity shards, end to end.
    private let parity: [[UInt8]]
    /// For shard `n`: its block, and its index within that block.
    private let index: [(block: Int, shard: Int)]

    public var count: Int { index.count }

    /// Shard `n` in sending order.
    public func shard(_ n: Int) -> (header: VideoShardHeader, data: ArraySlice<UInt8>) {
        let (blockIndex, shardIndex) = index[n]
        let block = layout.blocks[blockIndex]
        let size = layout.shardSize
        let bytes: ArraySlice<UInt8>
        if shardIndex < block.dataShards {
            let start = (block.firstShard + shardIndex) * size
            bytes = data[start..<start + size]
        } else {
            let start = (shardIndex - block.dataShards) * size
            bytes = parity[blockIndex][start..<start + size]
        }
        let blockCount = layout.blocks.count
        var flags = info.flags
        if blockIndex == blockCount - 1 { flags.insert(.lastBlock) }
        let header = VideoShardHeader(
            streamID: info.streamID, frameNumber: info.frameNumber, captureTime: info.captureTime, flags: flags,
            block: UInt8(blockIndex), blockCount: UInt8(blockCount), shardIndex: UInt8(shardIndex),
            dataShards: UInt8(block.dataShards), parityShards: UInt8(block.parityShards),
            referenceDistance: info.referenceDistance)
        return (header, bytes)
    }

    /// Cuts `payload` (a `FramePayload` encoding) into `shardSize`-byte shards
    /// (`DatagramLayout.videoShardDataCapacity`) and computes parity per `policy`.
    public init(payload: [UInt8], info: VideoFrameInfo, shardSize: Int, policy: FECPolicy) throws(FECError) {
        guard !info.flags.contains(.lastBlock), info.flags.isSubset(of: .defined) else {
            throw .invalidParameters("info.flags")
        }
        let layout = try VideoBlockLayout(payloadLength: payload.count, shardSize: shardSize, policy: policy)
        var data = payload
        data.append(contentsOf: repeatElement(0, count: layout.paddedLength - payload.count))

        var parity: [[UInt8]] = []
        parity.reserveCapacity(layout.blocks.count)
        var index: [(block: Int, shard: Int)] = []
        index.reserveCapacity(layout.totalDataShards + layout.totalParityShards)
        for (blockIndex, block) in layout.blocks.enumerated() {
            let code = try ReedSolomonCode(dataShards: block.dataShards, parityShards: block.parityShards,
                                           shardSize: shardSize)
            var blockParity = [UInt8](repeating: 0, count: code.parityLength)
            let start = block.firstShard * shardSize
            var failure: FECError?
            data.withUnsafeBytes { all in
                blockParity.withUnsafeMutableBytes { out in
                    do throws(FECError) {
                        try code.encodeParity(of: UnsafeRawBufferPointer(rebasing: all[start..<start + code.dataLength]),
                                              into: out)
                    } catch { failure = error }
                }
            }
            if let failure { throw failure }
            parity.append(blockParity)
            for shard in 0..<(block.dataShards + block.parityShards) { index.append((blockIndex, shard)) }
        }
        self.info = info
        self.layout = layout
        self.data = data
        self.parity = parity
        self.index = index
    }
}
