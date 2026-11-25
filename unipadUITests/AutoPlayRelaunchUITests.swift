import XCTest

/// Covers autoplay completion, restart, and step practice with the silent PlaybackStop fixture.
final class AutoPlayRelaunchUITests: XCTestCase {
    @MainActor
    func testMappingKeepsThePageAfterTheWormhole() throws {
        try withPlayScreen(library: "wormhole-mapping", title: "Wormhole Song Time Fixture",
                           launchArguments: ["-SelectedTheme", "default"]) { app, grid, idle in
            openOptions(in: app)
            app.buttons["autoMapping"].tap()
            let question = app.alerts["Fit the autoplay?"]
            XCTAssertTrue(question.waitForExistence(timeout: 5))
            question.buttons["Fit"].tap()
            XCTAssertTrue(app.staticTexts["Autoplay saved. You can restore the previous version from the menu."].waitForExistence(timeout: 20))
            app.buttons["Autoplay"].firstMatch.tap()
            waitForTransportToGo(app, timeout: 15, "The mapped wormhole fixture must finish")
            UITestSupport.attachScreenshot("mapping-wormhole-press-page", to: self)
            XCTAssertEqual(try PadPixels.settled(grid).changedPads(comparedWith: idle), ["1,4"],
                           "Mapping a short sound must keep the second press on page 2")
        }
    }

    @MainActor
    func testEarlyPressUsesThePageBeforeTheWormhole() throws {
        try withPlayScreen(library: "wormhole-song-time", title: "Wormhole Song Time Fixture",
                           launchArguments: ["-SelectedTheme", "default"]) { app, grid, idle in
            choose("Autoplay", app: app)
            waitForTransportToGo(app, timeout: 15, "The short wormhole fixture must finish")
            UITestSupport.attachScreenshot("wormhole-early-press-page", to: self)
            XCTAssertEqual(try PadPixels.settled(grid).changedPads(comparedWith: idle), ["1,3"],
                           "The press at 1 ms must use page 1's light, not page 2's marker at 1,4")
        }
    }

