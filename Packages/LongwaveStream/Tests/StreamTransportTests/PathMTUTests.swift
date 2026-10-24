import StreamSim
@testable import StreamTransport
import StreamWire
import XCTest

private let ms: UInt64 = 1_000_000

final class PathMTUSearchTests: XCTestCase {
    /// Drives a search against a path that takes `limit`, acknowledging a
    /// probe 2 ms after it goes. Returns the sizes probed.
    @discardableResult
    private func drive(_ search: inout PathMTUSearch, limit: () -> Int, from start: UInt64, for duration: UInt64) -> [Int] {
        var now = start
        var probed: [Int] = []
        while now < start + duration {
            if let size = search.nextProbe(now: now) {
                probed.append(size)
                if size <= limit() { search.acknowledged(size, now: now + 2 * ms) }
            }
            now = max(now + ms, min(search.nextWakeTime ?? .max, start + duration))
        }
        return probed
    }

    func testTheCeilingIsTriedFirst() {
        var search = PathMTUSearch(base: 1_200, ceiling: 1_452, now: 0)
        XCTAssertEqual(search.current, 1_200)
        let probed = drive(&search, limit: { 1_500 }, from: 0, for: 100 * ms)
        XCTAssertEqual(probed, [1_452])
        XCTAssertEqual(search.current, 1_452)
        XCTAssertEqual(search.phase, .complete)
    }

    func testBisectsTowardsASmallerPath() {
        // Tailscale over IPv4: 1252 bytes of UDP payload.
        var search = PathMTUSearch(base: 1_200, ceiling: 1_452, now: 0)
        let probed = drive(&search, limit: { 1_252 }, from: 0, for: 30_000 * ms)
        XCTAssertEqual(search.phase, .complete)
        XCTAssertLessThanOrEqual(search.current, 1_252)
        XCTAssertGreaterThan(search.current, 1_252 - PathMTUSearch.granularity)
        XCTAssertEqual(probed.prefix(3), [1_452, 1_452, 1_452], "three tries before giving a size up")
    }

    func testABlackHoleFallsBackToTheBaseAndSearchesAgain() {
        var search = PathMTUSearch(base: 1_200, ceiling: 1_452, now: 0)
        var limit = 1_500
        drive(&search, limit: { limit }, from: 0, for: 100 * ms)
        XCTAssertEqual(search.current, 1_452)

        // The path shrinks: the next confirmations are lost.
        limit = 1_300
        drive(&search, limit: { limit }, from: 100 * ms, for: 13_100 * ms)
        XCTAssertEqual(search.blackHoles, 1)
        XCTAssertEqual(search.current, 1_200, "media drops to the base at once")
        drive(&search, limit: { limit }, from: 13_200 * ms, for: 20_000 * ms)
        XCTAssertLessThanOrEqual(search.current, 1_300)
        XCTAssertGreaterThan(search.current, 1_300 - PathMTUSearch.granularity)
    }

    func testRaisesAfterTenMinutes() {
        var search = PathMTUSearch(base: 1_200, ceiling: 1_452, now: 0)
        var limit = 1_300
        drive(&search, limit: { limit }, from: 0, for: 30_000 * ms)
        let found = search.current
        limit = 1_500
        drive(&search, limit: { limit }, from: 30_000 * ms, for: 500_000 * ms)
        XCTAssertEqual(search.current, found, "no growth before the raise timer")
        drive(&search, limit: { limit }, from: 530_000 * ms, for: 100_000 * ms)
        XCTAssertEqual(search.current, 1_452)
    }

    func testNothingToProbeAtTheBase() {
        var search = PathMTUSearch(base: 1_200, ceiling: 1_200, now: 0)
        XCTAssertEqual(search.phase, .complete)
        XCTAssertNil(search.nextProbe(now: 0))
        XCTAssertNil(search.nextWakeTime)
    }
}

final class PathMTUSimulationTests: XCTestCase {
    private func connected(down: LinkModel, up: LinkModel = .lan) throws -> (Harness, UInt32) {
        let harness = Harness(up: up, down: down)
        harness.run(for: 50 * ms)
        let index = try XCTUnwrap(harness.hostIndex)
        harness.client!.setPathCeiling(1_452, now: harness.now)
        _ = harness.host.withSession(index) { $0.setPathCeiling(1_452, now: harness.hostNow) }
        return (harness, index)
    }

