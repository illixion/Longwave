import Foundation

/// The Mac half of the Longwave KVM dongle's USB serial protocol — the link
/// that carries HID reports to the ESP32, which relays them to the Vision Pro
/// as a Bluetooth keyboard and mouse. `Firmware/kvm-dongle/PROTOCOL.md` is the
/// normative description; this is a direct implementation of it, and
/// `Firmware/kvm-dongle/tools/kvmctl.py` is the reference client to compare
/// against when something looks wrong.
///
/// Everything mutable lives on one serial queue, which is what makes the
/// ordering guarantees work: the dongle answers commands strictly in order, so
/// replies are matched to a FIFO of waiters, and a key press frame can never
/// overtake the release frame that follows it. An actor would not do — its
/// reentrancy lets two `await`ing callers interleave, and two resumed tasks are
/// not guaranteed to run in the order they were created, which is exactly the
/// guarantee a keyboard needs.
final class KVMDongleLink: @unchecked Sendable {

    // MARK: - Wire vocabulary

    enum Command: UInt8 {
        case ping = 0x01
        case status = 0x02
        case keyReport = 0x03
        case mouse = 0x04
        case mouseButtons = 0x05
        case consumer = 0x06
        case releaseAll = 0x07
        case forgetBonds = 0x08
    }

    enum LinkState: UInt8, Sendable {
        case idle = 0, advertising = 1, connected = 2, ready = 3

        var title: String {
            switch self {
            case .idle: return "Idle"
            case .advertising: return "Advertising"
            case .connected: return "Connected, pairing"
            case .ready: return "Ready"
            }
        }
    }

    /// The 16-byte status block (§4.2), decoded.
    struct Status: Sendable, Equatable {
        var protocolVersion: UInt8
        var firmware: String
        var state: LinkState
        var flags: UInt8
        var bondCount: UInt8
        var ledState: UInt8
        var address: String
        var uptime: UInt16

        var isConnected: Bool { flags & 0x01 != 0 }
        var isEncrypted: Bool { flags & 0x02 != 0 }
        var isAdvertising: Bool { flags & 0x04 != 0 }
        var hasBond: Bool { flags & 0x08 != 0 }
        var keyboardSubscribed: Bool { flags & 0x10 != 0 }
        var mouseSubscribed: Bool { flags & 0x20 != 0 }
        var consumerSubscribed: Bool { flags & 0x40 != 0 }

        /// True when the headset will actually receive something we send. The
        /// subscription bits matter as much as the connection: a host that has
        /// connected but not enabled notifications answers `NOT_SUBSCRIBED` to
        /// every report. visionOS enables them per report characteristic and
        /// not always at once — observed connected and encrypted with none of
        /// the three on — so this asks for *one*, and an individual report kind
        /// that is still unsubscribed simply goes nowhere until it is.
        var acceptsInput: Bool {
            isConnected && isEncrypted && (keyboardSubscribed || mouseSubscribed)
        }
    }

    enum Event: Sendable {
        case boot(firmware: String)
        case advertising
        case connected
        case encrypted(bonded: Bool)
        case disconnected(reason: UInt8)
        case leds(UInt8)
        case subscribed(UInt8)
        /// A line of the firmware's own log, which shares this UART.
        case log(String)
        /// The port went away — unplugged, or a read error. Terminal.
        case closed(reason: String?)
    }

    enum Failure: LocalizedError {
        case openFailed(String)
        case configureFailed(String)
        case notOpen
        case timedOut(Command)
        case refused(Command, code: UInt8)
        case malformedReply

        var errorDescription: String? {
            switch self {
            case .openFailed(let why): return "Could not open the dongle: \(why)"
            case .configureFailed(let why): return "Could not configure the serial port: \(why)"
            case .notOpen: return "The dongle is not connected."
            case .timedOut(let command): return "The dongle did not answer \(command) in time."
            case .refused(let command, let code): return "\(Self.errorName(code)) (\(command))"
            case .malformedReply: return "The dongle sent a reply this client could not read."
            }
        }

        static func errorName(_ code: UInt8) -> String {
            switch code {
            case 0x01: return "Checksum mismatch"
            case 0x02: return "Wrong payload length"
            case 0x03: return "Unknown command"
            case 0x04: return "Headset not connected"
            case 0x05: return "Headset has not subscribed"
            case 0x06: return "Bluetooth send failed"
            case 0x07: return "Payload out of range"
            default: return "Dongle error \(code)"
            }
        }