    @MainActor
    func testSlowStepInputAfterAWormholeDoesNotRepeatThePlayedPad() throws {
        try withPlayScreen(library: "wormhole-song-time", title: "Wormhole Song Time Fixture",
                           launchArguments: ["-SelectedTheme", "default"]) { app, grid, _ in
            choose("Step", app: app)
            XCTAssertEqual(try guidePads(attachGuideScreenshot(grid, name: "slow-step-01-first-group")),
                           ["1,1", "1,2"])
            pressTopRow(grid, columns: 0..<1)
            let secondPage = app.buttons["playChain.2"]
            let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"),
                                                  object: secondPage)
            XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 5), .completed,
                           "The hand-played sound must still move the page after 100 ms")
            Thread.sleep(forTimeInterval: 0.3)
            app.buttons["playChain.1"].tap()
            XCTAssertEqual(try guidePads(attachGuideScreenshot(grid, name: "slow-step-02-return-to-song-page")),
                           ["1,2"], "Only the unplayed input may be guided after returning to page 1")
            pressTopRow(grid, columns: 1..<2)
            waitForTransportToGo(app, timeout: 15, "The remaining input must finish step practice")
        }
    }

    @MainActor
    func testGuideStartsAfterSongEndAndCanSwitchToAutoplay() {
        continueAfterFailure = false
        let orientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = orientation }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.isolatedLibraryLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()
        let list = app.scrollViews["main.packList"]
        XCTAssertTrue(list.waitForExistence(timeout: 30))
        UITestSupport.searchForPack("Playback Stop Fixture", in: app)
        let title = list.staticTexts["Playback Stop Fixture"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the Playback Stop fixture was not prepared")
        XCTAssertTrue(UITestSupport.scrollIntoView(title, in: list, app: app, maxSwipes: 20))
        title.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        choose("Autoplay", app: app)
        UITestSupport.attachScreenshot("autoplay-01-first-start", to: self)
        // The short fixture reaches its natural end without exceeding the suite deadline.
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
        openOptions(in: app)
        UITestSupport.attachScreenshot("autoplay-06-options-after-end", to: self)
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
        app.launchArguments = UITestSupport.isolatedLibraryLaunchArguments()
        app.launch()
        defer { app.terminate() }
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 20))
        UITestSupport.searchForPack("Playback Stop Fixture", in: app)
        let title = app.staticTexts["Playback Stop Fixture"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the Playback Stop fixture was not prepared")
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

    /// The same capture runs before and after the runner fix. Unit tests verify sound requests;
    /// this silent fixture gives that request a sustained light for the screen comparison.
    @MainActor
    func testStepToAutoplayShowsThePendingPad() throws {
        try withPlayScreen(library: "step-resume", title: "Step Resume Fixture") { app, grid, idle in
            choose("Step", app: app)
            UITestSupport.attachScreenshot("pending-step-01-guide", to: self)
            choose("Autoplay", app: app)
            XCTAssertTrue(app.buttons["pause.fill"].waitForExistence(timeout: 5))
            UITestSupport.attachScreenshot("pending-step-02-autoplay", to: self)
            XCTAssertEqual(try PadPixels.settled(grid).changedPads(comparedWith: idle), ["1,1"],
                           "Sounding autoplay must trigger the unplayed guided pad's light")
            app.buttons["pause.fill"].tap()
            app.buttons["play.fill"].tap()
            UITestSupport.attachScreenshot("pending-step-03-resumed", to: self)
        }
    }

    /// The long gaps leave room for actual screen input and captures. Exact millisecond cases
    /// live in the gated runner tests; here a played paused step must not appear again.
    @MainActor
    func testTimedGuideDoesNotRepeatTheStepPlayedWhilePaused() throws {
        try withPlayScreen(library: "timed-step-resume", title: "Timed Step Resume Fixture",
                           launchArguments: ["-UniPadReleaseGuideLookaheadMs", "60000", "-SelectedTheme", "default"]) { app, grid, _ in
            choose("Guide", app: app)
            app.buttons["pause.fill"].tap()
            let paused = attachGuideScreenshot(grid, name: "timed-resume-01-paused-first-guide")
            XCTAssertEqual(try guidePads(paused), ["1,1"])
            pressTopRow(grid, columns: 0..<1)
            let played = attachGuideScreenshot(grid, name: "timed-resume-02-first-played")
            XCTAssertEqual(try guidePads(played), ["1,2"],
                           "The press must replace the first guide with the second")
            app.buttons["play.fill"].tap()
            let resumed = attachGuideScreenshot(grid, name: "timed-resume-03-after-resume")
            XCTAssertEqual(try guidePads(resumed), ["1,2"],
                           "Only the next unplayed step may return in the timed guide")
        }
    }

    @MainActor
    private func attachGuideScreenshot(_ grid: XCUIElement, name: String) -> XCUIScreenshot {
        let screenshot = grid.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return screenshot
    }

    /// The pinned default theme draws green guide outlines; step practice fills the same pads.
    /// Sample the outline too so changing the countdown's fill cannot look like a missing guide.
    @MainActor
    private func guidePads(_ screenshot: XCUIScreenshot) throws -> [String] {
        let pixels = try PadPixels(screenshot, insetFraction: 0.05)
        return pixels.means.indices.compactMap { index in
            let rgb = pixels.means[index]
            return rgb[1] > rgb[0] + 20 && rgb[1] > rgb[2] + 20
                ? "\(index / 8 + 1),\(index % 8 + 1)" : nil
        }
    }

    /// One case of `StepReturnAutoplayTests` through the real background and return, read from the
    /// pads as drawn: pad 1,2 pressed, Play first, and the fixture's last group is pads 1,2 and 2,1.
    @MainActor
    private func checkAutoplayAfterReturningToPartialStep(awayFor seconds: TimeInterval) throws {
        try withPlayScreen(library: "step-return", title: "Step Return Fixture") { app, grid, idle in
            choose("Step", app: app)
            pressTopRow(grid, columns: 0..<2)
            UITestSupport.attachScreenshot("step-return-01-partly-pressed", to: self)

            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: seconds)
            app.activate()
            XCTAssertTrue(grid.waitForExistence(timeout: 15))
            XCTAssertEqual(try PadPixels.settled(grid).changedPads(comparedWith: idle), [],
                           "Leaving the app must clear the guides and lights until Play")
            let resume = app.buttons["play.fill"]
            XCTAssertTrue(resume.waitForExistence(timeout: 5))
            resume.tap()
            UITestSupport.attachScreenshot("step-return-02-guide", to: self)
            let guide = try PadPixels.settled(grid)
            XCTAssertEqual(guide.changedPads(comparedWith: idle), ["2,1"], "Play must guide only the unpressed pad")

            choose("Autoplay", app: app)
            UITestSupport.attachScreenshot("step-return-03-autoplay", to: self)
            let played = try PadPixels.settled(grid)
            XCTAssertEqual(played.changedPads(comparedWith: idle), ["2,1"], "Autoplay must light only the unpressed pad")
            XCTAssertEqual(played.changedPads(comparedWith: guide), ["2,1"], "The pad's own light must replace its guide")
            waitForTransportToGo(app, timeout: 15, "The last group must end the song")
        }
    }

    /// Runs `body` on a fixture pack's play screen, in landscape, with the unlit pads as its baseline.
    @MainActor
    private func withPlayScreen(library: String, title: String, launchArguments: [String] = [],
                                _ body: (XCUIApplication, XCUIElement, PadPixels) throws -> Void) throws {
        continueAfterFailure = false
        let orientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = orientation }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.isolatedLibraryLaunchArguments(library: library) + launchArguments
        app.launch()
        defer { app.terminate() }
        UITestSupport.dismissSystemAlerts()
        let pack = app.staticTexts[title].firstMatch
        XCTAssertTrue(pack.waitForExistence(timeout: 30))
        pack.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 15))
        try body(app, grid, try PadPixels.settled(grid))
    }

    @MainActor
    func testAutoplayAfterOneSecondAwayFromPartialStep() throws {
        try checkAutoplayAfterReturningToPartialStep(awayFor: 1)
    }

    @MainActor
    func testAutoplayAfterTenSecondsAwayFromPartialStep() throws {
        try checkAutoplayAfterReturningToPartialStep(awayFor: 10)
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
        waitForTransportToGo(app, timeout: 15, "Step practice did not finish after its last group")
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
        openOptions(in: app)
        let button = app.buttons[mode].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    /// Song completion removes the transport and moves the menu within its centered column.
    /// Its accessibility element can exist before the animation reaches the tap position.
    @MainActor
    private func openOptions(in app: XCUIApplication) {
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(UITestSupport.waitForSettledFrame(timeout: 5,
            waitForArrival: { menu.waitForExistence(timeout: $0) },
            frame: {
                guard menu.isHittable else { return nil }
                return UITestSupport.currentFrame(of: menu)
            }), "The menu must stop moving before it is tapped")
        menu.tap()
        XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 5),
                      "Tapping the settled menu must open the options panel")
    }

    @MainActor
    private func waitForSongEnd(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["forward.end.fill"].waitForExistence(timeout: 5))
        waitForTransportToGo(app, timeout: 240, "Autoplay did not reach the end after starting")
    }

    /// A short last group may already be over when this starts, so it only waits for the button to go.
    @MainActor
    private func waitForTransportToGo(_ app: XCUIApplication, timeout: TimeInterval, _ message: String) {
        let ended = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                              object: app.buttons["forward.end.fill"])
        XCTAssertEqual(XCTWaiter().wait(for: [ended], timeout: timeout), .completed, message)
    }
}
