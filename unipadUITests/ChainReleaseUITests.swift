import XCTest

/// Install the unchanged ChainRelease delayed archive in Documents/UniPack before running.
/// A missing pack skips this optional check; required fixture runs must report a pass, not a skip.
/// One actual simulator finger holds the first pad through the pack's 100 ms chain move.
/// Audio stop targets are independently checked by ChainReleaseTests, not inferred here.
final class ChainReleaseUITests: XCTestCase {
    @MainActor
    func testOneFingerThroughPackChainMoveAndRelease() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 20))
        let list = app.scrollViews["main.packList"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let title = list.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Chain Release v1 delayed")).firstMatch
        // Lazy rows outside the viewport do not exist in the accessibility tree yet.
        // Search the library itself so a recent-pack card cannot select another route.
        for _ in 0..<10 {
            if title.exists && title.isHittable { break }
            list.swipeUp()
        }
        guard title.exists && title.isHittable else {
            throw XCTSkip("Chain Release v1 delayed is not installed in Documents/UniPack; chain release UI was not checked")
        }
        title.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() } else { title.tap() }
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 20))
        UITestSupport.attachScreenshot("01-before-pad-press", to: self)
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625)).press(forDuration: 0.4)
        XCTAssertTrue(grid.exists)
        UITestSupport.attachScreenshot("02-after-pack-chain-move-and-release", to: self)
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.1875)).tap()
        UITestSupport.attachScreenshot("03-after-second-pad-release", to: self)
        app.buttons["line.3.horizontal"].tap()
        XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 5))
        app.buttons["rectangle.portrait.and.arrow.right"].tap()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 10))
        UITestSupport.attachScreenshot("04-home-after-exit", to: self)
    }
}
