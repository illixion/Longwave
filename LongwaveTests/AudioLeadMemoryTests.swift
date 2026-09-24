import XCTest
@testable import Longwave

/// The remembered lead is what saves each session from paying for its first
/// stall with pops, so it has to come back for the same link and only that
/// link, and must stop applying once it is old enough to describe a
/// different network.
final class AudioLeadMemoryTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "AudioLeadMemoryTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testRoundTripsPerHostPortAndTransport() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        AudioLeadMemory.remember(0.215, host: "Mac.local", port: 4855, lowLatency: true, defaults: defaults, now: now)
        XCTAssertEqual(
            AudioLeadMemory.lead(host: "mac.local", port: 4855, lowLatency: true, defaults: defaults, now: now),
            0.215, "host names compare case-insensitively"
        )
        XCTAssertNil(AudioLeadMemory.lead(host: "mac.local", port: 4855, lowLatency: false, defaults: defaults, now: now))
        XCTAssertNil(AudioLeadMemory.lead(host: "mac.local", port: 4856, lowLatency: true, defaults: defaults, now: now))
        XCTAssertNil(AudioLeadMemory.lead(host: "other.local", port: 4855, lowLatency: true, defaults: defaults, now: now))
    }

    func testLaterSessionReplacesEarlierOne() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        AudioLeadMemory.remember(0.215, host: "mac", port: 1, lowLatency: true, defaults: defaults, now: now)
        AudioLeadMemory.remember(0.040, host: "mac", port: 1, lowLatency: true, defaults: defaults, now: now)
        XCTAssertEqual(AudioLeadMemory.lead(host: "mac", port: 1, lowLatency: true, defaults: defaults, now: now), 0.040,
                       "a link that improved is remembered as improved")
    }

    func testStaleLeadIsIgnored() {
        let saved = Date(timeIntervalSince1970: 1_000_000)
        AudioLeadMemory.remember(0.2, host: "mac", port: 1, lowLatency: true, defaults: defaults, now: saved)
        let later = saved.addingTimeInterval(AudioLeadMemory.maximumAge + 1)
        XCTAssertNil(AudioLeadMemory.lead(host: "mac", port: 1, lowLatency: true, defaults: defaults, now: later))
    }

    func testRejectsNonsense() {
        AudioLeadMemory.remember(.nan, host: "mac", port: 1, lowLatency: true, defaults: defaults)
        AudioLeadMemory.remember(0, host: "mac", port: 1, lowLatency: true, defaults: defaults)
        XCTAssertNil(AudioLeadMemory.lead(host: "mac", port: 1, lowLatency: true, defaults: defaults))
    }
}
