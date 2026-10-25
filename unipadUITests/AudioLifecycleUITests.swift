import XCTest

/// Exercises the real audio engine and app lifecycle with the shared Faded sample pack.
/// Screenshots and the app's audio logs are evidence of the simulator flow, not audible latency.
/// Every launch stages a silent 8x8 Faded in an isolated library and requires a pass.
final class AudioLifecycleUITests: XCTestCase {
    @MainActor
    func testPadsAndAutoplayRemainUsableAfterReturningFromHome() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments(library: "chain-layout")
        app.launch()
        UITestSupport.dismissSystemAlerts()
        let list = app.scrollViews["main.packList"]
        XCTAssertTrue(list.waitForExistence(timeout: 30))
        let title = list.staticTexts.matching(NSPredicate(format: "label == %@", "Alan Walker - Faded")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the isolated library must stage Faded")
        XCTAssertTrue(UITestSupport.scrollIntoView(title, in: list, app: app, maxSwipes: 20))
        UITestSupport.attachScreenshot("audio-01-pack-selected", to: self)
        title.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        let grid = app.otherElements["playPadGrid"]
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30))
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        UITestSupport.attachScreenshot("audio-02-pack-open", to: self)
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625)).press(forDuration: 0.4)
        UITestSupport.attachScreenshot("audio-03-after-pad", to: self)

        XCUIDevice.shared.press(.home)
        waitForBackground(app)
        UITestSupport.attachScreenshot("audio-04-home", to: self)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625)).press(forDuration: 0.4)
        UITestSupport.attachScreenshot("audio-05-pad-after-return", to: self)

        menu.tap()
        let autoplay = app.buttons["Autoplay"].firstMatch
        XCTAssertTrue(autoplay.waitForExistence(timeout: 5))
        autoplay.tap()
        UITestSupport.attachScreenshot("audio-06-autoplay", to: self)
        XCUIDevice.shared.press(.home)
        waitForBackground(app)
        UITestSupport.attachScreenshot("audio-07-autoplay-home", to: self)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        UITestSupport.attachScreenshot("audio-08-autoplay-return", to: self)
        let resume = app.buttons["play.fill"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "returning home must wait for a manual resume")
        XCTAssertFalse(app.buttons["pause.fill"].exists)
        resume.tap()
        XCTAssertTrue(app.buttons["pause.fill"].waitForExistence(timeout: 5))
        UITestSupport.attachScreenshot("audio-08-manually-resumed", to: self)
        menu.tap()
        let quit = app.buttons["rectangle.portrait.and.arrow.right"]
        XCTAssertTrue(quit.waitForExistence(timeout: 5))
        quit.tap()
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        UITestSupport.attachScreenshot("audio-09-exit", to: self)
        app.terminate()
    }

    @MainActor
    private func waitForBackground(_ app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: app)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed)
    }
}
