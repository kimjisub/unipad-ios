import XCTest

/// Seed Documents/UniPack/Faded from the repository's Faded.zip before running.
/// Without the sample pack this check is skipped, as with other pack UI tests.
/// Exercises playback across the dependency update with production collection off.
final class DependencyPlaybackSmokeTests: XCTestCase {
    @MainActor
    func testFadedPadsReturnAndRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments()
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        UITestSupport.attachScreenshot("dependency-01-home", to: self)

        let pack = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Faded")).firstMatch
        guard pack.waitForExistence(timeout: 30) else {
            throw XCTSkip("Faded is not installed in Documents/UniPack; playback was not checked")
        }
        pack.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30))
        UITestSupport.attachScreenshot("dependency-02-faded", to: self)

        let menu = app.buttons["line.3.horizontal"]
        menu.tap()
        XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 10))
        UITestSupport.setPlayOption("Trace Log", on: true, in: app)
        UITestSupport.setPlayOption("LED", on: false, in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        for point in [CGVector(dx: 0.0625, dy: 0.0625), CGVector(dx: 0.4375, dy: 0.4375)] {
            grid.coordinate(withNormalizedOffset: point).tap()
        }
        UITestSupport.attachScreenshot("dependency-03-pads-pressed", to: self)

        menu.tap()
        XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 10))
        UITestSupport.setPlayOption("Trace Log", on: false, in: app)
        UITestSupport.setPlayOption("LED", on: true, in: app)
        app.buttons["rectangle.portrait.and.arrow.right"].tap()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        UITestSupport.attachScreenshot("dependency-04-returned-home", to: self)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        XCTAssertTrue(pack.waitForExistence(timeout: 30))
        UITestSupport.attachScreenshot("dependency-05-relaunched", to: self)
    }
}
