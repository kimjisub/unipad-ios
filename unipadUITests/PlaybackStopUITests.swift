import XCTest

/// Install Fixtures/PlaybackStop in Documents/unipack before running. Missing content fails the
/// check rather than silently skipping a stop/exit regression. All audio in this fixture is silent.
final class PlaybackStopUITests: XCTestCase {
    private let app = XCUIApplication()

    @MainActor
    func testRepeatedInputExitAndPracticeModeSwitchesStayResponsive() {
        continueAfterFailure = false
        app.launchArguments += UITestSupport.englishLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()

        for round in 0..<3 {
            openPack()
            let grid = app.otherElements["playPadGrid"]
            for _ in 0..<4 { grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625)).tap() }
            if round == 0 { UITestSupport.attachScreenshot("01-repeated-input", to: self) }
            leave()
            if round == 0 { UITestSupport.attachScreenshot("02-home-after-sound", to: self) }

            openPack()
            choose("Step")
            if round == 0 { UITestSupport.attachScreenshot("03-step-waiting", to: self) }
            grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625)).tap()
            if round == 0 { UITestSupport.attachScreenshot("04-step-after-input", to: self) }
            choose("Autoplay")
            if round == 0 { UITestSupport.attachScreenshot("05-autoplay", to: self) }
            choose("Guide")
            if round == 0 { UITestSupport.attachScreenshot("06-guide", to: self) }
            choose("Step")
            leave()
            if round == 0 { UITestSupport.attachScreenshot("07-home-after-step", to: self) }
        }
    }

    @MainActor
    private func openPack() {
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 15))
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Playback Stop Fixture")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "install Fixtures/PlaybackStop first")
        title.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() } else { title.tap() }
        XCTAssertTrue(app.otherElements["playPadGrid"].waitForExistence(timeout: 15))
    }

    @MainActor
    private func menu() {
        app.buttons["line.3.horizontal"].tap()
        XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func choose(_ mode: String) {
        menu()
        let button = app.buttons[mode].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(app.otherElements["playPadGrid"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func leave() {
        menu()
        app.buttons["rectangle.portrait.and.arrow.right"].tap()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 10), "exit left the screen unresponsive")
    }
}
