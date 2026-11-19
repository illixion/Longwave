import XCTest
@testable import Longwave

final class ITermCommandsTests: XCTestCase {
    func testResultStripsMarkerOnSuccess() throws {
        let out = try ITermCommands.result("banner\n[{\"a\":1}]\n\(ITermCommands.exitMarker)0\n")
        XCTAssertEqual(out, "banner\n[{\"a\":1}]\n")
    }

    func testResultThrowsToolMessageOnFailure() {
        let raw = "[notice] pip is old\niterm-tool: 0 sessions match 'x'\n\(ITermCommands.exitMarker)1\n"
        XCTAssertThrowsError(try ITermCommands.result(raw)) { error in
            XCTAssertEqual(error.localizedDescription, "iterm-tool: 0 sessions match 'x'")
        }
    }

    func testResultWithoutMarkerFails() {
        XCTAssertThrowsError(try ITermCommands.result("Connection closed"))
    }

    func testDecodeSkipsBannerLinesAndGroups() throws {
        let json = """
        welcome to zsh
        [{"w":1,"t":1,"window_id":"pty-A","tab_id":"1","session_id":"S1","name":"zsh","title":"build","job":"zsh","cwd":"/tmp","cols":80,"rows":24,"current_tab":true,"current_session":true,"front_window":true},\
        {"w":1,"t":1,"window_id":"pty-A","tab_id":"1","session_id":"S2","name":"vim","title":"build","job":"vim","cwd":null,"cols":40,"rows":24,"current_tab":true,"current_session":false,"front_window":true},\
        {"w":2,"t":1,"window_id":"pty-B","tab_id":"4","session_id":"S3","name":"claude","title":"","job":"2.1.0","cwd":"/r","cols":100,"rows":50,"current_tab":true,"current_session":true,"front_window":false}]
        """
        let sessions = try ITermCommands.decodeJSON([ITermCommands.Session].self, from: json)
        let windows = ITermCommands.windows(from: sessions)
        XCTAssertEqual(windows.map(\.id), ["pty-A", "pty-B"])
        XCTAssertEqual(windows[0].tabs.count, 1)
        XCTAssertEqual(windows[0].tabs[0].sessions.map(\.sessionID), ["S1", "S2"])
        XCTAssertTrue(windows[0].isFront)
        XCTAssertFalse(windows[1].isFront)
        // An empty tab title falls back to the session name.
        XCTAssertEqual(windows[1].tabs[0].title, "claude")
    }

    func testInvocationQuotesArgumentsAndPrefersInstalledCopy() {
        let line = ITermCommands.invocation(["rename", "S1", "it's mine"])
        XCTAssertTrue(line.contains("'rename' 'S1' 'it'\\''s mine'"))
        XCTAssertTrue(line.hasPrefix("T=\"$HOME/Library/Application Support/Longwave/iterm/iterm-tool\""))
        XCTAssertTrue(ITermCommands.viewCommand(sessionID: "S1").hasPrefix("zsh -lic "))
    }

    /// `exec` belongs on
    /// the tool call, not in front of the `T=` assignment.
    func testViewExecSitsOnTheToolCall() {
        let inner = ITermCommands.invocation(["view", "S1"], exec: true)
        XCTAssertFalse(inner.hasPrefix("exec"))
        XCTAssertTrue(inner.contains("exec \"$T\" 'view' 'S1'"))
        XCTAssertTrue(inner.contains("then exec iterm-tool 'view' 'S1'"))
    }
}
