import Foundation
import SwiftUI

/// Value key for the per-session Native scenes ("mac-native-stream",
/// "mac-native-unity-controls", "mac-native-keyboard", "mac-native-window"):
/// one set of windows per Native connection, so reopening a connection
/// reactivates its windows instead of minting duplicates — and two
/// connections no longer fight over one window.
///
/// Identity is the saved connection's id rather than a slot number: unlike
/// Moonlight (where a session *is* one of the linked copies of
/// moonlight-common-c, so there are exactly three), a Native session is just a
/// socket and there is no ceiling on how many can run.
struct MacNativeSessionID: Codable, Hashable, Identifiable {
    let connectionID: UUID

    var id: UUID { connectionID }
    /// Suffix that scopes this session's windows in `WindowSessionRegistry`.
    var registryInstance: String { connectionID.uuidString }

    init(_ connectionID: UUID) {
        self.connectionID = connectionID
    }

    init(connection: SavedConnection) {
        self.connectionID = connection.id
    }
}

/// The app's Native (Mac/Windows desktop stream) sessions — one
/// `MacNativeStreamManager` per saved connection, created on demand and kept
/// until the user disconnects it.
///
/// Native used to be a single manager injected into the environment, which
/// meant a second connection took the first one's socket, window and state:
/// starting a stream from another host ended the one already running. Nothing
/// about the protocol is single-session, so the store simply keys managers by
/// connection. A scene is keyed by `MacNativeSessionID` and injects
/// `session(for:)` as the `MacNativeStreamManager` its views already read from
/// the environment, so the stream, keyboard and per-window views did not have
/// to learn about sessions.
@Observable
final class MacNativeSessionStore {
    /// Deliberately not observed: `session(for:)` is called from a
    /// `WindowGroup` body (the scene resolving its value), and mutating an
    /// observed property there is a mutation during view update. The observed
    /// list below changes only from explicit actions.
    @ObservationIgnored private var managers: [MacNativeSessionID: MacNativeStreamManager] = [:]

    /// Live sessions in the order they were started, oldest first.
    private(set) var sessionIDs: [MacNativeSessionID] = []

    /// The session a Summon (or a single-window client's stream cover) targets
    /// when only a window *kind* is known — the most recently started one.
    private(set) var focusedID: MacNativeSessionID?

    /// The manager for `id`, creating it if this is the first time the scene
    /// (or the connection list) has asked for it.
    func session(for id: MacNativeSessionID) -> MacNativeStreamManager {
        if let existing = managers[id] { return existing }
        let manager = MacNativeStreamManager(sessionID: id)
        managers[id] = manager
        return manager
    }

    func existingSession(for id: MacNativeSessionID) -> MacNativeStreamManager? {
        managers[id]
    }

    /// Starts (or re-focuses) the session for a saved connection. The manager
    /// is returned unconnected — the caller decides what Screen/Audio/Unity
    /// should be doing before it connects.
    @discardableResult
    func begin(_ connection: SavedConnection) -> (id: MacNativeSessionID, manager: MacNativeStreamManager) {
        let id = MacNativeSessionID(connection: connection)
        let manager = session(for: id)
        if !sessionIDs.contains(id) {
            sessionIDs.append(id)
        }
        focusedID = id
        return (id, manager)
    }

    /// Tears a session down and forgets it — the hard close behind every
    /// Disconnect button. Its windows are dismissed by the caller.
    func end(_ id: MacNativeSessionID) {
        audioPlayers[id]?.userDisconnect()
        audioPlayers[id] = nil
        managers[id]?.forget()
        managers[id] = nil
        sessionIDs.removeAll { $0 == id }
        if focusedID == id {
            focusedID = sessionIDs.last
        }
    }

    /// Route the "which session does an id-only action mean" question to a
    /// specific session — the Sessions tab's Summon, and the phone's stream
    /// cover.
    func focus(_ id: MacNativeSessionID) {
        guard managers[id] != nil else { return }
        focusedID = id
    }

    /// Sessions with a live (or connecting) socket, oldest first.
    var connectedSessions: [(id: MacNativeSessionID, manager: MacNativeStreamManager)] {
        sessionIDs.compactMap { id in
            guard let manager = managers[id], manager.isEnabled else { return nil }
            return (id, manager)
        }
    }

    /// The session a single-scene client (iPhone) shows full-screen: the
    /// focused one while it is live, else whichever other session is.
    var activeID: MacNativeSessionID? {
        if let focusedID, let manager = managers[focusedID], manager.isEnabled {
            return focusedID
        }
        return connectedSessions.last?.id
    }

    // MARK: - Audio

    /// One audio player per session, created on demand alongside the screen
    /// manager. Deliberately not observed, for the same reason as `managers`.
    @ObservationIgnored private var audioPlayers: [MacNativeSessionID: AudioStreamManager] = [:]

    /// This session's audio player.
    ///
    /// Audio used to be one player for the whole app, with the store recording
    /// which session was allowed to use it — so a second session could connect
    /// its screen but not its sound. There is no reason for that: several
    /// streams mix perfectly well. What genuinely cannot be shared is Music
    /// mode, which takes the audio session exclusively and owns the one Now
    /// Playing entry, so `AudioStreamManager` grants that to a single player
    /// and runs every other one in Speaker mode — see its `effectiveAudioMode`.
    func audioPlayer(for id: MacNativeSessionID) -> AudioStreamManager {
        if let existing = audioPlayers[id] { return existing }
        let player = AudioStreamManager(scope: id.connectionID.uuidString)
        audioPlayers[id] = player
        return player
    }

    func existingAudioPlayer(for id: MacNativeSessionID) -> AudioStreamManager? {
        audioPlayers[id]
    }

    /// Host names of every live session — the Sessions tab's subtitle.
    var connectedTitles: [String] {
        connectedSessions.map(\.manager.title)
    }
}