        /// `NOT_CONNECTED` and `NOT_SUBSCRIBED` are the normal state whenever
        /// the headset is asleep or out of range, not faults — callers show
        /// them as status rather than as errors.
        var isHeadsetAbsent: Bool {
            if case .refused(_, let code) = self { return code == 0x04 || code == 0x05 }
            return false
        }

        /// The headset is there but is not listening to *this* report kind.
        /// Worth saying out loud and worth carrying on through: the pointer
        /// still works while the keyboard is unsubscribed, and vice versa.
        var isReportUnsubscribed: Bool {
            if case .refused(_, let code) = self { return code == 0x05 }
            return false
        }
    }

    // MARK: - Ports

    /// Serial devices that could plausibly be the dongle. `cu.*` (call-out)
    /// rather than `tty.*`: opening a `tty` device blocks waiting for carrier
    /// detect, which a USB-UART bridge never asserts.
    static func availablePorts() -> [String] {
        let prefixes = ["cu.usbserial", "cu.wchusbserial", "cu.SLAB_USBtoUART", "cu.usbmodem"]
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return entries
            .filter { name in prefixes.contains { name.hasPrefix($0) } }
            .sorted()
            .map { "/dev/" + $0 }
    }

    // MARK: - State (serial queue only)

    private let queue = DispatchQueue(label: "pro.longwave.kvm.link")
    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var inbox: [UInt8] = []
    private var logLine: [UInt8] = []
    private var waiters: [(id: UInt64, command: Command, finish: (Result<[UInt8], Error>) -> Void)] = []
    private var nextWaiterID: UInt64 = 0
    private var onEvent: (@Sendable (Event) -> Void)?

    var isOpen: Bool { queue.sync { fd >= 0 } }

    // MARK: - Opening and closing

    /// Opens `path` at 460800 8N1, waits for the board to settle, and returns
    /// its status. Events (including the firmware's log lines) arrive on
    /// `onEvent` from an arbitrary queue until `close()`.
    func open(path: String, onEvent: @escaping @Sendable (Event) -> Void) async throws -> Status {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.openLocked(path: path, onEvent: onEvent)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        // Opening the port toggles DTR/RTS on most USB-UART bridges, which
        // resets the board. Give it time to boot before asking anything, and
        // throw away the mask-ROM bootloader's 115200-baud noise.
        try? await Task.sleep(for: .milliseconds(400))
        queue.sync {
            guard fd >= 0 else { return }
            tcflush(fd, TCIFLUSH)
            inbox.removeAll()
            logLine.removeAll()
        }
        return try await status()
    }

    private func openLocked(path: String, onEvent: @escaping @Sendable (Event) -> Void) throws {
        closeLocked(reason: nil)

        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw Failure.openFailed(String(cString: strerror(errno)) + " (\(path))")
        }
        // Claim the port, so a stray `kvmctl.py` (or a second copy of this
        // app) cannot interleave frames with ours.
        if ioctl(descriptor, TIOCEXCL) == -1 {
            let why = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw Failure.openFailed("the port is in use — \(why)")
        }

