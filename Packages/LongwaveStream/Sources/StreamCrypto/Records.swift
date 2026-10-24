import Crypto
import StreamWire

/// The kind of a v3 datagram: the low four bits of its first byte. Bit 4 is the
/// key phase on transport packets and zero otherwise; bits 5 to 7 are reserved
/// and must be zero.
public enum PacketKind: UInt8, Sendable, CaseIterable {
    case initiation = 1
    case response = 2
    case transport = 3

    static let kindMask: UInt8 = 0x0F
    static let keyPhaseBit: UInt8 = 0x10
    static let reservedMask: UInt8 = 0xE0

    /// The kind of `datagram`, or nil for an empty one, reserved bits or an unknown
    /// kind. Such datagrams are dropped without a reply.
    public static func of(_ datagram: some Collection<UInt8>) -> PacketKind? {
        guard let first = datagram.first, first & reservedMask == 0 else { return nil }
        guard let kind = PacketKind(rawValue: first & kindMask) else { return nil }
        if kind != .transport, first & keyPhaseBit != 0 { return nil }
        return kind
    }
}

/// The AEAD that seals records after the handshake. The host picks one of the
/// client's offer: AES-256-GCM where the hardware accelerates it (Apple silicon,
/// x86 AES-NI, ARMv8 crypto extensions), ChaCha20-Poly1305 otherwise.
public enum RecordCipher: UInt8, Sendable, CaseIterable, CustomStringConvertible {
    case aes256GCM = 0
    case chaCha20Poly1305 = 1

    /// Bit in the initiation's cipher offer.
    public var offerBit: UInt8 { 1 << rawValue }

    /// Packets one key may seal before the sender rekeys. AES-GCM's is the
    /// confidentiality limit of RFC 9001 section 6.6 (2^23 packets); ChaCha20-Poly1305
    /// has no practical one, so it rekeys on the section 3 interval.
    public var packetsPerKey: UInt64 {
        switch self {
        case .aes256GCM: 1 << 23
        case .chaCha20Poly1305: 1 << 32
        }
    }

    /// Forgeries a receive key tolerates before the session must end (RFC 9001
    /// section 6.6).
    public var integrityLimit: UInt64 {
        switch self {
        case .aes256GCM: 1 << 52
        case .chaCha20Poly1305: 1 << 36
        }
    }

    public var description: String {
        switch self {
        case .aes256GCM: "AES-256-GCM"
        case .chaCha20Poly1305: "ChaCha20-Poly1305"
        }
    }

    static func offer(_ ciphers: some Sequence<RecordCipher>) -> UInt8 {
        ciphers.reduce(0) { $0 | $1.offerBit }
    }

    static func offered(in mask: UInt8) -> [RecordCipher] {
        allCases.filter { mask & $0.offerBit != 0 }
    }
}

/// The cleartext header of a transport packet, authenticated as associated data:
/// `flags u8 | receiver connection ID u32 | packet number u64`, little-endian.
public struct RecordHeader: Sendable, Equatable {
    public static let size = DatagramLayout.outerHeaderSize

    public var keyPhase: Bool
    public var receiverIndex: UInt32
    public var packetNumber: UInt64

    public init(keyPhase: Bool, receiverIndex: UInt32, packetNumber: UInt64) {
        self.keyPhase = keyPhase
        self.receiverIndex = receiverIndex
        self.packetNumber = packetNumber
    }

    /// Reads the header so the caller can route by `receiverIndex`.
    public init(parsing datagram: some Collection<UInt8>) throws(StreamCryptoError) {
        guard PacketKind.of(datagram) == .transport else { throw .malformed("record.flags") }
        guard datagram.count >= Self.size + DatagramLayout.authenticationTagSize else { throw .malformed("record.length") }
        let bytes = Array(datagram.prefix(Self.size))
        keyPhase = bytes[0] & PacketKind.keyPhaseBit != 0
        receiverIndex = littleEndian(bytes[1..<5])
        packetNumber = littleEndian(bytes[5..<13])
    }

    var bytes: [UInt8] {
        var writer = WireWriter(reservingCapacity: Self.size)
        writer.writeUInt8(PacketKind.transport.rawValue | (keyPhase ? PacketKind.keyPhaseBit : 0))
        writer.writeUInt32(receiverIndex)
        writer.writeUInt64(packetNumber)
        return writer.bytes
    }
}

