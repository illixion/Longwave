// StreamSim: the deterministic network simulator (NATIVE_V3_PROTOCOL.md
// section 7.5). Sessions run on virtual time over modelled links, so a test
// can put a host and a client in one process and make a failure reproducible
// from its seed. Test support only; nothing ships with it.

/// SplitMix64: small, seedable, and the same sequence on every platform.
public struct SimRandom: RandomNumberGenerator, Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    public mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// Uniform in `range`.
    public mutating func uniform(_ range: ClosedRange<UInt64>) -> UInt64 {
        range.lowerBound + next() % (range.upperBound - range.lowerBound + 1)
    }
}

/// One direction of a path: what happens to each datagram put on it.
public struct LinkModel: Sendable, Equatable {
    /// Fixed one-way delay, ns.
    public var propagationDelay: UInt64
    /// Extra delay drawn uniformly from 0...jitter per datagram, ns. Jitter
    /// larger than the spacing between datagrams reorders them.
    public var jitter: UInt64
    /// Bottleneck rate in bytes/s, 0 for unlimited. Datagrams queue behind it.
    public var rate: UInt64
    /// Bytes the bottleneck queue holds before tail drop.
    public var queueLimit: Int
    /// Independent loss probability per datagram.
    public var loss: Double
    /// Gilbert–Elliott burst loss, applied on top of `loss`.
    public var burst: BurstLoss?
    /// The headset's Wi-Fi stalls (section 7.5): delivery holds, then releases
    /// everything held at once.
    public var stalls: Stalls?

    public struct BurstLoss: Sendable, Equatable {
        public var enterBad: Double
        public var leaveBad: Double
        public var lossWhenBad: Double

        public init(enterBad: Double, leaveBad: Double, lossWhenBad: Double) {
            self.enterBad = enterBad
            self.leaveBad = leaveBad
            self.lossWhenBad = lossWhenBad
        }
    }

    public struct Stalls: Sendable, Equatable {
        /// Time between stall starts, ns.
        public var interval: ClosedRange<UInt64>
        /// How long each holds, ns.
        public var duration: ClosedRange<UInt64>

        public init(interval: ClosedRange<UInt64>, duration: ClosedRange<UInt64>) {
            self.interval = interval
            self.duration = duration
        }

        /// Fitted to the measured headset behaviour: 60–180 ms holds every 20–40 s.
        public static let headset = Stalls(interval: 20_000_000_000...40_000_000_000, duration: 60_000_000...180_000_000)
    }

    public init(propagationDelay: UInt64 = 1_000_000, jitter: UInt64 = 0, rate: UInt64 = 0, queueLimit: Int = 512 * 1024,
                loss: Double = 0, burst: BurstLoss? = nil, stalls: Stalls? = nil) {
        self.propagationDelay = propagationDelay
        self.jitter = jitter
        self.rate = rate
        self.queueLimit = queueLimit
        self.loss = loss
        self.burst = burst
        self.stalls = stalls
    }

    /// A clean LAN: 1 ms each way, a little jitter.
    public static let lan = LinkModel(propagationDelay: 1_000_000, jitter: 300_000)
}

/// A link's running state: the bottleneck queue, the burst-loss state and the
/// stall schedule.
public struct SimLink: Sendable {
    public var model: LinkModel
    public private(set) var delivered = 0
    public private(set) var lost = 0
    public private(set) var queueDrops = 0

    private var random: SimRandom
    private var bottleneckFreeAt: UInt64 = 0
    private var inBadState = false
    private var stall: (start: UInt64, end: UInt64)?

    public init(model: LinkModel, seed: UInt64) {
        self.model = model
        random = SimRandom(seed: seed)
    }

