import Foundation
import StreamWire
import XCTest

/// Hostile-input tests: seeded mutations of valid encodings fed to every
/// decoder. A trap anywhere crashes the test process, so finishing is the
/// "no crash" assertion; every input that does decode must round-trip.
///
/// Iterations per corpus entry default to 2,000 (about 1.6 million decode
/// attempts); set STREAMWIRE_FUZZ_ITERATIONS for a longer soak and
/// STREAMWIRE_FUZZ_SEED to reproduce a failure.
final class FuzzTests: XCTestCase {
    private var iterations: Int {
        ProcessInfo.processInfo.environment["STREAMWIRE_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 2000
    }

    private var seed: UInt64 {
        ProcessInfo.processInfo.environment["STREAMWIRE_FUZZ_SEED"].flatMap { UInt64($0) } ?? 0x5EED_1234
    }

    // MARK: Corpus

    private func corpus() throws -> [[UInt8]] {
        var entries: [[UInt8]] = [
            try VideoShardHeaderTests.parity.encoded(),
            try AudioShardHeader(channelID: 3, fecIndex: 1, codec: .opus, firstSample: 480, frameSamples: 240, fecGroup: 9).encoded(),
            FormatDescriptionTests.pcvrBytes, FormatDescriptionTests.gameBytes, FormatDescriptionTests.depthBytes,
            try Fixtures.depthFormat.encodedMessage(),
            try CapabilitySet.known.encoded(),
            try StateSnapshot(sequence: 1, hostTime: 2, payload: .headPose(Fixtures.headPose)).encoded(),
            try StateSnapshot(source: 3, sequence: 1, hostTime: 2, payload: .gamepad(Fixtures.gamepad)).encoded(),
            try StateSnapshot(sequence: 1, hostTime: 2, payload: .pointerAbsolute(PointerPosition(streamID: 4, x: 5, y: 6))).encoded(),
            SideDataTests.renderPoseItem + SideDataTests.foveationItem + SideDataTests.depthRangeItem,
            try FramePayload.encode(sideData: SideData(renderPose: Fixtures.renderPose, foveation: Fixtures.foveation),
                                    accessUnit: [0, 0, 0, 3, 0x26, 1, 0xAF]) + [0, 0, 0],
        ]
        entries += InputEventTests.vectors.map(\.1)
        entries.append(InputEventTests.vectors.flatMap(\.1)) // a whole input stream
        // A datagram body: control bytes, a video shard, padding.
        var datagram = WireWriter()
        try datagram.appendFrame(.ack, body: [1, 2, 3])
        try datagram.appendVideoShard(VideoShardHeaderTests.parity, data: [UInt8](repeating: 0x5A, count: 40))
        try datagram.appendFrame(.state, body: try StateSnapshot(sequence: 1, hostTime: 2,
                                                                 payload: .headPose(Fixtures.headPose)).encoded())
        datagram.appendPadding(5)
        entries.append(datagram.bytes)
        return entries
    }

    // MARK: Decoders under test

    /// Decodes `input`; if that succeeds, checks re-encoding is stable.
    /// Returns whether it decoded.
    private func check<T: Equatable>(_ input: [UInt8], _ name: String,
                                     decode: ([UInt8]) throws -> T?,
                                     encode: (T) throws -> [UInt8]) -> Bool {
        let value: T
        do {
            guard let decoded = try decode(input) else { return false }
            value = decoded
        } catch {
            return false // rejected: the expected outcome for most mutations
        }
        do {
            let first = try encode(value)
            let again = try decode(first)
            XCTAssertEqual(again, value, "\(name): value changed on round trip of \(hexString(input))")
            if let again {
                XCTAssertEqual(try encode(again), first, "\(name): encoding not stable for \(hexString(input))")
            }
        } catch {
            XCTFail("\(name): decoded \(hexString(input)) but could not re-encode: \(error)")
        }
        return true
    }

    /// Runs every decoder over one input; returns the names that accepted it.
    private func exerciseAll(_ input: [UInt8]) -> [String] {
        var accepted: [String] = []
        func note(_ name: String, _ ok: Bool) { if ok { accepted.append(name) } }

        note("video", check(input, "video", decode: { (b) in try VideoShardHeader(decoding: b) },
                            encode: { (v) in try v.encoded() }))
        note("audio", check(input, "audio", decode: { (b) in try AudioShardHeader(decoding: b) },
                            encode: { (v) in try v.encoded() }))
        note("format", check(input, "format", decode: { (b) in try FormatDescription(decoding: b) },
                             encode: { (v) in try v.encoded() }))
        note("capabilities", check(input, "capabilities", decode: { (b) in try CapabilitySet(decoding: b) },
                                   encode: { (v) in try v.encoded() }))
        note("state", check(input, "state", decode: { (b) in try StateSnapshot(frameBody: b) },
                            encode: { (v) in try v.encoded() }))
        note("sideData", check(input, "sideData", decode: { (b) throws -> SideData? in
            var reader = WireReader(b)
            return try SideData(items: &reader)
        }, encode: { (v) in
            var writer = WireWriter()
            try v.encodeItems(to: &writer)
            return writer.bytes
        }))
        note("payload", check(input, "payload", decode: { (b) throws -> FramePayload.Decoded? in
            try FramePayload.decode(b) // slice equality is by content
        }, encode: { (v) in try FramePayload.encode(sideData: v.sideData, accessUnit: v.accessUnit) }))
        note("frames", check(input, "frames", decode: { (b) throws -> [FrameValue]? in
            try FrameReader.frames(in: b).map { (frame) throws -> FrameValue in
                // Media bodies must also survive their header parsers.
                if frame.type == .video { _ = try? VideoShardHeader.split(frame.body) }
                if frame.type == .audio { _ = try? AudioShardHeader.split(frame.body) }
                if frame.type == .state { _ = try? StateSnapshot(frameBody: frame.body) }
                return FrameValue(type: frame.type, body: Array(frame.body))
            }
        }, encode: { (frames) in
            var writer = WireWriter()
            for frame in frames { try writer.appendFrame(frame.type, body: frame.body) }
            return writer.bytes
        }))
        note("messages", check(input, "messages", decode: { (b) throws -> [MessageValue]? in
            try MessageFraming.messages(in: b).map { (message) throws -> MessageValue in
                if let input = try? TimedInputEvent(message: message) {
                    return .input(input)
                }
                if let host = try? HostInputEvent(message: message) {
                    return .host(host)
                }
                if message.type == .formatDescription, let format = try? FormatDescription(decoding: message.body) {
                    return .format(format)
                }
                return .raw(message.type.rawValue, Array(message.body))
            }
        }, encode: { (messages) in
            var bytes: [UInt8] = []
            for message in messages {
                switch message {
                case .input(let event): bytes += try event.encodedMessage()
                case .host(let event): bytes += try event.encodedMessage()
                case .format(let format): bytes += try format.encodedMessage()
                case .raw(let type, let body): bytes += try MessageFraming.encode(MessageType(rawValue: type), body: body)
                }
            }
            return bytes
        }))
        return accepted
    }

    // MARK: Tests

    func testCorpusDecodesAndRoundTrips() throws {
        for entry in try corpus() {
            XCTAssertFalse(exerciseAll(entry).isEmpty, "corpus entry rejected by every decoder: \(hexString(entry))")
        }
    }

    func testMutatedInputsNeverTrapAndRoundTripWhenAccepted() throws {
        let entries = try corpus()
        var rng = SplitMix64(seed: seed)
        var acceptedCounts: [String: Int] = [:]
        var total = 0
        for entry in entries {
            for _ in 0..<iterations {
                let other = entries[Int(rng.next() % UInt64(entries.count))]
                let input = mutate(entry, splice: other, rng: &rng)
                for name in exerciseAll(input) { acceptedCounts[name, default: 0] += 1 }
                total += 1
            }
        }
        // The mutations must reach past the first validation check, or this
        // test would prove nothing about the deeper parsers.
        for name in ["video", "audio", "format", "state", "sideData", "payload", "frames", "messages", "capabilities"] {
            XCTAssertGreaterThan(acceptedCounts[name, default: 0], 0, "no mutated input ever decoded as \(name)")
        }
        print("fuzz: \(total) inputs x 9 decoders, seed \(seed); accepted per decoder: \(acceptedCounts.sorted { $0.key < $1.key })")
    }

    func testRandomBytesNeverTrap() {
        var rng = SplitMix64(seed: seed ^ 0xABCD)
        for _ in 0..<(iterations * 10) {
            let length = Int(rng.next() % 300)
            let input = (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            _ = exerciseAll(input)
        }
    }

    /// Generated valid values (not mutated bytes) must all round-trip.
    func testRandomValidValuesRoundTrip() throws {
        var rng = SplitMix64(seed: seed ^ 0x1111)
        for _ in 0..<(iterations * 5) {
            let header = randomVideoHeader(&rng)
            XCTAssertEqual(try VideoShardHeader(decoding: try header.encoded()), header)

            let audio = AudioShardHeader(channelID: UInt16(truncatingIfNeeded: rng.next()), fecIndex: UInt8(rng.next() % 4),
                                         discontinuity: rng.next() & 1 == 0, inBandFEC: rng.next() & 1 == 0,
                                         codec: rng.next() & 1 == 0 ? .opus : .pcm24, firstSample: rng.next(),
                                         frameSamples: UInt16(1 + rng.next() % 5760), fecGroup: UInt16(truncatingIfNeeded: rng.next()))
            XCTAssertEqual(try AudioShardHeader(decoding: try audio.encoded()), audio)

            var pose = Fixtures.headPose
            pose.displayTime = rng.next()
            pose.head.position = Vector3(randomFloat(&rng), randomFloat(&rng), randomFloat(&rng))
            pose.head.orientation = randomRotation(&rng)
            if rng.next() & 1 == 0 { pose.gaze = nil }
            let snapshot = StateSnapshot(sequence: UInt32(truncatingIfNeeded: rng.next()), hostTime: rng.next(), payload: .headPose(pose))
            XCTAssertEqual(try StateSnapshot(frameBody: try snapshot.encoded()), snapshot)

            let caps = CapabilitySet((0..<8).map { _ in Capability(rawValue: UInt8(truncatingIfNeeded: rng.next())) })
            XCTAssertEqual(try CapabilitySet(decoding: try caps.encoded()), caps)
        }
    }

    // MARK: Generators

    private func mutate(_ base: [UInt8], splice: [UInt8], rng: inout SplitMix64) -> [UInt8] {
        var bytes = base
        let rounds = 1 + Int(rng.next() % 3)
        for _ in 0..<rounds {
            let position = bytes.isEmpty ? 0 : Int(rng.next() % UInt64(bytes.count))
            switch rng.next() % 8 {
            case 0 where !bytes.isEmpty: // flip a bit
                bytes[position] ^= 1 << UInt8(rng.next() % 8)
            case 1 where !bytes.isEmpty: // an interesting byte
                bytes[position] = [0x00, 0x01, 0x7F, 0x80, 0xFF, 0xFE, 0x40, 0x3F][Int(rng.next() % 8)]
            case 2: // truncate
                bytes = Array(bytes.prefix(position))
            case 3: // insert random bytes
                let count = 1 + Int(rng.next() % 8)
                bytes.insert(contentsOf: (0..<count).map { _ in UInt8(truncatingIfNeeded: rng.next()) }, at: position)
            case 4 where !bytes.isEmpty: // delete a range
                let end = min(bytes.count, position + 1 + Int(rng.next() % 8))
                bytes.removeSubrange(position..<end)
            case 5 where !bytes.isEmpty: // duplicate a range
                let end = min(bytes.count, position + 1 + Int(rng.next() % 16))
                bytes.insert(contentsOf: bytes[position..<end], at: position)
            case 6: // splice in part of another entry
                let start = splice.isEmpty ? 0 : Int(rng.next() % UInt64(splice.count))
                bytes = Array(bytes.prefix(position)) + splice[start...]
            default: // a random 16- or 32-bit value somewhere (lengths, counts)
                guard bytes.count >= 4 else { break }
                let at = Int(rng.next() % UInt64(bytes.count - 3))
                let value = rng.next()
                for offset in 0..<(rng.next() & 1 == 0 ? 2 : 4) { bytes[at + offset] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(offset))) }
            }
        }
        return bytes
    }

