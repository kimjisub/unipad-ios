import XCTest

final class RetiredShareLinkTests: XCTestCase {
    @MainActor
    func testShareLinkLeavesHomeVisible() throws {
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments()
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        UITestSupport.attachScreenshot("share-link-home-before-opening", to: self)

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        safari.launch()
        let continueButton = safari.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 2) { continueButton.tap() }
        let address = safari.textFields.firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        safari.typeText("unipad://unipack?code=retired-share\n")
        let open = safari.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "열기"])).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let shareText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "retired-share")).firstMatch
        XCTAssertFalse(shareText.waitForExistence(timeout: 1))
        UITestSupport.attachScreenshot("share-link-after-opening", to: self)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons["gearshape"].isHittable, "The retired link replaced home")
    }
}
