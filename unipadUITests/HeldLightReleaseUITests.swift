import XCTest

/// A generated silent pack keeps its first pad red and moves to chain two. Its release must
/// clear that original endless light. The same gesture and screenshots also run before the fix.
final class HeldLightReleaseUITests: XCTestCase {
    @MainActor
    func testReleasingAfterTheLightChangesChainGoesDark() throws {
        continueAfterFailure = false
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("ExternalImportFixtures/HeldLight.uni")
        let app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments(library: "chain-release", archive: try Data(contentsOf: url))
        app.launch()
        defer { app.terminate() }
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 20))
        UITestSupport.searchForPack("Held Light", in: app)
        let title = app.staticTexts["Held Light"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() } else { title.tap() }
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 20))
        let idle = try PadPixels(grid.screenshot())
        UITestSupport.attachScreenshot("idle-before-press", to: self)
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625)).press(forDuration: 0.4)
        UITestSupport.attachScreenshot("released-after-chain-change", to: self)
        XCTAssertEqual(try PadPixels(grid.screenshot()).changedPads(comparedWith: idle), [],
                       "the endless light stayed on after its original press was released on chain two")
    }
}
