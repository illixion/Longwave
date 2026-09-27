import XCTest

/// Walks the main screens of the App Store edition, one full-room capture per
/// screen (3840×2160, the size App Store Connect takes for Apple Vision Pro).
/// Run through `scripts/capture-screenshots.sh`; the test cannot take the
/// shots itself, because `XCUIScreen.screenshot()` returns a 1×1 black image on
/// visionOS. Instead it writes the shot's name to `.request` in the output
/// directory and waits for the script, watching from the Mac, to answer with
/// `simctl io screenshot`.
///
/// The app is launched with `-LongwaveScreenshotDemo`, which seeds a fixed set
/// of saved connections. StoreKit answers from `Configuration/Longwave.storekit`
/// through the LongwaveUITests scheme, so the paywall shows both products with
/// prices — but only when the test is run from Xcode. xcodebuild ignores the
/// scheme's StoreKit file, and an `SKTestSession` started here does not reach
/// the app either; see the script's header for the Xcode route.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureStoreScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-LongwaveScreenshotDemo"]
        app.launch()

        let connectionsTab = app.buttons["rave.tab.connections"]
        XCTAssertTrue(connectionsTab.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Studio Mac"].waitForExistence(timeout: 10))
        capture("01-connections")

        select(app, tab: "pcvr")
        capture("02-pcvr")

        let unlock = app.buttons["Unlock PCVR"].firstMatch
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        unlock.tap()
        // Product rows are buttons, whose label merges their text, so match on
        // any element carrying the price rather than on a static text.
        let monthlyPrice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "1.99")).firstMatch
        let loaded = monthlyPrice.waitForExistence(timeout: 20)
        capture("03-paywall")
        XCTAssertTrue(loaded, "paywall products did not load — is the StoreKit configuration reaching the app?")
        app.buttons["Done"].firstMatch.tap()

        let help = app.buttons["Help"].firstMatch
        XCTAssertTrue(help.waitForExistence(timeout: 10))
        help.tap()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 10))
        capture("04-pcvr-help")
        app.buttons["Done"].firstMatch.tap()

        select(app, tab: "projects")
        capture("05-projects")

        select(app, tab: "settings")
        capture("06-settings")
    }

    @MainActor
    private func select(_ app: XCUIApplication, tab: String) {
        let button = app.buttons["rave.tab.\(tab)"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(tab) tab")
        button.tap()
    }

    /// `LONGWAVE_SCREENSHOT_DIR` from the script, else the repo's
    /// `build/screenshots` — the case when the test is run from Xcode, which
    /// passes no environment through.
    private static var outputFolder: URL {
        if let dir = ProcessInfo.processInfo.environment["LONGWAVE_SCREENSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/screenshots")
    }

    /// Waits out sheet and tab transitions, then has the script capture the room.
    @MainActor
    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 2.5)
        let folder = Self.outputFolder
        let shot = folder.appendingPathComponent("\(name).png")
        XCTAssertNoThrow(try Data(name.utf8).write(to: folder.appendingPathComponent(".request"), options: .atomic))
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: shot.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: shot.path), "no screenshot for \(name)")
    }
}
