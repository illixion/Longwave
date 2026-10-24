import StreamWire

/// The receiver's side of section 6.1: records every authenticated packet and
/// turns them into FEEDBACK reports every 20 ms, or at once after a loss.
///
/// Each packet number is reported once. New packets are reported as one
/// range from just above the last reported number, so a gap is a loss so far. A
/// late packet (below that point, so already reported lost) goes in a report of
/// its own run, never one that would re-mark its neighbours.
public struct FeedbackGenerator: Sendable {
    public static let defaultInterval: UInt64 = 20_000_000

    public let interval: UInt64
    /// Encoded size a report must stay under, so it fits a datagram with room
    /// for other frames.
    public let maxReportBytes: Int
    public private(set) var reportSequence: UInt16 = 0

    private var pending: [(number: UInt64, arrival: UInt64, ecn: ECNMark)] = []
    private var highestReported: UInt64?
    private var highestSeen: UInt64?
    private var lastReportAt: UInt64?
    private var lossSeen = false

    public init(interval: UInt64 = FeedbackGenerator.defaultInterval, maxReportBytes: Int = 900) {
        self.interval = interval
        self.maxReportBytes = maxReportBytes
    }

    /// Records one packet. `arrival` is local monotonic ns.
    public mutating func record(packetNumber: UInt64, arrival: UInt64, ecn: ECNMark = .notECT) {
        if let highestSeen, packetNumber > highestSeen + 1 { lossSeen = true }
        highestSeen = max(highestSeen ?? packetNumber, packetNumber)
        pending.append((packetNumber, arrival, ecn))
    }

    public var hasPending: Bool { !pending.isEmpty }

    /// When the next report is due, if anything is pending.
    public var nextReportTime: UInt64? {
        guard let first = pending.first else { return nil }
        if lossSeen { return first.arrival }
        return (lastReportAt ?? first.arrival) + interval
    }

    /// Reports for everything pending, with `streams` attached to the first.
    public mutating func makeReports(now: UInt64, streams: [Feedback.StreamStatus] = []) -> [Feedback] {
        guard !pending.isEmpty else { return [] }
        let sorted = pending.sorted { $0.number < $1.number }
        pending.removeAll(keepingCapacity: true)
        lossSeen = false
        lastReportAt = now

        // Late packets: consecutive runs below the reported point, one report each.
        var groups: [[(number: UInt64, arrival: UInt64, ecn: ECNMark)]] = []
        var fresh: [(number: UInt64, arrival: UInt64, ecn: ECNMark)] = []
        for packet in sorted {
            if let highestReported, packet.number <= highestReported {
                if let last = groups.last?.last, last.number + 1 == packet.number {
                    groups[groups.count - 1].append(packet)
                } else {
                    groups.append([packet])
                }
            } else {
                fresh.append(packet)
            }
        }
        var reports: [Feedback] = []
        for group in groups {
            reports += split(group.map { Feedback.Packet(packetNumber: $0.number, arrival: $0.arrival / 1_000, ecn: $0.ecn) })
        }
        if let first = fresh.first {
            let start = highestReported.map { $0 + 1 } ?? first.number
            var byNumber: [UInt64: (arrival: UInt64, ecn: ECNMark)] = [:]
            for packet in fresh { byNumber[packet.number] = (packet.arrival, packet.ecn) }
            let last = fresh.last!.number
            var packets: [Feedback.Packet] = []
            var number = start
            while number <= last {
                if let hit = byNumber[number] {
                    packets.append(.init(packetNumber: number, arrival: hit.arrival / 1_000, ecn: hit.ecn))
                } else {
                    packets.append(.init(packetNumber: number, arrival: nil))
                }
                number += 1
            }
            reports += split(packets)
            highestReported = last
        }
        if !streams.isEmpty, !reports.isEmpty { reports[0].streams = streams }
        return reports
    }

    /// Cuts a run of packets into reports that respect every encoding limit.
    private mutating func split(_ packets: [Feedback.Packet]) -> [Feedback] {
        var reports: [Feedback] = []
        var current: [Feedback.Packet] = []
        var reference: UInt64?
        var previous: UInt64?
        var estimate = 0
        func flush() {
            guard !current.isEmpty else { return }
            reports.append(Feedback(reportSequence: reportSequence, referenceTime: reference ?? 0, packets: current))
            reportSequence &+= 1
            current = []
            reference = nil
            previous = nil
            estimate = 0
        }
        for packet in packets {
            if let arrival = packet.arrival {
                let base = previous ?? arrival
                let delta = arrival >= base ? arrival - base : base - arrival
                if delta > UInt64(Feedback.maxDelta) || estimate + 4 > maxReportBytes - 40
                    || current.count == Feedback.maxPackets {
                    flush()
                }
                if reference == nil { reference = arrival }
                previous = arrival
                estimate += 3
            } else if current.count == Feedback.maxPackets {
                flush()
            }
            estimate += 1
            current.append(packet)
        }
        flush()
        return reports
    }
}

/// The sender's record of what it sent, to turn FEEDBACK into per-packet
/// results for the rate controller (section 6.2).
public struct SentPacketLog: Sendable {
    public struct Entry: Sendable, Equatable {
        public var packetNumber: UInt64
        public var sendTime: UInt64
        public var size: Int
        public var isMedia: Bool
        /// The probe burst this padding belonged to.
        public var probeCluster: UInt32? = nil
        /// An earlier report said it was lost; this result is its late arrival.
        public var reportedLost = false
    }

    public struct Result: Sendable, Equatable {
        public var packet: Entry
        /// Receiver µs, nil if reported lost.
        public var arrival: UInt64?
        public var ecn: ECNMark
    }

    public let capacity: Int
    private var entries: [UInt64: Entry] = [:]
    private var order: [UInt64] = []
    private var orderStart = 0

    public init(capacity: Int = 65_536) {
        self.capacity = capacity
    }

    public var count: Int { entries.count }

    public mutating func record(packetNumber: UInt64, sendTime: UInt64, size: Int, isMedia: Bool,
                                probeCluster: UInt32? = nil) {
        entries[packetNumber] = Entry(packetNumber: packetNumber, sendTime: sendTime, size: size, isMedia: isMedia,
                                      probeCluster: probeCluster)
        order.append(packetNumber)
        while entries.count > capacity, orderStart < order.count {
            entries[order[orderStart]] = nil
            orderStart += 1
        }
        if orderStart > 4096, orderStart * 2 > order.count {
            order.removeFirst(orderStart)
            orderStart = 0
        }
    }

    /// Results for the packets a report covers that this log still holds. A
    /// packet reported received is forgotten; one reported lost is kept, in
    /// case a late report says it arrived after all.
    public mutating func apply(_ feedback: Feedback) -> [Result] {
        var results: [Result] = []
        for packet in feedback.packets {
            guard let entry = entries[packet.packetNumber] else { continue }
            results.append(Result(packet: entry, arrival: packet.arrival, ecn: packet.ecn))
            if packet.arrival != nil {
                entries[packet.packetNumber] = nil
            } else {
                entries[packet.packetNumber]?.reportedLost = true
            }
        }
        return results
    }
}
