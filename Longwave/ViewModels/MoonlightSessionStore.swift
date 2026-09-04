#if MOONLIGHT_ENABLED
import Foundation
import SwiftUI

/// Value key for the per-session Moonlight scenes ("moonlight-stream",
/// "moonlight-keyboard"): one window per linked copy of moonlight-common-c, so
/// reopening a session's window reactivates it instead of minting a duplicate.
struct MoonlightSessionID: Codable, Hashable, Identifiable {
    var id: Int { slot }
    let slot: Int
}

/// The app's Moonlight sessions — one `MoonlightConnectionManager` per linked
/// copy of moonlight-common-c, created once and kept for the app's lifetime.
///
/// Moonlight used to be a single manager because the C library can only run one
/// connection; now there are `MoonlightLibrary.count` of them (see
/// `MoonlightLibrary` for how). Connecting a saved connection picks a manager:
/// the one already bound to that connection if there is one, else a free one. A
/// scene is keyed by `MoonlightSessionID`, and injects `session(for:)` as the
/// `MoonlightConnectionManager` its views already read from the environment, so
/// the stream and keyboard views did not have to learn about slots.
@Observable
final class MoonlightSessionStore {
    let sessions: [MoonlightConnectionManager]

    /// Mirror of `MoonlightInputFocus.slot` for views (which session shows the
    /// "controller here" badge, which one a Summon targets).
    private(set) var focusedSlot: Int = 0

    init() {
        sessions = MoonlightLibrary.all.map { MoonlightConnectionManager(library: $0) }
        for session in sessions {
            session.onStreamingChanged = { [weak self] slot, streaming in
                self?.streamingChanged(slot: slot, streaming: streaming)
            }
        }
    }

    func session(for id: MoonlightSessionID) -> MoonlightConnectionManager {
        sessions[id.slot]
    }

    /// Sessions that are streaming right now, in slot order.
    var streamingSessions: [MoonlightConnectionManager] {
        sessions.filter { $0.connectionState == .streaming }
    }

    /// Whether any session is mid-launch or streaming — what a single-window
    /// client (iPhone) presents its stream cover off.
    var activeSession: MoonlightConnectionManager? {
        sessions.first { $0.connectionState == .streaming || $0.connectionState == .launching }
    }

    /// The manager to use for `connection`: the one already working on that
    /// connection (so re-tapping a streaming row reopens its sheet rather than
    /// starting a second session against the same host), else the first one
    /// with nothing in flight. `nil` when every copy of the library is busy —
    /// the caller tells the user, since there is no queue to wait in.
    func session(for connection: SavedConnection) -> MoonlightConnectionManager? {
        if let bound = sessions.first(where: { $0.activeConnectionID == connection.id }) {
            return bound
        }
        return sessions.first { !$0.isBusy }
    }

    /// Route shared physical input (gamepads, Bluetooth mice, GCKeyboard) to
    /// `slot`. Called by the stream views as the user looks at / points at them.
    func focus(_ slot: Int) {
        MoonlightInputFocus.claim(slot)
        focusedSlot = MoonlightInputFocus.slot
    }

    private func streamingChanged(slot: Int, streaming: Bool) {
        if streaming {
            // A stream that just came up is what the user is about to play on.
            focus(slot)
        } else if MoonlightInputFocus.slot == slot,
                  let other = streamingSessions.first(where: { $0.slot != slot }) {
            // The focused stream ended; hand the controller to a survivor.
            focus(other.slot)
        }
    }
}
#endif
