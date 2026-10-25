import XCTest

/// Uses the public mode buttons and the runner tests' three-note chain-wait sequence, with 3 s
/// between the chain change and the first note so input and capture delays fit before it.
final class AutoPlayChainWaitUITests: XCTestCase {
    /// From leaving the chain hint to the first note: the 800 ms guide lookahead plus 3 s.
    private static let remainingDelay: TimeInterval = 3.8

    @MainActor
    func testSwitchingFromChainHintPreservesRemainingDelay() throws {
        continueAfterFailure = false
        let orientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = orientation }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments(library: "chain-wait")
        app.launch()
        defer { app.terminate() }
        UITestSupport.dismissSystemAlerts()
        UITestSupport.searchForPack("Chain Wait Fixture", in: app)
        let title = app.staticTexts["Chain Wait Fixture"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        title.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 20))
        let idle = try PadPixels(grid.screenshot())
        choose("Guide", app: app)
        Thread.sleep(forTimeInterval: 1)
        UITestSupport.attachScreenshot("chain-wait-hint", to: self)
        Thread.sleep(forTimeInterval: 5)
        app.buttons["line.3.horizontal"].tap()
        let auto = app.buttons["Autoplay"].firstMatch
        XCTAssertTrue(auto.waitForExistence(timeout: 5))
        let started = ProcessInfo.processInfo.systemUptime
        auto.tap()
        let early = grid.screenshot()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let attachment = XCTAttachment(screenshot: early)
        attachment.name = "chain-wait-after-switch"
        attachment.lifetime = .keepAlways
        add(attachment)
        let timing = XCTAttachment(string: "switch invocation to screenshot completion: \(elapsed) seconds")
        timing.lifetime = .keepAlways
        add(timing)
        XCTAssertLessThan(elapsed, Self.remainingDelay, "The capture missed the remaining-delay window")
        XCTAssertEqual(try PadPixels(early).changedPads(comparedWith: idle), [],
                       "Switching modes played a note before the remaining delay")
        // The three notes come 0, 0.5 and 1 s after the remaining delay.
        let played = started + Self.remainingDelay + 1.5
        Thread.sleep(forTimeInterval: max(0, played - ProcessInfo.processInfo.systemUptime))
        UITestSupport.attachScreenshot("chain-wait-three-notes-played", to: self)
        XCTAssertEqual(try PadPixels(grid.screenshot()).changedPads(comparedWith: idle), ["1,1"])
    }

    @MainActor
    private func choose(_ mode: String, app: XCUIApplication) {
        app.buttons["line.3.horizontal"].tap()
        let button = app.buttons[mode].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }
}
