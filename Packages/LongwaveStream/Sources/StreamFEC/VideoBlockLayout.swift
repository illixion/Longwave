import StreamWire

/// How much parity a block gets (section 4.2): `m = max(minimumParity,
/// ceil(k × ratio))`.
///
/// The ratio is held in permille so the ceiling is exact. With a `Double`,
/// 30 × 0.1 is 3.0000000000000004 and the ceiling adds a shard nobody asked for.
public struct FECPolicy: Sendable, Hashable {
    /// Parity shards per 1000 data shards. The rate controller keeps this
    /// within 50...500 (5% to 50%); 0 means parity only from `minimumParity`.
    public var ratioPermille: Int
    /// Floor per block, so a 3-shard P-frame still gets protection. 2 in the design.
    public var minimumParity: Int

    /// The design's starting point: 10%, at least 2 parity shards a block.
    public static let initial = FECPolicy(ratioPermille: 100, minimumParity: 2)
    /// No FEC at all (tests, or a NACK-only experiment).
    public static let none = FECPolicy(ratioPermille: 0, minimumParity: 0)

    public init(ratioPermille: Int, minimumParity: Int) {
        self.ratioPermille = ratioPermille
        self.minimumParity = minimumParity
    }

    public func parityShards(forDataShards k: Int) -> Int {
        max(minimumParity, (k * ratioPermille + 999) / 1000)
    }

    public func validate() throws(FECError) {
        guard ratioPermille >= 0, minimumParity >= 0 else { throw .invalidParameters("policy") }
        // A one-shard block must fit, or no frame can be laid out.
        guard 1 + parityShards(forDataShards: 1) <= VideoShardHeader.maxShardsPerBlock else {
            throw .invalidParameters("policy.parity")
        }
    }
}

/// How one frame payload splits into FEC blocks.
///
/// The payload is zero-padded to a whole number of `shardSize` shards. Those
/// are dealt into as few blocks as keep every block within 255 shards with its
/// parity. Blocks are as even as possible, larger first, so no block is left
/// with a sliver whose `minimumParity` costs more than it protects.
public struct VideoBlockLayout: Sendable, Hashable {
    public struct Block: Sendable, Hashable {
        /// Index of the block's first data shard among the frame's data shards.
        public var firstShard: Int
        public var dataShards: Int
        public var parityShards: Int

        public init(firstShard: Int, dataShards: Int, parityShards: Int) {
            self.firstShard = firstShard
            self.dataShards = dataShards
            self.parityShards = parityShards
        }
    }

    public let shardSize: Int
    public let totalDataShards: Int
    public let blocks: [Block]

    public var paddedLength: Int { totalDataShards * shardSize }
    public var totalParityShards: Int { blocks.reduce(0) { $0 + $1.parityShards } }

    public init(payloadLength: Int, shardSize: Int, policy: FECPolicy) throws(FECError) {
        try policy.validate()
        guard payloadLength >= 1 else { throw .invalidParameters("payloadLength") }
        guard shardSize >= 1 else { throw .invalidParameters("shardSize") }
        let total = (payloadLength + shardSize - 1) / shardSize
        let limit = VideoShardHeader.maxShardsPerBlock

        // parityShards(forDataShards:) never decreases as k grows, so the first
        // block count whose largest block fits is the smallest that works.
        var count = (total + limit - 1) / limit
        while true {
            let largest = (total + count - 1) / count
            if largest + policy.parityShards(forDataShards: largest) <= limit { break }
            count += 1
        }
        guard count <= Int(UInt8.max) else { throw .invalidParameters("blockCount") }

        var blocks: [Block] = []
        blocks.reserveCapacity(count)
        let base = total / count
        let larger = total % count
        var first = 0
        for index in 0..<count {
            let k = base + (index < larger ? 1 : 0)
            blocks.append(Block(firstShard: first, dataShards: k, parityShards: policy.parityShards(forDataShards: k)))
            first += k
        }
        self.shardSize = shardSize
        totalDataShards = total
        self.blocks = blocks
    }
}
