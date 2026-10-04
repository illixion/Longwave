// SPIKE ONLY: a blocking IPv4 UDP socket over Winsock or BSD sockets, to see
// how plain socket code reads in Swift on each platform. The Phase 1
// transport takes a `DatagramSocket` protocol instead (section 7.1).

#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct SpikeSocketError: Error, CustomStringConvertible {
    public let operation: String
    public let code: Int32
    public var description: String { "\(operation) failed (error \(code))" }
}

#if os(Windows)
private typealias SockLen = Int32
private typealias NativeSocket = SOCKET
private let invalidSocket = INVALID_SOCKET
private func lastSocketError() -> Int32 { WSAGetLastError() }
#else
private typealias SockLen = socklen_t
private typealias NativeSocket = Int32
private let invalidSocket: Int32 = -1
private func lastSocketError() -> Int32 { errno }
#endif

public final class SpikeUDPSocket: @unchecked Sendable {
    private let handle: NativeSocket
    private var destination = sockaddr_in()
    private var hasDestination = false

    #if os(Windows)
    /// Winsock must be started once per process before any socket call.
    private static let startup: Void = {
        var data = WSADATA()
        _ = WSAStartup(0x0202, &data)
    }()
    #endif

    /// Binds to `port` on `address` ("0.0.0.0" for any). Port 0 picks one.
    public init(bindAddress: String = "0.0.0.0", port: UInt16 = 0, bufferBytes: Int32 = 8 << 20) throws {
        #if os(Windows)
        _ = Self.startup
        handle = WinSDK.socket(AF_INET, Int32(SOCK_DGRAM), Int32(IPPROTO_UDP.rawValue))
        #elseif canImport(Darwin)
        handle = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        #else
        handle = Glibc.socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_UDP))
        #endif
        guard handle != invalidSocket else { throw SpikeSocketError(operation: "socket", code: lastSocketError()) }

        // Large buffers: an IDR at 1440p can be a few hundred datagrams sent
        // back to back, and the receiver may be descheduled for a moment.
        var size = bufferBytes
        _ = withUnsafeBytes(of: &size) { raw in
            setsockopt(handle, SOL_SOCKET, SO_RCVBUF, raw.baseAddress!.assumingMemoryBound(to: CChar.self), SockLen(raw.count))
        }
        _ = withUnsafeBytes(of: &size) { raw in
            setsockopt(handle, SOL_SOCKET, SO_SNDBUF, raw.baseAddress!.assumingMemoryBound(to: CChar.self), SockLen(raw.count))
        }

        var address = try Self.makeAddress(bindAddress, port: port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, SockLen(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = lastSocketError()
            close()
            throw SpikeSocketError(operation: "bind", code: code)
        }
    }

    deinit { close() }

    private var closed = false
    public func close() {
        guard !closed else { return }
        closed = true
        #if os(Windows)
        closesocket(handle)
        #else
        _ = Darwin_or_Glibc_close(handle)
        #endif
    }

    public var localPort: UInt16 {
        var address = sockaddr_in()
        var length = SockLen(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(handle, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    public func connect(host: String, port: UInt16) throws {
        destination = try Self.makeAddress(host, port: port)
        hasDestination = true
    }

    /// Sends one datagram to the connected destination. Returns false if the
    /// OS refused it (buffer full); the spike counts those as drops.
    @discardableResult
    public func send(_ datagram: UnsafeRawBufferPointer) -> Bool {
        precondition(hasDestination, "connect(host:port:) first")
        let sent = withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                #if os(Windows)
                return Int(sendto(handle, datagram.baseAddress!.assumingMemoryBound(to: CChar.self),
                                  Int32(datagram.count), 0, address, Int32(MemoryLayout<sockaddr_in>.size)))
                #else
                return sendto(handle, datagram.baseAddress!, datagram.count, 0, address,
                              socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        return sent == datagram.count
    }

    /// Sets how long `receive` blocks before returning 0.
    public func setReceiveTimeout(milliseconds: Int) {
        #if os(Windows)
        var value = DWORD(milliseconds)
        _ = withUnsafeBytes(of: &value) { raw in
            setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, raw.baseAddress!.assumingMemoryBound(to: CChar.self), SockLen(raw.count))
        }
        #else
        var value = timeval(tv_sec: milliseconds / 1000, tv_usec: Int32((milliseconds % 1000) * 1000))
        _ = setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        #endif
    }

    /// Receives one datagram into `buffer`; returns its length, or 0 on timeout.
    public func receive(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        #if os(Windows)
        let n = Int(recv(handle, buffer.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(buffer.count), 0))
        #else
        let n = recv(handle, buffer.baseAddress!, buffer.count, 0)
        #endif
        return max(0, n)
    }

    private static func makeAddress(_ host: String, port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY_INET
        address.sin_port = port.bigEndian
        let ok = host.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard ok == 1 else { throw SpikeSocketError(operation: "inet_pton(\(host))", code: lastSocketError()) }
        return address
    }
}

#if os(Windows)
private let ADDRESS_FAMILY_INET = ADDRESS_FAMILY(AF_INET)
#elseif canImport(Darwin)
private let ADDRESS_FAMILY_INET = sa_family_t(AF_INET)
private func Darwin_or_Glibc_close(_ fd: Int32) -> Int32 { Darwin.close(fd) }
#else
private let ADDRESS_FAMILY_INET = sa_family_t(AF_INET)
private func Darwin_or_Glibc_close(_ fd: Int32) -> Int32 { Glibc.close(fd) }
#endif

/// Host monotonic time in nanoseconds. On Windows this is QPC, the same clock
/// the capture shim stamps frames with.
public enum SpikeClock {
    #if os(Windows)
    private static let frequency: Int64 = {
        var value = LARGE_INTEGER()
        QueryPerformanceFrequency(&value)
        return value.QuadPart
    }()

    public static func nanos(fromTicks ticks: Int64) -> UInt64 {
        let whole = ticks / frequency
        let rest = ticks % frequency
        return UInt64(whole) &* 1_000_000_000 &+ UInt64(rest * 1_000_000_000 / frequency)
    }

    public static func now() -> UInt64 {
        var value = LARGE_INTEGER()
        QueryPerformanceCounter(&value)
        return nanos(fromTicks: value.QuadPart)
    }
    #elseif canImport(Darwin)
    public static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    #else
    public static func now() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }
    #endif
}
