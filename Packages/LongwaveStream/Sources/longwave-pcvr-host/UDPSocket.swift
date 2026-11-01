// A non-blocking IPv4 UDP socket over Winsock, for the sans-I/O v3 session:
// the host owns the socket and drives HostEndpoint with what arrives.

import WinSDK

struct UDPAddress: Hashable, Sendable, CustomStringConvertible {
    /// IPv4 address in network byte order, as in sockaddr_in.
    var ip: UInt32
    var port: UInt16

    var description: String {
        let b = withUnsafeBytes(of: ip) { Array($0) }
        return "\(b[0]).\(b[1]).\(b[2]).\(b[3]):\(port)"
    }
}

struct SocketError: Error, CustomStringConvertible {
    let operation: String
    let code: Int32
    var description: String { "\(operation) failed (WSA error \(code))" }
}

final class UDPSocket: @unchecked Sendable {
    private let handle: SOCKET

    private static let startup: Void = {
        var data = WSADATA()
        _ = WSAStartup(0x0202, &data)
    }()

    init(port: UInt16, bufferBytes: Int32 = 8 << 20) throws {
        _ = Self.startup
        handle = WinSDK.socket(AF_INET, Int32(SOCK_DGRAM), Int32(IPPROTO_UDP.rawValue))
        guard handle != INVALID_SOCKET else { throw SocketError(operation: "socket", code: WSAGetLastError()) }

        var size = bufferBytes
        for option in [SO_RCVBUF, SO_SNDBUF] {
            _ = withUnsafeBytes(of: &size) { raw in
                setsockopt(handle, SOL_SOCKET, option, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count))
            }
        }
        // Without this, an ICMP port-unreachable from a client that went away
        // makes the next recvfrom fail with WSAECONNRESET (SIO_UDP_CONNRESET).
        var off: DWORD = 0
        var returned: DWORD = 0
        _ = WSAIoctl(handle, 0x9800_000C, &off, DWORD(MemoryLayout<DWORD>.size), nil, 0, &returned, nil, nil)
        var nonBlocking: u_long = 1
        _ = ioctlsocket(handle, Int32(bitPattern: 0x8004_667E), &nonBlocking) // FIONBIO

        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_port = port.bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(handle, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            let code = WSAGetLastError()
            closesocket(handle)
            throw SocketError(operation: "bind :\(port)", code: code)
        }
    }

    deinit { closesocket(handle) }

    /// Blocks until a datagram is waiting or `milliseconds` pass.
    func wait(milliseconds: Int32) -> Bool {
        var fd = WSAPOLLFD(fd: handle, events: Int16(POLLRDNORM), revents: 0)
        return WSAPoll(&fd, 1, milliseconds) > 0
    }

    /// One waiting datagram, or nil when none is.
    func receive(into buffer: inout [UInt8]) -> (count: Int, from: UDPAddress)? {
        var address = sockaddr_in()
        var length = Int32(MemoryLayout<sockaddr_in>.size)
        let n = buffer.withUnsafeMutableBytes { raw in
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(handle, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count), 0, $0, &length)
                }
            }
        }
        guard n >= 0 else { return nil } // WSAEWOULDBLOCK, or an error the next poll repeats
        return (Int(n), UDPAddress(ip: address.sin_addr.S_un.S_addr, port: UInt16(bigEndian: address.sin_port)))
    }

    /// Returns false if the stack refused the datagram (send buffer full).
    @discardableResult
    func send(_ datagram: [UInt8], to destination: UDPAddress) -> Bool {
        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_port = destination.port.bigEndian
        address.sin_addr.S_un.S_addr = destination.ip
        let sent = datagram.withUnsafeBytes { raw in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(handle, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count), 0, $0,
                           Int32(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return Int(sent) == datagram.count
    }
}
