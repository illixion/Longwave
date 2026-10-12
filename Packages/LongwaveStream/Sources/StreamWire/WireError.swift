// StreamWire: the Native v3 wire types (NATIVE_V3_PROTOCOL.md section 4).
//
// The module is deliberately Foundation-free: it has to build on Windows and
// Linux, and Foundation would pull ICU (about 35 MB) into the Windows host for
// nothing. Only the Swift standard library is used.

/// Why a decode (or an encode of an invalid value) failed. Every parser in
/// StreamWire reports problems through this type and never traps, whatever the
/// input. The string payloads name the field, as `type.field`, for logs.
public enum WireError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The input ended inside a field.
    case truncated
    /// A value decoded completely but bytes were left over.
    case trailingBytes(Int)
    /// A varint ran past `Varint.maxLength` bytes.
    case varintTooLong
    /// A varint used more bytes than its value needs. Rejected so that every
    /// value has exactly one encoding.
    case nonCanonicalVarint
    /// A length or count is over its limit.
    case tooLarge(String)
    /// A field holds a value outside its allowed set or range, or a reserved
    /// bit is set.
    case invalid(String)
    /// The same item appears twice where only one is allowed.
    case duplicate(String)
    /// A required item is absent.
    case missing(String)
    /// Fields are individually valid but contradict each other.
    case inconsistent(String)

    public var description: String {
        switch self {
        case .truncated: "input truncated"
        case .trailingBytes(let count): "\(count) trailing bytes"
        case .varintTooLong: "varint too long"
        case .nonCanonicalVarint: "non-canonical varint"
        case .tooLarge(let field): "\(field) too large"
        case .invalid(let field): "\(field) invalid"
        case .duplicate(let field): "\(field) duplicated"
        case .missing(let field): "\(field) missing"
        case .inconsistent(let field): "\(field) inconsistent"
        }
    }
}
