import XCTest

/// Uses the real Faded sample pack and lets autoplay reach the end without seeking.
final class AutoPlayRelaunchUITests: XCTestCase {
    @MainActor
    func testGuideAndAutoplayCanStartAfterTheSongFinishes() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()
        let list = app.scrollViews["main.packList"]
        XCTAssertTrue(list.waitForExistence(timeout: 30))
        let title = list.staticTexts.matching(NSPredicate(format: "label == %@", "Alan Walker - Faded")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Install the real Faded sample pack before this check")
        XCTAssertTrue(UITestSupport.scrollIntoView(title, in: list, app: app, maxSwipes: 20))
        title.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        choose("Autoplay", app: app)
        UITestSupport.attachScreenshot("autoplay-01-first-start", to: self)
        waitForSongEnd(app)
        UITestSupport.attachScreenshot("autoplay-02-first-end", to: self)

        choose("Guide", app: app)
        XCTAssertTrue(app.buttons["pause.fill"].waitForExistence(timeout: 5))
        // Let the first guide lookahead draw before capturing it; the runner unit and screen
        // model tests check actual guide events, rather than treating the transport as proof.
        Thread.sleep(forTimeInterval: 0.5)
        UITestSupport.attachScreenshot("autoplay-03-guide-after-end", to: self)
        choose("Autoplay", app: app)
        XCTAssertTrue(app.buttons["pause.fill"].waitForExistence(timeout: 5))
        UITestSupport.attachScreenshot("autoplay-04-restarted-autoplay", to: self)
        waitForSongEnd(app)
        UITestSupport.attachScreenshot("autoplay-05-second-end", to: self)
        menu.tap()
        app.buttons["rectangle.portrait.and.arrow.right"].tap()
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    private func choose(_ mode: String, app: XCUIApplication) {
        app.buttons["line.3.horizontal"].tap()
        let button = app.buttons[mode].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    @MainActor
    private func waitForSongEnd(_ app: XCUIApplication) {
        let transport = app.buttons["forward.end.fill"]
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        let ended = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: transport)
        XCTAssertEqual(XCTWaiter().wait(for: [ended], timeout: 240), .completed,
                       "Autoplay did not reach the end after starting")
    }
}