    /// Each side finds its own direction's size: 1452 up a clean LAN, about
    /// 1400 down a path that takes no more. Media then seals at that size.
    func testEachDirectionFindsItsOwnSize() throws {
        var down = LinkModel.lan
        down.maxDatagram = 1_400
        let (harness, index) = try connected(down: down)
        harness.run(for: 12_000 * ms)
        XCTAssertEqual(harness.client!.udpPayload, 1_452)
        let host = try XCTUnwrap(harness.host.sessions[index]?.session)
        XCTAssertLessThanOrEqual(host.udpPayload, 1_400)
        XCTAssertGreaterThan(host.udpPayload, 1_400 - PathMTUSearch.granularity)

        // A full-size shard at the found size arrives.
        let shard = DatagramLayout.videoShardDataCapacity(udpPayload: host.udpPayload)
        let header = VideoShardHeader(streamID: 1, frameNumber: 0, captureTime: 0, flags: [.key, .lastBlock], block: 0,
                                      blockCount: 1, shardIndex: 0, dataShards: 1, parityShards: 0, referenceDistance: 0)
        let datagram = try XCTUnwrap(try harness.host.withSession(index) {
            try $0.sealVideo(header, data: [UInt8](repeating: 7, count: shard), now: harness.hostNow)
        })
        XCTAssertLessThanOrEqual(datagram.count, host.udpPayload)
        XCTAssertGreaterThan(datagram.count, host.udpPayload - 2)
        harness.network.send(datagram, from: .host, to: .client, now: harness.now)
        harness.run(for: 10 * ms)
        XCTAssertTrue(harness.clientEvents.contains { if case .video(_, let data) = $0 { data.count == shard } else { false } })
    }

    /// The path shrinks under a running session (onto a VPN): confirmation
    /// probes go missing, media drops to 1200 within a confirmation interval
    /// and three probe timeouts, and the search settles on the new size. The
    /// lost probes are not loss to the rate controller.
    func testBlackHoleRecovery() throws {
        let (harness, index) = try connected(down: .lan)
        harness.run(for: 1_000 * ms)
        XCTAssertEqual(harness.host.sessions[index]?.session.udpPayload, 1_452)
        var vpn = LinkModel.lan
        vpn.maxDatagram = 1_252
        harness.network.setModel(vpn, from: .host, to: .client)
        harness.run(for: 14_000 * ms)
        let session = try XCTUnwrap(harness.host.sessions[index]?.session)
        XCTAssertEqual(session.pathMTU?.blackHoles, 1)
        harness.run(for: 20_000 * ms)
        let settled = try XCTUnwrap(harness.host.sessions[index]?.session)
        XCTAssertLessThanOrEqual(settled.udpPayload, 1_252)
        XCTAssertGreaterThan(settled.udpPayload, 1_252 - PathMTUSearch.granularity)
        XCTAssertGreaterThan(harness.network.link(.host, to: .client)?.oversizeDrops ?? 0, 3)
        XCTAssertNil(harness.host.sessions[index]?.session.closure, "small traffic never used the probed size")

        var controller = GCCRateController()
        for event in harness.hostReceivedEvents {
            if case .feedback(_, let results) = event { controller.onFeedback(results, now: harness.hostNow, rtt: 2 * ms) }
        }
        XCTAssertEqual(controller.smoothedLoss, 0, accuracy: 0.001)
    }

    /// A roaming client may now be on a different path: the host searches again.
    func testRoamingRestartsTheHostSearch() throws {
        let (harness, index) = try connected(down: .lan)
        harness.run(for: 1_000 * ms)
        XCTAssertEqual(harness.host.sessions[index]?.session.udpPayload, 1_452)
        var narrow = LinkModel.lan
        narrow.maxDatagram = 1_300
        harness.network.setModel(narrow, from: .host, to: .clientRoamed)
        harness.clientNode = .clientRoamed
        try harness.client!.send(.keyDown, body: [1], on: .input)
        harness.run(for: 20 * ms)
        XCTAssertEqual(harness.host.sessions[index]?.session.udpPayload, 1_200, "unconfirmed on the new path")
        harness.run(for: 20_000 * ms)
        let size = try XCTUnwrap(harness.host.sessions[index]?.session.udpPayload)
        XCTAssertLessThanOrEqual(size, 1_300)
        XCTAssertGreaterThan(size, 1_300 - PathMTUSearch.granularity)
    }
}
