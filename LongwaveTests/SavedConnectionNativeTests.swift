import XCTest
@testable import Longwave

final class SavedConnectionNativeTests: XCTestCase {
    func testUnityDefaultsOffAndPersistsThroughAccessor() {
        let connection = SavedConnection(
            hostname: "mac.local",
            connectionType: .native
        )

        XCTAssertFalse(connection.nativeUnityEnabled)
        connection.nativeUnityEnabled = true
        XCTAssertTrue(connection.nativeUnityEnabled)
    }
}