/// One direction's sealing key. Generation 0 comes from the Noise split; each
/// rekey derives the next from the last, and the key phase bit flips with it.
struct RecordKey: Sendable {
    let cipher: RecordCipher
    let bytes: [UInt8]
    let generation: UInt64
    let key: SymmetricKey

    static let recordLabel = "Longwave-NS3 record "
    static let rekeyLabel = Array("Longwave-NS3 rekey".utf8)

    init(cipher: RecordCipher, splitKey: [UInt8]) {
        self.init(cipher: cipher, bytes: Self.derive(splitKey, info: Array((Self.recordLabel + cipher.description).utf8)),
                  generation: 0)
    }

    private init(cipher: RecordCipher, bytes: [UInt8], generation: UInt64) {
        self.cipher = cipher
        self.bytes = bytes
        self.generation = generation
        key = SymmetricKey(data: bytes)
    }

    var keyPhase: Bool { generation & 1 == 1 }

    func next() -> RecordKey {
        RecordKey(cipher: cipher, bytes: Self.derive(bytes, info: Self.rekeyLabel), generation: generation + 1)
    }

    private static func derive(_ input: [UInt8], info: [UInt8]) -> [UInt8] {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: input), info: info, outputByteCount: 32)
            .withUnsafeBytes { Array($0) }
    }

    /// 32 bits of zeros, then the packet number little-endian, for both ciphers.
    static func nonce(_ packetNumber: UInt64) -> [UInt8] {
        Noise.chaChaNonce(packetNumber)
    }

    func seal(_ plaintext: [UInt8], header: [UInt8], packetNumber: UInt64) throws(StreamCryptoError) -> [UInt8] {
        let nonce = Self.nonce(packetNumber)
        do {
            switch cipher {
            case .aes256GCM:
                let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: header)
                return header + box.ciphertext + box.tag
            case .chaCha20Poly1305:
                let box = try ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: nonce), authenticating: header)
                return header + box.ciphertext + box.tag
            }
        } catch {
            throw .invalidState("record seal")
        }
    }

    func open(_ datagram: [UInt8], packetNumber: UInt64) throws(StreamCryptoError) -> [UInt8] {
        let header = datagram[..<RecordHeader.size]
        let tagStart = datagram.count - DatagramLayout.authenticationTagSize
        let ciphertext = datagram[RecordHeader.size..<tagStart]
        let tag = datagram[tagStart...]
        let nonce = Self.nonce(packetNumber)
        do {
            switch cipher {
            case .aes256GCM:
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
                return Array(try AES.GCM.open(box, using: key, authenticating: header))
            case .chaCha20Poly1305:
                let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
                return Array(try ChaChaPoly.open(box, using: key, authenticating: header))
            }
        } catch {
            throw .authenticationFailed
        }
    }
}

/// Seals one direction's transport packets.
///
/// Packet numbers start at 0 and are never reused. The key rotates after
/// `cipher.packetsPerKey` packets or `rekeyInterval` nanoseconds, whichever comes
/// first; the receiver follows the key phase bit.
public struct RecordSender: Sendable {
    /// One hour, in nanoseconds (section 3).
    public static let defaultRekeyInterval: UInt64 = 3_600_000_000_000

    public let receiverIndex: UInt32
    public var cipher: RecordCipher { key.cipher }
    public var generation: UInt64 { key.generation }
    public private(set) var nextPacketNumber: UInt64 = 0

    private var key: RecordKey
    private var packetsUnderKey: UInt64 = 0
    private var keyStartedAt: UInt64
    private let rekeyInterval: UInt64
    private let packetsPerKey: UInt64

    init(key: RecordKey, receiverIndex: UInt32, now: UInt64,
         rekeyInterval: UInt64 = RecordSender.defaultRekeyInterval, packetsPerKey: UInt64? = nil) {
        self.key = key
        self.receiverIndex = receiverIndex
        keyStartedAt = now
        self.rekeyInterval = rekeyInterval
        self.packetsPerKey = packetsPerKey ?? key.cipher.packetsPerKey
    }

