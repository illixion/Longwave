// The devices paired with the Windows Companion, read where its backend keeps
// them (CompanionWindows/backend/Devices/DeviceRegistry.cs): a JSON list,
// DPAPI-protected for the current user, in HKCU\SOFTWARE\Longwave\Companion
// "PairedDevices". The host must run as the same user. Tokens never leave
// this file except as the v3 PSK they derive.

import Foundation
import StreamCrypto
import StreamWire
import WinSDK

struct PairedDevice: Decodable, Equatable {
    let id: String
    let name: String
    let grants: [String]
    let token: String

    /// The Companion's grant names onto v3's bits (CompanionGrant order:
    /// screen, audio, input, projects, sshKey).
    var sessionGrants: SessionGrants {
        var value = SessionGrants()
        if grants.contains("screen") { value.insert(.screen) }
        if grants.contains("input") { value.insert(.input) }
        return value
    }

    var psk: StreamPSK { StreamPSK(token: token, identity: id) }
}

enum PairedDevices {
    private static let entropy = Array("Longwave paired devices v1".utf8)

    static func load() throws -> [PairedDevice] {
        guard let sealed = try readRegistryBinary() else { return [] }
        let json = try unprotect(sealed)
        return try JSONDecoder().decode([PairedDevice].self, from: Data(json))
    }

    private static func readRegistryBinary() throws -> [UInt8]? {
        // HKEY_CURRENT_USER, a sign-extended pseudo-handle.
        let currentUser = HKEY(bitPattern: Int(Int32(bitPattern: 0x8000_0001)))
        let flags = DWORD(0x0000_0008) // RRF_RT_REG_BINARY
        return try "SOFTWARE\\Longwave\\Companion".withCString(encodedAs: UTF16.self) { path in
            try "PairedDevices".withCString(encodedAs: UTF16.self) { name in
                var size: DWORD = 0
                var status = RegGetValueW(currentUser, path, name, flags, nil, nil, &size)
                if status == ERROR_FILE_NOT_FOUND { return nil }
                guard status == ERROR_SUCCESS else { throw HostError("RegGetValueW size: \(status)") }
                var bytes = [UInt8](repeating: 0, count: Int(size))
                status = RegGetValueW(currentUser, path, name, flags, nil, &bytes, &size)
                guard status == ERROR_SUCCESS else { throw HostError("RegGetValueW: \(status)") }
                return Array(bytes.prefix(Int(size)))
            }
        }
    }

    private static func unprotect(_ sealed: [UInt8]) throws -> [UInt8] {
        var sealedCopy = sealed
        var entropyCopy = entropy
        return try sealedCopy.withUnsafeMutableBufferPointer { input in
            try entropyCopy.withUnsafeMutableBufferPointer { salt in
                var inBlob = DATA_BLOB(cbData: DWORD(input.count), pbData: input.baseAddress)
                var saltBlob = DATA_BLOB(cbData: DWORD(salt.count), pbData: salt.baseAddress)
                var outBlob = DATA_BLOB()
                guard CryptUnprotectData(&inBlob, nil, &saltBlob, nil, nil, 0, &outBlob) else {
                    throw HostError("CryptUnprotectData failed (\(GetLastError()))")
                }
                defer { LocalFree(outBlob.pbData) }
                return Array(UnsafeBufferPointer(start: outBlob.pbData, count: Int(outBlob.cbData)))
            }
        }
    }
}

struct HostError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
