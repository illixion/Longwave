import DebugTrace
import SwiftData
import SwiftUI
import WatchConnectivity

/// Hands the Apple Watch a Mac to show: the most recently used paired Native
/// connection whose Mac allows this iPhone the screen. The watch speaks the
/// watch lane (`WatchLinkProtocol`) with this iPhone's own device key, which
/// the Mac accepts for as long as it allows this iPhone the screen — so the
/// watch needs no pairing of its own, and revoking the iPhone revokes it too.
@MainActor
final class WatchCredentialSync: NSObject, WCSessionDelegate {
    static let shared = WatchCredentialSync()

    private var pending: [String: Any]?
    private var lastSent: [String: String]?

    func update(from connections: [SavedConnection]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate == nil {
            session.delegate = self
            session.activate()
        }
        let candidate = connections
            .filter { $0.connectionType == .native && $0.companionDeviceToken != nil }
            .filter { $0.companionGrants.isEmpty || $0.companionGrants.contains(.screen) }
            .max { ($0.lastConnected ?? .distantPast) < ($1.lastConnected ?? .distantPast) }
        guard let candidate, let token = candidate.companionDeviceToken else { return }
        let context = ["address": candidate.hostname, "token": token, "name": candidate.displayName]
        guard context != lastSent else { return }
        if session.activationState == .activated {
            send(context)
        } else {
            pending = context
        }
    }

    private func send(_ context: [String: String]) {
        let session = WCSession.default
        guard session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext(context)
            lastSent = context
        } catch {
            AppLog.companionDiscovery.log("Couldn't hand the watch its Mac: \(error.localizedDescription)")
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            guard activationState == .activated, let pending = self.pending as? [String: String] else { return }
            self.pending = nil
            self.send(pending)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}

/// Keeps `WatchCredentialSync` in step with the saved connections.
struct WatchCredentialSyncView: View {
    @Query private var connections: [SavedConnection]

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: connections.map { "\($0.id)\($0.lastConnected?.timeIntervalSince1970 ?? 0)\($0.companionGrantsRaw)" }) {
                WatchCredentialSync.shared.update(from: connections)
            }
    }
}