    /// Seals `body` (the frames of section 4.1) into one datagram.
    /// `now` is monotonic nanoseconds.
    public mutating func seal(_ body: [UInt8], now: UInt64) throws(StreamCryptoError) -> (packetNumber: UInt64, datagram: [UInt8]) {
        guard nextPacketNumber < UInt64.max else { throw .packetNumbersExhausted }
        if packetsUnderKey >= packetsPerKey || (now >= keyStartedAt && now - keyStartedAt >= rekeyInterval) {
            key = key.next()
            packetsUnderKey = 0
            keyStartedAt = now
        }
        let number = nextPacketNumber
        let header = RecordHeader(keyPhase: key.keyPhase, receiverIndex: receiverIndex, packetNumber: number).bytes
        let datagram = try key.seal(body, header: header, packetNumber: number)
        nextPacketNumber += 1
        packetsUnderKey += 1
        return (number, datagram)
    }
}

/// Opens one direction's transport packets: replay window, key phases, and the
/// integrity limit.
///
/// After the peer rekeys, the previous key is kept for packets reordered across
/// the switch, and dropped once the window has moved past the switch point, since
/// anything older is rejected as a replay anyway.
public struct RecordReceiver: Sendable {
    public let localIndex: UInt32
    public var cipher: RecordCipher { current.cipher }
    public var generation: UInt64 { current.generation }
    /// Forgeries seen so far; at `cipher.integrityLimit` every open fails.
    public private(set) var authenticationFailures: UInt64 = 0
    /// Whether any packet has authenticated: the peer has proven it holds the
    /// session keys (the host's key-confirmation rule, section 3).
    public var hasAcceptedPacket: Bool { window.highest != nil }

    private var current: RecordKey
    private var previous: RecordKey?
    /// The first packet number accepted under `current`.
    private var switchedAt: UInt64 = 0
    private var window: ReplayWindow
    private let integrityLimit: UInt64

    init(key: RecordKey, localIndex: UInt32, windowSize: Int = ReplayWindow.defaultSize, integrityLimit: UInt64? = nil) {
        current = key
        self.localIndex = localIndex
        window = ReplayWindow(size: windowSize)
        self.integrityLimit = integrityLimit ?? key.cipher.integrityLimit
    }

    /// Authenticates and decrypts one transport datagram, returning its body.
    /// Any error means drop the datagram; only `.integrityLimitReached` ends the
    /// session.
    public mutating func open(_ datagram: [UInt8]) throws(StreamCryptoError) -> (packetNumber: UInt64, body: [UInt8]) {
        guard authenticationFailures < integrityLimit else { throw .integrityLimitReached }
        let header = try RecordHeader(parsing: datagram)
        guard header.receiverIndex == localIndex else { throw .unknownConnection }
        let number = header.packetNumber
        guard window.check(number) else { throw .replayed }

        if previous != nil, let highest = window.highest, highest >= switchedAt &+ UInt64(window.size) {
            previous = nil
        }

        if header.keyPhase == current.keyPhase {
            let body = try attempt(current, datagram, number)
            accept(number)
            return (number, body)
        }
        let isNewest = window.highest.map { number > $0 } ?? true
        if let previous, let body = try? previous.open(datagram, packetNumber: number) {
            accept(number)
            return (number, body)
        }
        // Not the old key. Only a packet newer than any accepted can be the peer's
        // next one, including a rekey before the old key was dropped. One failure
        // is counted per forged packet, however many keys it was tried with.
        guard isNewest else {
            authenticationFailures += 1
            throw .authenticationFailed
        }
        let next = current.next()
        let body = try attempt(next, datagram, number)
        previous = current
        current = next
        switchedAt = number
        accept(number)
        return (number, body)
    }

    private mutating func attempt(_ key: RecordKey, _ datagram: [UInt8], _ number: UInt64) throws(StreamCryptoError) -> [UInt8] {
        do {
            return try key.open(datagram, packetNumber: number)
        } catch {
            authenticationFailures += 1
            throw error
        }
    }

    private mutating func accept(_ number: UInt64) {
        window.accept(number)
    }
}

func littleEndian<T: FixedWidthInteger>(_ bytes: ArraySlice<UInt8>) -> T {
    var value: T = 0
    for (offset, byte) in bytes.enumerated() { value |= T(byte) << (8 * offset) }
    return value
}
