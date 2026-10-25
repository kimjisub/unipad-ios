import XCTest

/// Uses the public mode buttons and the runner tests' three-note chain-wait sequence, opened by a
/// 5 s delay. The guide's chain hint holds song time from one lookahead before the first note, so
/// switching to autoplay from it leaves that lookahead before the note; counting the held time
/// would play the note at once. The app's 800 ms is shorter than input and capture take on a busy
/// machine, so the check lengthens it.
final class AutoPlayChainWaitUITests: XCTestCase {
    private static let guideLookaheadMs = 4000
    private static var remainingDelay: TimeInterval { TimeInterval(guideLookaheadMs) / 1000 }

    @MainActor
    func testSwitchingFromChainHintPreservesRemainingDelay() throws {
        continueAfterFailure = false
        let orientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = orientation }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments(library: "chain-wait")
            + ["-UniPadReleaseGuideLookaheadMs", "\(Self.guideLookaheadMs)"]
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
        // The hint starts 1 s in; switching 7 s in puts the held time well past the 5 s first note.
        Thread.sleep(forTimeInterval: 2)
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
        // The tap starts after `started` and the shot ends before `elapsed`, so the screen shows the
        // app less than `elapsed` after it switched.
        XCTAssertLessThan(elapsed, Self.remainingDelay, "The capture missed the remaining-delay window")
        XCTAssertEqual(try PadPixels(early).changedPads(comparedWith: idle), [],
                       "Switching modes played a note before the remaining delay")
        // The three notes come 0, 0.5 and 1 s after the remaining delay.
        Thread.sleep(forTimeInterval: max(0, started + Self.remainingDelay + 1 - ProcessInfo.processInfo.systemUptime))
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var played: [String]
        repeat {
            played = try PadPixels(grid.screenshot()).changedPads(comparedWith: idle)
        } while played.isEmpty && ProcessInfo.processInfo.systemUptime < deadline
        UITestSupport.attachScreenshot("chain-wait-three-notes-played", to: self)
        XCTAssertEqual(played, ["1,1"])
    }

    @MainActor
    private func choose(_ mode: String, app: XCUIApplication) {
        app.buttons["line.3.horizontal"].tap()
        let button = app.buttons[mode].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }
}
