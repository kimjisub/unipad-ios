import XCTest

/// The silent pack repeats a finite light scene long enough to survive menu interactions.
/// Turning lights back on must wait for a new input instead of replaying that scene.
final class LightDiscardUITests: XCTestCase {
    @MainActor
    func testReenablingLightsWaitsForANewPad() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let archive = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("ExternalImportFixtures/LightDiscard.uni")
        let app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments(library: "chain-release", archive: try Data(contentsOf: archive))
        app.launch()
        defer { app.terminate() }
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 20))
        UITestSupport.searchForPack("Light Discard", in: app)
        UITestSupport.openPack(titled: "Light Discard", in: app, missingMessage: "the light fixture was not imported")
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 20))
        app.buttons["line.3.horizontal"].tap()
        setSwitch("Feedback light", checked: false, in: app)
        setSwitch("LED", checked: true, in: app)
        dismissOptions(in: app, grid: grid)
        let idle = try PadPixels.settled(grid)
        let first = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625))
        first.tap()
        XCTAssertFalse(try PadPixels(grid.screenshot()).changedPads(comparedWith: idle).isEmpty)
        UITestSupport.attachScreenshot("light-scene-running", to: self)

        app.buttons["line.3.horizontal"].tap()
        setSwitch("LED", checked: false, in: app)
        dismissOptions(in: app, grid: grid)
        XCTAssertEqual(try PadPixels.settled(grid).changedPads(comparedWith: idle), [])
        UITestSupport.attachScreenshot("lights-disabled", to: self)
        first.tap()
        app.buttons["line.3.horizontal"].tap()
        setSwitch("LED", checked: true, in: app)
        dismissOptions(in: app, grid: grid)
        Thread.sleep(forTimeInterval: 1)
        UITestSupport.attachScreenshot("lights-reenabled-without-new-input", to: self)
        XCTAssertEqual(try PadPixels(grid.screenshot()).changedPads(comparedWith: idle), [],
                       "the scene from before disabling lights returned")
        first.tap()
        XCTAssertFalse(try PadPixels(grid.screenshot()).changedPads(comparedWith: idle).isEmpty,
                       "a new input did not start its light")
        UITestSupport.attachScreenshot("new-input-starts-light", to: self)
    }

    @MainActor
    private func setSwitch(_ name: String, checked: Bool, in app: XCUIApplication) {
        let matches = app.switches.matching(identifier: name)
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 5))
        let control = matches.element(boundBy: matches.count - 1)
        if (control.value as? String == "1") != checked { control.tap() }
        XCTAssertEqual(control.value as? String, checked ? "1" : "0")
    }

    @MainActor
    private func dismissOptions(in app: XCUIApplication, grid: XCUIElement) {
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["line.3.horizontal"].waitForExistence(timeout: 5))
    }
}
