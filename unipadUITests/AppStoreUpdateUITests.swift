import XCTest

/// Injects only the public lookup and installation context. Pack selection, playback, import
/// controls and the existing update label all use the real home and play screens.
final class AppStoreUpdateUITests: XCTestCase {
    @MainActor func testNewVersionKeepsExistingPromptAndPackPlayback() throws {
        try exercise("available", updateExpected: true)
    }
    @MainActor func testCurrentVersionDoesNotShowPromptOrBlockPlayback() throws {
        try exercise("current", updateExpected: false)
    }
    @MainActor func testFailureDoesNotShowPromptOrBlockPlayback() throws {
        try exercise("failure", updateExpected: false)
    }
    @MainActor func testTenSecondDelayDoesNotBlockPackSelectionOrPlayback() throws {
        try exercise("delay", updateExpected: false)
    }

    @MainActor private func exercise(_ response: String, updateExpected: Bool) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments(isolated: true)
            + ["-UniPadAppStoreResponse", response]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        let prompt = app.staticTexts["main.updateAvailable"]
        UITestSupport.attachScreenshot("\(response)-home-initial", to: self)
        if updateExpected { XCTAssertTrue(prompt.waitForExistence(timeout: 5)) }
        else { XCTAssertFalse(prompt.exists) }
        UITestSupport.attachScreenshot("\(response)-home-before-selection", to: self)

        // The same local pack in every state; its first pad maps a real sound and an LED.
        let list = app.scrollViews["main.packList"]
        let title = list.staticTexts["Release Fixture - Tests"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(UITestSupport.scrollIntoView(title, in: list, app: app))
        title.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 20))
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625)).tap()
        UITestSupport.attachScreenshot("\(response)-play-after-first-pad", to: self)
        app.buttons["line.3.horizontal"].tap()
        let quit = app.buttons["rectangle.portrait.and.arrow.right"]
        XCTAssertTrue(quit.waitForExistence(timeout: 5))
        quit.tap()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 10))
        if app.buttons["Play"].firstMatch.exists { title.tap() }
        if updateExpected { XCTAssertTrue(prompt.waitForExistence(timeout: 5)) }
        else { XCTAssertFalse(prompt.exists) }
        UITestSupport.attachScreenshot("\(response)-home-after-return", to: self)
        let archive = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Normal", withExtension: "zip"))
        app.open(archive)
        let imported = app.staticTexts["main.importResult.title"]
        XCTAssertTrue(imported.waitForExistence(timeout: 30))
        XCTAssertEqual(imported.label, "Pack imported!")
        UITestSupport.attachScreenshot("\(response)-import-complete", to: self)
        app.buttons["main.importResult.ok"].tap()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 10))
        if updateExpected { XCTAssertTrue(prompt.waitForExistence(timeout: 5)) }
        else { XCTAssertFalse(prompt.exists) }
        XCTAssertTrue(app.buttons["main.guide.import"].exists)
        XCTAssertTrue(app.buttons["main.guide.download"].exists)
    }
}
