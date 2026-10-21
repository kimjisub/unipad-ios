import XCTest

/// Optional real-pack screen capture companion to StorePackLedTimingTests. Install the same pack in
/// Documents/UniPack and pass its title in TEST_RUNNER_UNIPAD_LED_TIMING_VISUAL_PACK.
final class LedAutoplayUITests: XCTestCase {
    @MainActor
    func testSamplePackAutoplayRemainsResponsive() throws {
        guard let title = ProcessInfo.processInfo.environment["UNIPAD_LED_TIMING_VISUAL_PACK"] else {
            throw XCTSkip("set UNIPAD_LED_TIMING_VISUAL_PACK to an installed sample pack title")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments()
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 20))
        UITestSupport.searchForPack(title, in: app)
        let list = app.scrollViews["main.packList"]
        let row = list.staticTexts[title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(UITestSupport.scrollIntoView(row, in: list, app: app, maxSwipes: 20))
        row.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() } else { row.tap() }
        XCTAssertTrue(app.otherElements["playPadGrid"].waitForExistence(timeout: 20))
        app.buttons["line.3.horizontal"].tap()
        app.buttons["Autoplay"].firstMatch.tap()
        for second in [10, 20, 30, 40, 50, 60] {
            Thread.sleep(forTimeInterval: 10)
            UITestSupport.attachScreenshot("autoplay-\(second)s", to: self)
        }
        let pause = app.buttons["pause.fill"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        Thread.sleep(forTimeInterval: 3)
        UITestSupport.attachScreenshot("autoplay-paused-3s", to: self)
        Thread.sleep(forTimeInterval: 5)
        UITestSupport.attachScreenshot("autoplay-paused-8s", to: self)
        app.buttons["line.3.horizontal"].tap()
        app.buttons["rectangle.portrait.and.arrow.right"].tap()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 15))
    }
}
