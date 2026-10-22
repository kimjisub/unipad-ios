import XCTest

/// Share-code links from the discontinued pack sharing service must leave the app on home,
/// without an import screen or a request to the retired endpoint.
final class RetiredShareLinkTests: XCTestCase {
    @MainActor
    func testShareLinkLeavesHomeVisible() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments(isolated: true)
        app.launch()
        let settings = app.buttons["gearshape"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        XCTAssertTrue(UITestSupport.waitUntilHittable(settings, timeout: 20))

        app.open(try XCTUnwrap(URL(string: "unipad://unipack?code=retired-share")))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let shareText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "retired-share")).firstMatch
        XCTAssertFalse(shareText.waitForExistence(timeout: 3), "The retired link opened an import screen")
        UITestSupport.attachScreenshot("share-link-after-opening", to: self)
        XCTAssertTrue(settings.isHittable, "The retired link replaced home")
    }
}
