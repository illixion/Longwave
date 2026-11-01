import Foundation
import RAVECompanion

/// The fixed pairing port (`CompanionPairLink.defaultPort`) a headset dials
/// when it can't see this Mac over Bonjour (RAVESDK's
/// `RAVEDirectPairingListener` since 2026-11-01). It listens only while
/// connections by address are allowed, or for ten minutes after an address
/// link was sent.
typealias DirectPairingListener = RAVEDirectPairingListener

extension RAVEDirectPairingListener {
    convenience init() {
        self.init(namespace: CompanionDiscovery.namespace)
    }
}
