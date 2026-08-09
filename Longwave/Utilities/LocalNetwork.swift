import Foundation

/// Detects when this device is joined to a **Windows Mobile Hotspot** (Internet Connection
/// Sharing) network so the connection form can pre-fill the host automatically.
///
/// Windows ICS has pinned its shared network to **192.168.137.0/24** with the host (gateway)
/// at **192.168.137.1** for ~20 years. So if this device currently holds a `192.168.137.x`
/// lease, we're almost certainly behind a Windows host's NAT (e.g. the Longwave Windows
/// Hotspot Companion) and the VNC/Moonlight server is reachable at `192.168.137.1`.
///
/// This is a deliberately lightweight alternative to mDNS/Bonjour discovery: no service
/// advertising, no `NWBrowser`, no entitlements — just a subnet check against a known constant.
enum LocalNetwork {
    static let windowsIcsSubnetPrefix = "192.168.137."
    static let windowsIcsGateway = "192.168.137.1"

    /// Returns the inferred Windows-ICS host (the gateway) if this device currently holds an
    /// address on the ICS subnet; otherwise `nil`.
    static func windowsHotspotHost() -> String? {
        inferWindowsHotspotHost(from: activeIPv4Addresses())
    }

    /// Pure inference used by `windowsHotspotHost()` — separated so it's unit-testable without
    /// touching the live interface list. If any address is on the ICS subnet (and isn't the
    /// gateway itself), the host is the ICS gateway.
    static func inferWindowsHotspotHost(from addresses: [String]) -> String? {
        for ip in addresses where ip.hasPrefix(windowsIcsSubnetPrefix) && ip != windowsIcsGateway {
            return windowsIcsGateway
        }
        return nil
    }

    /// All non-loopback IPv4 addresses currently assigned to up interfaces (via `getifaddrs`).
    static func activeIPv4Addresses() -> [String] {
        var results: [String] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return results }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & Int32(IFF_UP)) != 0,
                  (flags & Int32(IFF_LOOPBACK)) == 0,
                  let sa = current.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let saLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            if getnameinfo(sa, saLen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.isEmpty { results.append(ip) }
            }
        }
        return results
    }
}
