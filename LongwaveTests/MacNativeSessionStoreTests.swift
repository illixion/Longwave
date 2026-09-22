import XCTest
@testable import Longwave

/// The Native stream used to be one manager for the whole app, so starting a
/// second connection took the first one's socket and window. These cover the
/// store that replaced it: one screen manager and one audio player per
/// connection, and the one thing that genuinely can't be shared — Music mode.
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

    func testEachSessionGetsItsOwnAudioPlayer() {
        let store = MacNativeSessionStore()
        let (firstID, _) = store.begin(connection("one.local"))
        let (secondID, _) = store.begin(connection("two.local"))

        let first = store.audioPlayer(for: firstID)
        let second = store.audioPlayer(for: secondID)

        XCTAssertFalse(first === second)
        // Asking twice hands back the same player, not a fresh one.
        XCTAssertTrue(store.audioPlayer(for: firstID) === first)
        XCTAssertNotEqual(first.scope, second.scope)
    }

    /// Both sessions can stream audio at once — the streams mix. Only Music
    /// mode is exclusive, and that is arbitrated inside `AudioStreamManager`.
    func testBothSessionsCanStreamAudioButOnlyOneRunsMusicMode() {
        let store = MacNativeSessionStore()
        let (firstID, _) = store.begin(connection("one.local"))
        let (secondID, _) = store.begin(connection("two.local"))
        let first = store.audioPlayer(for: firstID)
        let second = store.audioPlayer(for: secondID)
        defer {
            first.userDisconnect()
            second.userDisconnect()
        }

        first.audioMode = .music
        second.audioMode = .music

        // The explicit second choice takes the slot; the first drops to
        // Speaker and keeps playing rather than being switched off.
        XCTAssertEqual(second.effectiveAudioMode, .music)
        XCTAssertEqual(first.effectiveAudioMode, .speaker)
        XCTAssertTrue(first.isForcedToSpeaker)
        XCTAssertFalse(second.isForcedToSpeaker)
        // The preference is untouched — it is the grant that moved.
        XCTAssertEqual(first.audioMode, .music)
    }

    func testEndingTheMusicModeSessionLeavesTheSlotFree() {
        let store = MacNativeSessionStore()
        let (firstID, _) = store.begin(connection("one.local"))
        let (secondID, _) = store.begin(connection("two.local"))
        let second = store.audioPlayer(for: secondID)
        defer { second.userDisconnect() }
        store.audioPlayer(for: firstID).audioMode = .music

        store.end(firstID)
        second.audioMode = .music

        XCTAssertEqual(second.effectiveAudioMode, .music)
    }

    /// Volume, mode and the live toggle are per player: two streams playing at
    /// once need their own levels, and one shared key would have the last
    /// session to touch a slider decide for all of them.
    func testAudioPreferencesArePerSession() {
        let store = MacNativeSessionStore()
        let (firstID, _) = store.begin(connection("one.local"))
        let (secondID, _) = store.begin(connection("two.local"))
        let first = store.audioPlayer(for: firstID)
        let second = store.audioPlayer(for: secondID)
        defer {
            first.userDisconnect()
            second.userDisconnect()
        }

        let secondVolumeBefore = second.volume
        first.volume = secondVolumeBefore == 0.25 ? 0.5 : 0.25
        first.liveEnabled = true

        XCTAssertEqual(second.volume, secondVolumeBefore, accuracy: 0.0001)
        XCTAssertNotEqual(first.volume, second.volume, accuracy: 0.0001)
        XCTAssertFalse(second.liveEnabled)
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