        var settings = termios()
        guard tcgetattr(descriptor, &settings) == 0 else {
            let why = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw Failure.configureFailed(why)
        }
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        settings.c_cflag &= ~tcflag_t(CRTSCTS)
        withUnsafeMutablePointer(to: &settings.c_cc) { control in
            control.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { slots in
                slots[Int(VMIN)] = 0
                slots[Int(VTIME)] = 0
            }
        }
        cfsetspeed(&settings, speed_t(Self.baudRate))
        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            let why = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw Failure.configureFailed(why)
        }
        // Darwin's termios tops out at B230400, so the real rate is set through
        // IOKit's serial ioctl — the same thing pyserial does for a non-standard
        // speed on macOS. `IOSSIOSPEED` is `_IOW('T', 2, speed_t)`, which Swift
        // cannot evaluate from the C macro.
        var speed = speed_t(Self.baudRate)
        if ioctl(descriptor, Self.iossioSpeed, &speed) == -1 {
            let why = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw Failure.configureFailed("\(Self.baudRate) baud rejected — \(why)")
        }

        fd = descriptor
        self.onEvent = onEvent

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(descriptor) }
        reader = source
        source.resume()
    }

    func close() {
        queue.sync { closeLocked(reason: nil) }
    }

    private func closeLocked(reason: String?) {
        guard fd >= 0 || reader != nil else { return }
        reader?.cancel()   // the cancel handler closes the descriptor
        reader = nil
        fd = -1
        inbox.removeAll()
        logLine.removeAll()
        let stranded = waiters
        waiters.removeAll()
        for waiter in stranded { waiter.finish(.failure(Failure.notOpen)) }
        let sink = onEvent
        onEvent = nil
        if let sink { sink(.closed(reason: reason)) }
    }

    // MARK: - Commands

    @discardableResult
    func send(_ command: Command, payload: [UInt8] = []) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.fd >= 0 else {
                    continuation.resume(throwing: Failure.notOpen)
                    return
                }
                let id = self.nextWaiterID
                self.nextWaiterID += 1
                var settled = false
                let finish: (Result<[UInt8], Error>) -> Void = { result in
                    guard !settled else { return }
                    settled = true
                    continuation.resume(with: result)
                }
                self.waiters.append((id: id, command: command, finish: finish))
                // Strong self on purpose: this holds the link alive for at
                // most one timeout, and a weak capture here would only race
                // the reply it exists to give up on.
                self.queue.asyncAfter(deadline: .now() + Self.replyTimeout) {
                    guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                    self.waiters.remove(at: index)
                    finish(.failure(Failure.timedOut(command)))
                }
                do {
                    try self.writeLocked(Self.encode(command, payload))
                } catch {
                    if let index = self.waiters.firstIndex(where: { $0.id == id }) {
                        self.waiters.remove(at: index)
                    }
                    finish(.failure(error))
                }
            }
        }
    }

    func ping() async throws -> Duration {
        let started = ContinuousClock.now
        _ = try await send(.ping, payload: [0x4C, 0x57])
        return ContinuousClock.now - started
    }

    func status() async throws -> Status {
        let payload = try await send(.status)
        guard let status = Self.decodeStatus(payload) else { throw Failure.malformedReply }
        return status
    }

    /// Sends a boot-protocol keyboard report verbatim: modifiers, a reserved
    /// zero, then up to six usage IDs.
    func sendKeyboard(_ report: [UInt8]) async throws {
        var padded = report
        padded.append(contentsOf: [UInt8](repeating: 0, count: max(0, 8 - padded.count)))
        try await send(.keyReport, payload: Array(padded.prefix(8)))
    }

    func sendMouse(dx: Int16, dy: Int16, buttons: UInt8, wheel: Int8, pan: Int8) async throws {
        let payload: [UInt8] = [
            UInt8(truncatingIfNeeded: dx), UInt8(truncatingIfNeeded: dx >> 8),
            UInt8(truncatingIfNeeded: dy), UInt8(truncatingIfNeeded: dy >> 8),
            buttons,
            UInt8(bitPattern: wheel),
            UInt8(bitPattern: pan),
        ]
        try await send(.mouse, payload: payload)
    }

    func sendConsumer(usage: UInt16, pressed: Bool) async throws {
        try await send(.consumer, payload: [
            UInt8(truncatingIfNeeded: usage), UInt8(truncatingIfNeeded: usage >> 8),
            pressed ? 1 : 0,
        ])
    }

    func releaseAll() async throws {
        try await send(.releaseAll)
    }

    func forgetBonds() async throws {
        try await send(.forgetBonds)
    }

    // MARK: - Framing

    private static let baudRate = 460_800
    private static let iossioSpeed: UInt = 0x8008_5402
    private static let replyTimeout: TimeInterval = 1.5
    private static let startOfFrame: UInt8 = 0xA5
    private static let maxPayload = 64

    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 {
                crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : (crc << 1)
            }
        }
        return crc
    }

    static func encode(_ command: Command, _ payload: [UInt8]) -> [UInt8] {
        let body = [command.rawValue, UInt8(payload.count)] + payload
        return [startOfFrame] + body + [checksum(body)]
    }

    static func decodeStatus(_ payload: [UInt8]) -> Status? {
        guard payload.count >= 16, let state = LinkState(rawValue: payload[4]) else { return nil }
        let address = (8...13).reversed().map { String(format: "%02x", payload[$0]) }.joined(separator: ":")
        return Status(
            protocolVersion: payload[0],
            firmware: "\(payload[1]).\(payload[2]).\(payload[3])",
            state: state,
            flags: payload[5],
            bondCount: payload[6],
            ledState: payload[7],
            address: address,
            uptime: UInt16(payload[14]) | (UInt16(payload[15]) << 8))
    }

    private func writeLocked(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer in
                Darwin.write(fd, buffer.baseAddress! + offset, bytes.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if errno == EAGAIN || errno == EINTR {
                usleep(200)
                continue
            }
            throw Failure.openFailed(String(cString: strerror(errno)))
        }
    }

    private func readAvailable() {
        guard fd >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = chunk.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                inbox.append(contentsOf: chunk[0..<count])
                if count < chunk.count { break }
                continue
            }
            if count == 0 { break }
            if errno == EAGAIN || errno == EINTR { break }
            closeLocked(reason: String(cString: strerror(errno)))
            return
        }
        parseInbox()
    }

    /// Pulls frames out of `inbox`, treating everything that is not a frame as
    /// firmware log text — which is exactly what it is, since the ESP-IDF
    /// console shares this UART and can never emit the `0xA5` start byte.
    private func parseInbox() {
        while !inbox.isEmpty {
            guard let start = inbox.firstIndex(of: Self.startOfFrame) else {
                absorbLog(inbox)
                inbox.removeAll()
                return
            }
            if start > 0 {
                absorbLog(Array(inbox[0..<start]))
                inbox.removeFirst(start)
            }
            guard inbox.count >= 3 else { return }
            let length = Int(inbox[2])
            guard length <= Self.maxPayload else {
                // Not a frame after all: that 0xA5 was log text.
                inbox.removeFirst()
                continue
            }
            guard inbox.count >= length + 4 else { return }
            let body = Array(inbox[1...(2 + length)])
            let expected = inbox[3 + length]
            guard Self.checksum(body) == expected else {
                inbox.removeFirst()
                continue
            }
            let type = body[0]
            let payload = Array(body.dropFirst(2))
            inbox.removeFirst(length + 4)
            dispatch(type: type, payload: payload)
        }
    }

    private func dispatch(type: UInt8, payload: [UInt8]) {
        switch type {
        case 0x85: // EVENT — unsolicited, never an answer to a command
            guard let code = payload.first else { return }
            emit(event(code: code, data: Array(payload.dropFirst())))
        case 0x81: // ACK
            guard !waiters.isEmpty else { return }
            let waiter = waiters.removeFirst()
            waiter.finish(.success(Array(payload.dropFirst())))
        case 0x82: // NACK
            guard !waiters.isEmpty else { return }
            let waiter = waiters.removeFirst()
            let code = payload.count >= 2 ? payload[1] : 0
            waiter.finish(.failure(Failure.refused(waiter.command, code: code)))
        case 0x83: // STATUS
            guard !waiters.isEmpty else { return }
            let waiter = waiters.removeFirst()
            waiter.finish(.success(payload))
        default:
            break
        }
    }

    private func event(code: UInt8, data: [UInt8]) -> Event {
        switch code {
        case 0x01: return .boot(firmware: data.count >= 4 ? "\(data[1]).\(data[2]).\(data[3])" : "?")
        case 0x02: return .advertising
        case 0x03: return .connected
        case 0x04: return .encrypted(bonded: data.first == 1)
        case 0x05: return .disconnected(reason: data.first ?? 0)
        case 0x06: return .leds(data.first ?? 0)
        case 0x07: return .subscribed(data.first ?? 0)
        default: return .log("unknown event 0x\(String(code, radix: 16))")
        }
    }

    /// Accumulates non-frame bytes into whole log lines.
    private func absorbLog(_ bytes: [UInt8]) {
        for byte in bytes {
            if byte == 0x0A || byte == 0x0D {
                flushLogLine()
            } else if byte >= 0x20 && byte < 0x7F {
                logLine.append(byte)
                if logLine.count > 240 { flushLogLine() }
            }
            // Anything else is boot-ROM noise at the wrong baud: drop it.
        }
    }

    private func flushLogLine() {
        defer { logLine.removeAll(keepingCapacity: true) }
        let text = String(decoding: logLine, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        emit(.log(text))
    }

    private func emit(_ event: Event) {
        onEvent?(event)
    }
}
