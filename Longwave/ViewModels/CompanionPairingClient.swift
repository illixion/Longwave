import Foundation
import RAVECompanion

/// Pairs this device with a Companion (RAVESDK's `RAVEPairingClient` since
/// 2026-11-01): knocks with a pairing request and finds the listener the Mac
/// opens for it — or, from an address link, dials the Mac's direct pairing
/// port on each address in turn — then runs the exchange, shows the code for
/// the user to compare, and hands back the device's own token and what the
/// user allowed it, once they approve on the Mac.
typealias CompanionPairingClient = RAVEPairingClient<CompanionGrant>

extension RAVEPairingClient where Grant == CompanionGrant {
    /// - Parameter requested: what to ask the Mac for; its dialog starts from
    ///   these and the user decides.
    /// - Parameter sshPublicKey: this device's SSH key, offered when the user
    ///   wants SSH login as well; the Mac adds it only if allowed.
    convenience init(mac: CompanionLocator.NearbyMac, requested: Set<CompanionGrant> = CompanionGrant.defaults,
                     sshPublicKey: String? = nil) {
        self.init(locator: .shared, host: mac, deviceName: DeviceName.current, requested: requested,
                  sshPublicKey: sshPublicKey)
    }

    convenience init(link: CompanionPairLink, requested: Set<CompanionGrant> = CompanionGrant.defaults,
                     sshPublicKey: String? = nil) {
        self.init(locator: .shared, link: link, deviceName: DeviceName.current, requested: requested,
                  sshPublicKey: sshPublicKey)
    }
}
