import XCTest

final class ZeroDurationLedUITests: XCTestCase {
    @MainActor
    func testHugeFiniteLoopsLeavePlaybackResponsive() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments()
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 20))
        UITestSupport.searchForPack("Zero Duration LED Fixture", in: app)
        let title = app.staticTexts["Zero Duration LED Fixture"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "install test-fixtures/ZeroDurationLED first")
        title.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() } else { title.tap() }
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 20))
        UITestSupport.attachScreenshot("before-zero-duration-pad", to: self)
        NSLog("ZERO_DURATION_PAD_PRESS_STARTED")
        let start = Date()
        for _ in 0..<3 {
            grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625)).tap()
            grid.coordinate(withNormalizedOffset: CGVector(dx: 0.1875, dy: 0.0625)).tap()
        }
        NSLog("ZERO_DURATION_PAD_PRESS_FINISHED: %.3f seconds", Date().timeIntervalSince(start))
        UITestSupport.attachScreenshot("after-zero-duration-pads", to: self)
        app.buttons["line.3.horizontal"].tap()
        app.buttons["rectangle.portrait.and.arrow.right"].tap()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 10))
        UITestSupport.attachScreenshot("home-after-zero-duration-pads", to: self)
    }
}
