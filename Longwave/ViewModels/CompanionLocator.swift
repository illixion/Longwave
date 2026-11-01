import Foundation
import RAVECompanion

/// The headset's side of `CompanionDiscovery`: finds Companions on the local
/// network and knocks for a paired one's ports. The work is RAVESDK's
/// `RAVECompanionLocator` (since 2026-11-01); this keeps Longwave's names and
/// its one shared instance.
typealias CompanionLocator = RAVECompanionLocator

extension RAVECompanionLocator {
    /// Longwave's locator: its namespace, this device's id and name.
    static let shared = RAVECompanionLocator(
        namespace: CompanionDiscovery.namespace,
        deviceID: headsetID,
        deviceName: { DeviceName.current }
    )

    /// This device's identity towards Companions. Stable, random, and not
    /// tied to anything else about the device.
    nonisolated static let headsetID: String = persistentDeviceID(key: "longwaveHeadsetID")

    typealias NearbyMac = NearbyHost
}

extension RAVECompanionLocator.NearbyHost {
    /// What to dial for a host that takes direct pairing.
    var pairLink: CompanionPairLink? { directPairLink(CompanionDiscovery.namespace) }
}
