/// Sliding anti-replay window over 64-bit packet numbers (section 3, "Records,
/// replay, roaming"): WireGuard's design, after RFC 6479.
///
/// A packet number is accepted once. Anything more than `size - 1` behind the
/// highest accepted number is rejected as too old. `check` runs before AEAD
/// (cheap rejection) and `accept` only after the packet authenticated, so a
/// forgery can't move the window.
public struct ReplayWindow: Sendable, Equatable {
    public static let defaultSize = 2048

    public let size: Int
    private var words: [UInt64]
    public private(set) var highest: UInt64?

    public init(size: Int = ReplayWindow.defaultSize) {
        precondition(size > 0 && size % 64 == 0, "window size must be a positive multiple of 64")
        self.size = size
        words = [UInt64](repeating: 0, count: size / 64)
    }

    /// Whether `number` would be accepted.
    public func check(_ number: UInt64) -> Bool {
        guard let highest else { return true }
        if number > highest { return true }
        guard highest - number < UInt64(size) else { return false }
        return !isSet(number)
    }

    /// Records `number`. Returns false, changing nothing, when `check` would.
    @discardableResult
    public mutating func accept(_ number: UInt64) -> Bool {
        guard check(number) else { return false }
        if let highest, number > highest {
            let advance = number - highest
            if advance >= UInt64(size) {
                for index in words.indices { words[index] = 0 }
            } else {
                // Clear the slots the window slides over: highest+1 ... number.
                var slot = highest &+ 1
                var remaining = advance
                while remaining > 0 {
                    let bit = Int(slot % UInt64(size))
                    if bit % 64 == 0, remaining >= 64 {
                        words[bit / 64] = 0
                        slot &+= 64
                        remaining -= 64
                    } else {
                        words[bit / 64] &= ~(UInt64(1) << UInt64(bit % 64))
                        slot &+= 1
                        remaining -= 1
                    }
                }
            }
            self.highest = number
        } else if highest == nil {
            highest = number
        }
        let bit = Int(number % UInt64(size))
        words[bit / 64] |= UInt64(1) << UInt64(bit % 64)
        return true
    }

    private func isSet(_ number: UInt64) -> Bool {
        let bit = Int(number % UInt64(size))
        return words[bit / 64] & (UInt64(1) << UInt64(bit % 64)) != 0
    }
}
