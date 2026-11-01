import Foundation
import RAVECompanion

/// The Companion's side of `CompanionDiscovery` (RAVESDK's
/// `RAVECompanionPresence` since 2026-11-01): announces this Mac on the local
/// network and watches for headsets knocking to connect or pair.
typealias CompanionPresence = RAVECompanionPresence

extension RAVECompanionPresence {
    /// Longwave's presence: its namespace and the id headsets remember this
    /// Mac by, kept where it always was.
    convenience init() {
        self.init(namespace: CompanionDiscovery.namespace, macIDKey: "companionMacID")
    }

    /// Names of the paired headsets knocking right now, for the status line.
    var knockingHeadsets: [String] { knockingDevices }
}

extension RAVECompanionPresence.PairRequest {
    var headsetID: String { deviceID }
}
