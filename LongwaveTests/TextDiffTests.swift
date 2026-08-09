import XCTest
@testable import Longwave

/// `TextDiff.delta` powers the soft-keyboard mirror: it turns a (old → new)
/// text-field edit into a backspace count + an insert string via a common
/// prefix. These cover the append / delete / replace / dictation-rewrite cases
/// the append-only diff used to get wrong.
final class TextDiffTests: XCTestCase {

    func testAppend() {
        let d = TextDiff.delta(old: "hel", new: "hello")
        XCTAssertEqual(d.deleteCount, 0)
        XCTAssertEqual(d.insert, "lo")
    }

    func testPureDeletion() {
        let d = TextDiff.delta(old: "hello", new: "hel")
        XCTAssertEqual(d.deleteCount, 2)
        XCTAssertEqual(d.insert, "")
    }

    func testReplaceTail() {
        // "running" -> "ran": shared prefix "r", delete "unning" (6), insert "an".
        let d = TextDiff.delta(old: "running", new: "ran")
        XCTAssertEqual(d.deleteCount, 6)
        XCTAssertEqual(d.insert, "an")
    }

    func testDictationMidStringRewrite() {
        // Dictation replaces a whole word: "i scream" -> "ice cream".
        // Shared prefix "i", delete " scream" (7), insert "ce cream".
        let d = TextDiff.delta(old: "i scream", new: "ice cream")
        XCTAssertEqual(d.deleteCount, 7)
        XCTAssertEqual(d.insert, "ce cream")
    }

    func testNoChange() {
        let d = TextDiff.delta(old: "same", new: "same")
        XCTAssertEqual(d.deleteCount, 0)
        XCTAssertEqual(d.insert, "")
    }

    func testFromEmpty() {
        let d = TextDiff.delta(old: "", new: "hi")
        XCTAssertEqual(d.deleteCount, 0)
        XCTAssertEqual(d.insert, "hi")
    }

    func testToEmpty() {
        let d = TextDiff.delta(old: "bye", new: "")
        XCTAssertEqual(d.deleteCount, 3)
        XCTAssertEqual(d.insert, "")
    }

    func testApplyingDeltaReconstructsNew() {
        // Property: deleting `deleteCount` from old's tail and appending insert
        // must reproduce new.
        let cases = [("running", "ran"), ("i scream", "ice cream"),
                     ("hello", "hel"), ("", "abc"), ("abc", ""), ("foo", "foobar")]
        for (old, new) in cases {
            let d = TextDiff.delta(old: old, new: new)
            var reconstructed = old
            reconstructed.removeLast(d.deleteCount)
            reconstructed += d.insert
            XCTAssertEqual(reconstructed, new, "delta(\(old) → \(new)) didn't reconstruct")
        }
    }
}
