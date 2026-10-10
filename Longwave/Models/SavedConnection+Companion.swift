import Foundation

/// A Native connection's credential towards its Companion. Pairing gives this
/// device a token of its own, kept in the keychain under the connection's id;
/// a connection set up before that still holds the old shared token.
extension SavedConnection {
    static let companionDeviceTokenService = "pro.longwave.companionDevice"

    /// This device's own token for the paired Mac, if it was paired since
    /// per-device pairing.
    var companionDeviceToken: String? {
        KeychainStore.get(service: Self.companionDeviceTokenService, account: id.uuidString)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Stores (or with nil, removes) the device token. Pairing clears the
    /// legacy shared token at the same time: one connection holds one key.
    @discardableResult
    func setCompanionDeviceToken(_ token: String?) -> Bool {
        let stored = KeychainStore.set(service: Self.companionDeviceTokenService, account: id.uuidString, value: token ?? "")
        if stored, token != nil { companionToken = "" }
        return stored
    }

    /// What every Companion channel presents: the device token with this
    /// device's id, else the shared token (old fixed identities), else nil.
    var companionCredential: CompanionCredential? {
        if let token = companionDeviceToken {
            return CompanionCredential(token: token, deviceID: CompanionLocator.headsetID)
        }
        if !companionToken.isEmpty {
            return CompanionCredential(token: companionToken, deviceID: nil)
        }
        return nil
    }

    /// Paired the old way: works while the Mac still accepts the shared
    /// token, and should be paired again.
    var companionNeedsPairing: Bool {
        connectionType == .native && companionDeviceToken == nil
    }

    var companionGrants: Set<CompanionGrant> {
        get { Set(companionGrantsRaw.split(separator: ",").compactMap { CompanionGrant(rawValue: String($0)) }) }
        set { companionGrantsRaw = newValue.map(\.rawValue).sorted().joined(separator: ",") }
    }

    /// Called when the connection is deleted.
    func forgetCompanionCredential() {
        KeychainStore.delete(service: Self.companionDeviceTokenService, account: id.uuidString)
    }
}

extension SavedConnection {
    /// `companionCredential`, or an empty one the channels refuse to dial
    /// with — for call sites that hand it straight to a connect.
    var resolvedCompanionCredential: CompanionCredential {
        companionCredential ?? CompanionCredential(token: "", deviceID: nil)
    }
}
