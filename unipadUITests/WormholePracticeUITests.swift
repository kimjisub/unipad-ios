import XCTest

/// Uses the real parser, warning alert and player with a silent one-chain pack.
final class WormholePracticeUITests: XCTestCase {
    @MainActor func testStepWithJump2() { exercise(jump: "2", mode: "Step") }
    @MainActor func testStepWithJump40() { exercise(jump: "40", mode: "Step") }
    @MainActor func testGuideWithJump2() { exercise(jump: "2", mode: "Guide") }
    @MainActor func testGuideWithJump40() { exercise(jump: "40", mode: "Guide") }

    @MainActor
    private func exercise(jump: String, mode: String) {
        continueAfterFailure = false
        let orientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = orientation }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.isolatedLibraryLaunchArguments(library: "empty")
            + ["-UniPadReleaseWormhole", jump]
        app.launch()
        defer { app.terminate() }
        let title = app.staticTexts["Wormhole \(jump)"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        title.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()

        let warning = app.alerts["Warning"]
        let warned = warning.waitForExistence(timeout: 5)
        UITestSupport.attachScreenshot("\(mode)-\(jump)-01-warning", to: self)
        if warned {
            XCTAssertTrue(warning.staticTexts[
                "keySound : [1 1 1 silence.wav 1 \(jump)] wormhole is incorrect"
            ].exists)
            warning.buttons["Accept"].tap()
        }

        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 15))
        app.buttons["line.3.horizontal"].tap()
        let button = app.buttons[mode].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        UITestSupport.attachScreenshot("\(mode)-\(jump)-02-mode", to: self)
        button.tap()
        if mode == "Step", app.state == .runningForeground {
            let frame = grid.frame
            let side = min(frame.width, frame.height)
            for column in 0..<2 {
                grid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                    dx: (frame.width - side) / 2 + side * (CGFloat(column) + 0.5) / 8,
                    dy: (frame.height - side) / 2 + side / 16
                )).tap()
            }
        }
        let ended = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons["forward.end.fill"])
        let result = XCTWaiter().wait(for: [ended], timeout: 15)
        UITestSupport.attachScreenshot("\(mode)-\(jump)-03-after-play", to: self)
        XCTAssertEqual(app.state, .runningForeground, "the missing chain closed the app")
        XCTAssertEqual(result, .completed, "the missing chain stopped practice before the end")
        XCTAssertTrue(grid.exists)
        XCTAssertTrue(warned, "the invalid jump must appear in the warning list")
    }
}
