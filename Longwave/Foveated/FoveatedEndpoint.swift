//  FoveatedEndpoint.swift
//
//  Pure-logic validation for foveated (PCVR) connection endpoints. Kept free of
//  the `FOVEATED_ENABLED` flag and of the device-only `FoveatedStreaming`
//  framework so it can be unit-tested in the default build configuration
//  (`FoveatedEndpointTests`). The manager turns a `SavedConnection` into a real
//  `FoveatedStreamingSession.Endpoint`; this type just answers "is the user
//  input usable?" for the same three modes.

import Foundation
import Network

enum FoveatedEndpoint {

    /// A valid IPv4 address string (the local-IP connect mode requires one;
    /// `FoveatedStreamingSession.Endpoint.local` takes an `IPAddress`).
    static func isValidIPv4(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return IPv4Address(trimmed) != nil
    }

    /// A TCP port in the usable range.
    static func isValidPort(_ port: Int) -> Bool {
        port > 0 && port <= 65_535
    }

    /// Whether a connection of `mode` has enough information to attempt a
    /// connection. System discovery always can (the system presents a picker);
    /// local needs a valid IP + port.
    static func canConnect(mode: FoveatedConnectionMode, host: String, port: Int) -> Bool {
        switch mode {
        case .systemDiscovered:
            return true
        case .local:
            return isValidIPv4(host) && isValidPort(port)
        }
    }
}
