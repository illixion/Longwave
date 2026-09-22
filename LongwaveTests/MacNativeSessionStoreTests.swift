import XCTest
@testable import Longwave

/// The Native stream used to be one manager for the whole app, so starting a
/// second connection took the first one's socket and window. These cover the
/// store that replaced it: one session per connection, and the one thing that
/// genuinely stays shared — the audio player.
@MainActor
final class MacNativeSessionStoreTests: XCTestCase {
    private func connection(_ host: String) -> SavedConnection {
        SavedConnection(hostname: host, connectionType: .native)
    }

    func testTwoConnectionsGetTheirOwnSessions() {
        let store = MacNativeSessionStore()
        let first = connection("one.local")
        let second = connection("two.local")

        let (firstID, firstManager) = store.begin(first)
        let (secondID, secondManager) = store.begin(second)

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertFalse(firstManager === secondManager)
        XCTAssertEqual(store.sessionIDs, [firstID, secondID])
    }

    func testReconnectingTheSameConnectionReusesItsSession() {
        let store = MacNativeSessionStore()
        let saved = connection("mac.local")

        let (firstID, firstManager) = store.begin(saved)
        let (secondID, secondManager) = store.begin(saved)

        XCTAssertEqual(firstID, secondID)
        XCTAssertTrue(firstManager === secondManager)
        XCTAssertEqual(store.sessionIDs.count, 1)
    }

    func testEndingOneSessionLeavesTheOtherAlone() {
        let store = MacNativeSessionStore()
        let (firstID, _) = store.begin(connection("one.local"))
        let (secondID, secondManager) = store.begin(connection("two.local"))

        store.end(firstID)

        XCTAssertEqual(store.sessionIDs, [secondID])
        XCTAssertTrue(store.existingSession(for: secondID) === secondManager)
        XCTAssertNil(store.existingSession(for: firstID))
        XCTAssertEqual(store.focusedID, secondID)
    }

    func testAudioBelongsToOneSessionAtATime() {
        let store = MacNativeSessionStore()
        let (firstID, _) = store.begin(connection("one.local"))
        let (secondID, _) = store.begin(connection("two.local"))

        // Nobody has claimed it yet, so either may take it.
        XCTAssertTrue(store.ownsAudio(firstID))
        XCTAssertTrue(store.ownsAudio(secondID))

        store.claimAudio(firstID)
        XCTAssertTrue(store.ownsAudio(firstID))
        XCTAssertFalse(store.ownsAudio(secondID))

        // Releasing from the session that doesn't hold it changes nothing.
        store.releaseAudio(secondID)
        XCTAssertTrue(store.ownsAudio(firstID))
        XCTAssertFalse(store.ownsAudio(secondID))

        store.releaseAudio(firstID)
        XCTAssertTrue(store.ownsAudio(secondID))
    }

    func testEndingTheAudioOwnerHandsThePlayerBack() {
        let store = MacNativeSessionStore()
        let (firstID, _) = store.begin(connection("one.local"))
        let (secondID, _) = store.begin(connection("two.local"))
        store.claimAudio(firstID)

        store.end(firstID)

        XCTAssertTrue(store.ownsAudio(secondID))
    }

    /// The Screen toggle is remembered per session, not per app — one shared
    /// defaults key would have the last session to toggle Screen decide
    /// whether every other one resumes it.
    func testScreenToggleIsRememberedPerSession() {
        let store = MacNativeSessionStore()
        let (_, firstManager) = store.begin(connection("one.local"))
        let (_, secondManager) = store.begin(connection("two.local"))

        firstManager.liveEnabled = true

        XCTAssertTrue(firstManager.liveEnabled)
        XCTAssertFalse(secondManager.liveEnabled)

        firstManager.liveEnabled = false
    }

    /// A window scene resolving its value after the session ended must not
    /// resurrect a live session — it gets an empty manager and shows the
    /// placeholder.
    func testSceneLookupAfterEndYieldsAnUnconnectedManager() {
        let store = MacNativeSessionStore()
        let (id, _) = store.begin(connection("one.local"))
        store.end(id)

        let manager = store.session(for: id)

        XCTAssertNil(manager.connection)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertTrue(store.sessionIDs.isEmpty)
    }
}
