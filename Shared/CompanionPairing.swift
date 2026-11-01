import Foundation
import RAVECompanion

/// Finding and pairing with a Companion on the local network, with no token
/// for the user to copy and no port open on the Mac until a headset asks.
///
/// The protocol lives in RAVESDK's `RAVECompanion` (moved 2026-11-01 so other
/// apps can pair the same way); this file keeps Longwave's names for it, under
/// Longwave's namespace. The wire format is unchanged: the Windows Companion
/// (`CompanionWindows/backend/Devices/Pairing.cs`) implements the same bytes,
/// and `RAVECompanionTests` pins them with vectors taken from the code that
/// used to be here.
///
/// - `_longwave-mac._tcp`, advertised by the Mac for as long as the Companion
///   runs. A record only — no socket listens behind it.
/// - `_longwave-knock._tcp`, advertised by the headset while it wants the Mac:
///   a rolling tag only a holder of the pairing secret can make, or `pair=1`.
/// - `_longwave-pair._tcp`, advertised by the Mac only while it answers one
///   pairing request.
nonisolated enum CompanionDiscovery {
    static let namespace = RAVECompanionNamespace.longwave

    static var macServiceType: String { namespace.hostServiceType }
    static var knockServiceType: String { namespace.knockServiceType }
    static var pairServiceType: String { namespace.pairServiceType }

    /// TXT keys, by Longwave's names.
    enum Key {
        static let version = RAVECompanionDiscovery.Key.version
        static let macID = RAVECompanionDiscovery.Key.hostID
        static let addresses = RAVECompanionDiscovery.Key.addresses
        static let open = RAVECompanionDiscovery.Key.open
        static let headsetID = RAVECompanionDiscovery.Key.deviceID
        static let tag = RAVECompanionDiscovery.Key.tag
        static let pairRequest = RAVECompanionDiscovery.Key.pairRequest
        static let name = RAVECompanionDiscovery.Key.name
        static let os = RAVECompanionDiscovery.Key.os
        static let pairPort = RAVECompanionDiscovery.Key.pairPort
    }

    static let version = RAVECompanionDiscovery.version

    static func minute(of date: Date) -> Int64 { RAVECompanionDiscovery.minute(of: date) }

    static func knockTag(token: String, macID: String, headsetID: String, minute: Int64) -> String {
        RAVECompanionDiscovery.knockTag(namespace, token: token, hostID: macID, deviceID: headsetID, minute: minute)
    }

    static func isValidKnock(tag: String, token: String, macID: String, headsetID: String, now: Date = Date()) -> Bool {
        RAVECompanionDiscovery.isValidKnock(namespace, tag: tag, token: token, hostID: macID, deviceID: headsetID, now: now)
    }
}

/// What the Mac hands a headset once the user has approved it.
typealias PairingGrant = RAVEPairingGrant
/// One numeric-comparison pairing (`RAVEPairingExchange`).
typealias PairingExchange = RAVEPairingExchange
/// The messages of a pairing, with Longwave's grants.
typealias PairingMessage = RAVEPairingMessage<CompanionGrant>
