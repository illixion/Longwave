import XCTest
@testable import Longwave

/// The pinned web panels' settings: what an address becomes, the Twitch chat
/// shortcut, and that a saved list (including a hand-moved offset) reads back.
/// Placing and pausing are RAVEEngine's RAVEPanel rules, tested there.
///
/// Gated with the feature: pinned panels exist only in the PCVR space.
#if FOVEATED_ENABLED
final class PCVRWebPanelsTests: XCTestCase {
    func testAddressWithoutSchemeGetsHTTPS() {
        XCTAssertEqual(PCVRWebPanelConfig(address: "example.com/chat").url?.absoluteString,
                       "https://example.com/chat")
        XCTAssertEqual(PCVRWebPanelConfig(address: " http://example.com ").url?.absoluteString,
                       "http://example.com")
        XCTAssertNil(PCVRWebPanelConfig(address: "   ").url)
    }

    func testTwitchChatIsThePopOutForTheChannel() {
        XCTAssertEqual(PCVRWebPanelConfig.twitchChat(channel: " SomeStreamer "),
                       "https://www.twitch.tv/popout/somestreamer/chat?popout=")
    }

    func testSavedPanelsReadBack() throws {
        let suite = "PCVRWebPanelsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var chat = PCVRWebPanelConfig(address: PCVRWebPanelConfig.twitchChat(channel: "a"))
        chat.offset = [0.01, 0.05, -0.2]
        chat.opacity = 0.6
        let page = PCVRWebPanelConfig(address: "example.com", mount: .view, enabled: false)
        defaults.set(try JSONEncoder().encode([chat, page]), forKey: "foveatedWebPanels")
        XCTAssertEqual(PCVRWebPanelStore.load(from: defaults), [chat, page])
    }

    func testNothingSavedIsAnEmptyList() throws {
        let suite = "PCVRWebPanelsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PCVRWebPanelStore.load(from: defaults), [])
    }
}
#endif