    private func randomVideoHeader(_ rng: inout SplitMix64) -> VideoShardHeader {
        let blockCount = UInt8(1 + rng.next() % 8)
        let block = UInt8(rng.next() % UInt64(blockCount))
        let dataShards = UInt8(1 + rng.next() % 200)
        let parityShards = UInt8(rng.next() % UInt64(256 - Int(dataShards)))
        let key = rng.next() % 4 == 0
        var flags: VideoShardFlags = key ? [.key] : []
        if block == blockCount - 1 { flags.insert(.lastBlock) }
        if rng.next() & 1 == 0 { flags.insert(rng.next() & 1 == 0 ? .discardable : .longTermReference) }
        if rng.next() & 1 == 0 { flags.insert(.recovery) }
        return VideoShardHeader(streamID: UInt32(truncatingIfNeeded: rng.next()), frameNumber: UInt32(truncatingIfNeeded: rng.next()),
                                captureTime: rng.next(), flags: flags, block: block, blockCount: blockCount,
                                shardIndex: UInt8(rng.next() % UInt64(Int(dataShards) + Int(parityShards))),
                                dataShards: dataShards, parityShards: parityShards,
                                referenceDistance: key ? 0 : UInt16(truncatingIfNeeded: rng.next()))
    }

    private func randomFloat(_ rng: inout SplitMix64) -> Float {
        Float(Int64(bitPattern: rng.next()) % 20_000) / 1000
    }

    private func randomRotation(_ rng: inout SplitMix64) -> Quaternion {
        var q = (randomFloat(&rng), randomFloat(&rng), randomFloat(&rng), randomFloat(&rng) + 0.5)
        let norm = (q.0 * q.0 + q.1 * q.1 + q.2 * q.2 + q.3 * q.3).squareRoot()
        q = (q.0 / norm, q.1 / norm, q.2 / norm, q.3 / norm)
        return Quaternion(x: q.0, y: q.1, z: q.2, w: q.3)
    }
}

// Value wrappers that compare by content, not by slice indices.

private struct FrameValue: Equatable {
    var type: FrameType
    var body: [UInt8]
}

private enum MessageValue: Equatable {
    case input(TimedInputEvent)
    case host(HostInputEvent)
    case format(FormatDescription)
    case raw(UInt8, [UInt8])
}
