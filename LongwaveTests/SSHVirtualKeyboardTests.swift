import XCTest
@testable import Longwave

/// The PTY byte sequences our on-screen keyboard produces for the terminal.
@MainActor
final class SSHVirtualKeyboardTests: XCTestCase {

    private func bytes(_ key: VirtualKey, _ modifiers: VirtualModifiers = []) -> [UInt8] {
        SSHKeyboardSink.bytes(for: key, modifiers: modifiers)
    }

    private let g = VirtualKey.character(base: "g", shifted: "G")

    /// The reported bug: a latched ⌃ plus a letter just typed the letter.
    func testControlGIsTheControlByte() {
        XCTAssertEqual(bytes(g, .control), [0x07])  // BEL
        XCTAssertEqual(bytes(.character(base: "c", shifted: "C"), .control), [0x03])  // interrupt
        XCTAssertEqual(bytes(g), [0x67])            // unmodified is still "g"
    }

    func testShiftPicksTheShiftedGlyphWithoutDoubleApplying() {
        XCTAssertEqual(bytes(g, .shift), [0x47])                                  // "G"
        XCTAssertEqual(bytes(.character(base: "1", shifted: "!"), .shift), [0x21]) // "!"
        // ⌃⇧G is the same control byte as ⌃G — control folds case away.
        XCTAssertEqual(bytes(g, [.shift, .control]), [0x07])
    }

    func testAltPrefixesWithEscape() {
        XCTAssertEqual(bytes(.character(base: "f", shifted: "F"), .option), [0x1B, 0x66])
        // Combined: ESC then the control byte.
        XCTAssertEqual(bytes(.character(base: "b", shifted: "B"), [.control, .option]), [0x1B, 0x02])
    }

    func testCommandIsDroppedRatherThanMisencoded() {
        // ⌘ has no PTY encoding; the cap is disabled, but the mapping must not
        // invent bytes if it is ever reached.
        XCTAssertEqual(bytes(g, .command), [0x67])
        XCTAssertFalse(SSHKeyboardSink.supports(.modifier(.command)))
        XCTAssertFalse(SSHKeyboardSink.supports(.key(.capsLock)))
        XCTAssertTrue(SSHKeyboardSink.supports(.modifier(.control)))
    }

    func testSpecialKeysUseTheirStandardSequences() {
        XCTAssertEqual(bytes(.return), [0x0D])
        XCTAssertEqual(bytes(.escape), [0x1B])
        XCTAssertEqual(bytes(.backspace), [0x7F])
        XCTAssertEqual(bytes(.tab), [0x09])
        XCTAssertEqual(bytes(.up), [0x1B, 0x5B, 0x41])
        XCTAssertEqual(bytes(.pageUp), [0x1B, 0x5B, 0x35, 0x7E])
        XCTAssertEqual(bytes(.forwardDelete), [0x1B, 0x5B, 0x33, 0x7E])
        XCTAssertEqual(bytes(.insert), [0x1B, 0x5B, 0x32, 0x7E])
        XCTAssertEqual(bytes(.capsLock), [])
    }

    func testModifiedSpecialKeysUseTheXtermParameterForm() {
        // ESC [ 1 ; 5 D — ctrl-left (word-left), param 1 + 4·ctrl.
        XCTAssertEqual(bytes(.left, .control), Array("\u{1B}[1;5D".utf8))
        // ⇧⇥ is back-tab, not a parameterised sequence.
        XCTAssertEqual(bytes(.tab, .shift), [0x1B, 0x5B, 0x5A])
        // ESC [ 5 ; 2 ~ — shift-PageUp.
        XCTAssertEqual(bytes(.pageUp, .shift), Array("\u{1B}[5;2~".utf8))
    }

    func testFunctionKeysSpanBothEncodingFamilies() {
        XCTAssertEqual(bytes(.function(1)), Array("\u{1B}OP".utf8))
        XCTAssertEqual(bytes(.function(4)), Array("\u{1B}OS".utf8))
        // F5 up are ESC [ <n> ~ with a gap where 16 would be.
        XCTAssertEqual(bytes(.function(5)), Array("\u{1B}[15~".utf8))
        XCTAssertEqual(bytes(.function(6)), Array("\u{1B}[17~".utf8))
        XCTAssertEqual(bytes(.function(12)), Array("\u{1B}[24~".utf8))
        XCTAssertEqual(bytes(.function(13)), [])
    }

    /// Multi-digit `ESC [ <n> ; <p> ~` — the single-byte form this used to emit
    /// could not represent F5 and up at all.
    func testModifiedFunctionKeysKeepTheirMultiDigitParameter() {
        XCTAssertEqual(bytes(.function(5), .shift), Array("\u{1B}[15;2~".utf8))
        XCTAssertEqual(bytes(.function(1), .control), Array("\u{1B}[1;5P".utf8))
    }
}