    /// When a datagram of `size` bytes sent at `now` arrives, or nil if lost.
    public mutating func transmit(size: Int, now: UInt64) -> UInt64? {
        if let burst = model.burst {
            if inBadState {
                if random.unit() < burst.leaveBad { inBadState = false }
            } else if random.unit() < burst.enterBad {
                inBadState = true
            }
            if inBadState, random.unit() < burst.lossWhenBad {
                lost += 1
                return nil
            }
        }
        if model.loss > 0, random.unit() < model.loss {
            lost += 1
            return nil
        }
        var departure = now
        if model.rate > 0 {
            let start = max(now, bottleneckFreeAt)
            let queued = Double(start - now) * Double(model.rate) / 1e9
            guard Int(queued) + size <= model.queueLimit else {
                queueDrops += 1
                return nil
            }
            bottleneckFreeAt = start + UInt64(Double(size) / Double(model.rate) * 1e9)
            departure = bottleneckFreeAt
        }
        var arrival = departure + model.propagationDelay + (model.jitter > 0 ? random.uniform(0...model.jitter) : 0)
        if let stalls = model.stalls {
            if stall == nil { stall = schedule(after: 0, stalls) }
            // Stalls that ended before this arrival are history.
            while let current = stall, current.end <= arrival { stall = schedule(after: current.end, stalls) }
            if let current = stall, arrival >= current.start {
                // Held by the stall; released together when it ends.
                arrival = current.end
            }
        }
        delivered += 1
        return arrival
    }

    private mutating func schedule(after time: UInt64, _ stalls: LinkModel.Stalls) -> (start: UInt64, end: UInt64) {
        let start = time + random.uniform(stalls.interval)
        return (start, start + random.uniform(stalls.duration))
    }
}

/// Datagrams in flight, delivered in time order (ties in send order).
public struct SimNetwork<Endpoint: Hashable & Sendable>: Sendable {
    public struct Delivery: Sendable {
        public var time: UInt64
        public var from: Endpoint
        public var to: Endpoint
        public var bytes: [UInt8]
        fileprivate var order: UInt64
    }

    private var links: [Pair: SimLink] = [:]
    private var heap: [Delivery] = []
    private var sendOrder: UInt64 = 0

    private struct Pair: Hashable, Sendable {
        var from: Endpoint
        var to: Endpoint
    }

    public init() {}

    public mutating func connect(_ from: Endpoint, to: Endpoint, model: LinkModel, seed: UInt64) {
        links[Pair(from: from, to: to)] = SimLink(model: model, seed: seed)
    }

    public func link(_ from: Endpoint, to: Endpoint) -> SimLink? {
        links[Pair(from: from, to: to)]
    }

    public mutating func setModel(_ model: LinkModel, from: Endpoint, to: Endpoint) {
        links[Pair(from: from, to: to)]?.model = model
    }

    /// Puts a datagram on the link `from` → `to`. No link means it vanishes.
    public mutating func send(_ bytes: [UInt8], from: Endpoint, to: Endpoint, now: UInt64) {
        let pair = Pair(from: from, to: to)
        guard var link = links[pair] else { return }
        let arrival = link.transmit(size: bytes.count, now: now)
        links[pair] = link
        guard let arrival else { return }
        push(Delivery(time: arrival, from: from, to: to, bytes: bytes, order: sendOrder))
        sendOrder += 1
    }

    public var nextDeliveryTime: UInt64? { heap.first?.time }

    /// The next delivery due by `now`, if any.
    public mutating func popDue(now: UInt64) -> Delivery? {
        guard let first = heap.first, first.time <= now else { return nil }
        let last = heap.removeLast()
        if !heap.isEmpty {
            heap[0] = last
            siftDown(0)
        }
        return first
    }

    private static func before(_ a: Delivery, _ b: Delivery) -> Bool {
        a.time != b.time ? a.time < b.time : a.order < b.order
    }

    private mutating func push(_ delivery: Delivery) {
        heap.append(delivery)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.before(heap[child], heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ start: Int) {
        var parent = start
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < heap.count, Self.before(heap[left], heap[smallest]) { smallest = left }
            if right < heap.count, Self.before(heap[right], heap[smallest]) { smallest = right }
            guard smallest != parent else { return }
            heap.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
