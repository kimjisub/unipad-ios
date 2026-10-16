import XCTest

/// Covers real Faded playback and step practice with the silent PlaybackStop fixture.
final class AutoPlayRelaunchUITests: XCTestCase {
    @MainActor
    func testGuideStartsAfterSongEndAndCanSwitchToAutoplay() {
        continueAfterFailure = false
        let orientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = orientation }
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
    func testStepPracticeCanStartAfterItsLastGroup() {
        continueAfterFailure = false
        let orientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = orientation }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments()
        app.launch()
        defer { app.terminate() }
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 20))
        UITestSupport.searchForPack("Playback Stop Fixture", in: app)
        let title = app.staticTexts["Playback Stop Fixture"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Install Fixtures/PlaybackStop before this check")
        title.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 15))

        choose("Step", app: app)
        UITestSupport.attachScreenshot("step-01-first-group", to: self)
        playAllGroups(grid, app: app)
        UITestSupport.attachScreenshot("step-02-end", to: self)
        choose("Step", app: app)
        UITestSupport.attachScreenshot("step-03-restarted-first-group", to: self)
        // Completing every group again proves the new run started at the first one.
        // Guide colors are also captured for review.
        playAllGroups(grid, app: app)
        UITestSupport.attachScreenshot("step-04-second-end", to: self)
    }

    /// The fixture's three groups are one pad each, along the top row.
    @MainActor
    private func playAllGroups(_ grid: XCUIElement, app: XCUIApplication) {
        let transport = app.buttons["forward.end.fill"]
        pressTopRow(grid, columns: 0..<2)
        Thread.sleep(forTimeInterval: 0.5)
        UITestSupport.attachScreenshot("step-last-group", to: self)
        XCTAssertTrue(transport.exists, "Step practice ended before its last group was played")
        pressTopRow(grid, columns: 2..<3)
        let ended = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: transport)
        XCTAssertEqual(XCTWaiter().wait(for: [ended], timeout: 15), .completed,
                       "Step practice did not finish after its last group")
    }

    @MainActor
    private func pressTopRow(_ grid: XCUIElement, columns: Range<Int>) {
        // The square grid is centered in its container.
        let frame = grid.frame
        let side = min(frame.width, frame.height)
        for column in columns {
            grid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: (frame.width - side) / 2 + side * (CGFloat(column) + 0.5) / 8,
                dy: (frame.height - side) / 2 + side / 16
            )).tap()
        }
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
