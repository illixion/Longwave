import XCTest
@testable import Longwave

final class SavedConnectionNativeTests: XCTestCase {
    func testUnityDefaultsOffAndPersistsThroughAccessor() {
        let connection = SavedConnection(
            hostname: "mac.local",
            connectionType: .native
        )

        XCTAssertFalse(connection.nativeUnityEnabled)
        XCTAssertFalse(connection.nativeUnityAutoShow)
        connection.nativeUnityEnabled = true
        connection.nativeUnityAutoShow = true
        XCTAssertTrue(connection.nativeUnityEnabled)
        XCTAssertTrue(connection.nativeUnityAutoShow)
    }

    func testUnityManagerPersistsAutoShowAndTracksVisibilityIntent() {
        let connection = SavedConnection(
            hostname: "mac.local",
            connectionType: .native
        )
        connection.nativeUnityEnabled = true
        connection.nativeUnityAutoShow = true

        let manager = MacNativeStreamManager()
        manager.prepare(for: connection)

        XCTAssertTrue(manager.unityEnabled)
        XCTAssertTrue(manager.unityAutoShow)
        XCTAssertTrue(manager.unityVisibleWindowIDs.isEmpty)

        manager.markUnityWindowVisible(42)
        XCTAssertEqual(manager.unityVisibleWindowIDs, [42])

        manager.markUnityWindowHidden(42, suppressAutoShow: true)
        XCTAssertTrue(manager.unityVisibleWindowIDs.isEmpty)
        XCTAssertEqual(manager.unityAutoShowSuppressedWindowIDs, [42])

        manager.markUnityWindowVisible(42)
        XCTAssertEqual(manager.unityVisibleWindowIDs, [42])
        XCTAssertTrue(manager.unityAutoShowSuppressedWindowIDs.isEmpty)

        manager.setUnityAutoShow(false)
        XCTAssertFalse(manager.unityAutoShow)
        XCTAssertFalse(connection.nativeUnityAutoShow)

        manager.markUnityWindowHidden(42, suppressAutoShow: true)
        manager.setUnityAutoShow(true)
        XCTAssertTrue(manager.unityAutoShowSuppressedWindowIDs.isEmpty)
    }

    func testConnectedStatusDoesNotImplyDesktopFramePending() {
        XCTAssertEqual(MacNativeStreamManager.State.connected.statusText, "Connected")
    }
}
