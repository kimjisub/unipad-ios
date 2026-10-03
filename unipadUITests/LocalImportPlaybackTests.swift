import XCTest

/// Prepare LocalTone.zip in the simulator's On My iPhone file provider before running.
/// The fixture contains only a generated 440 Hz tone; no third-party music is needed.
final class LocalImportPlaybackTests: XCTestCase {
    @MainActor
    func testLocalToneImportsAndPlays() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments()
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        UITestSupport.revealHomeCard(.import, in: app).tap()
        let pack = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "LocalTone")).firstMatch
        if !pack.waitForExistence(timeout: 3) {
            for label in ["Browse", "On My iPhone"] {
                let item = app.descendants(matching: .any).matching(identifier: label).firstMatch
                if item.waitForExistence(timeout: 3) && item.isHittable { item.tap() }
            }
        }
        guard pack.waitForExistence(timeout: 10) else {
            UITestSupport.attachScreenshot("local-tone-missing-fixture", to: self)
            XCTFail("Prepare Fixtures/LocalTone.zip in On My iPhone before running")
            return
        }
        UITestSupport.attachScreenshot("local-tone-file-picker", to: self)
        pack.tap()
        let playNow = app.buttons["main.importResult.playNow"]
        XCTAssertTrue(playNow.waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["Local Tone"].exists)
        UITestSupport.attachScreenshot("local-tone-imported", to: self)
        playNow.tap()
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30))
        let menu = app.buttons["line.3.horizontal"]
        menu.tap()
        UITestSupport.setPlayOption("Trace Log", on: true, in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625)).tap()
        UITestSupport.attachScreenshot("local-tone-pad-pressed", to: self)
        XCTAssertEqual(app.state, .runningForeground)
        menu.tap()
        UITestSupport.setPlayOption("Trace Log", on: false, in: app)
        app.buttons["rectangle.portrait.and.arrow.right"].tap()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
    }
}
