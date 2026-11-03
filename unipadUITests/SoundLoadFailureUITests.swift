import XCTest

/// What the play screen says about sound files that will not play, on staged packs whose one
/// unreadable sound is an empty file.
final class SoundLoadFailureUITests: XCTestCase {
    private func launch(_ library: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments(library: library, isolated: true)
        app.launch()
        return app
    }

    private func open(_ title: String, in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        let card = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "\(title) was not staged")
        card.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() } else { card.tap() }
    }

    private func checkDetails(in app: XCUIApplication, from button: XCUIElement, step: String) {
        button.tap()
        let details = app.navigationBars["Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10), "the details did not open")
        XCTAssertTrue(app.staticTexts["empty.wav"].exists, "the file is not named")
        XCTAssertTrue(app.staticTexts["Can't read the file"].exists, "the reason is not given")
        UITestSupport.attachScreenshot("\(step)-details", to: self)
        app.buttons["soundLoadDetailsClose"].tap()
        XCTAssertTrue(details.waitForNonExistence(timeout: 10), "the details did not close")
    }

    /// One sound cannot be read: the pack opens, says so once, and lists it on request.
    @MainActor
    func testAPartlyReadablePackOpensAndTellsWhatWillNotPlay() {
        let app = launch("sound-partial")
        defer { app.terminate() }
        open("Partial Sound Fixture", in: app)

        let notice = app.alerts["Can't read the file of 1 sound"]
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "no notice: \(app.debugDescription)")
        XCTAssertTrue(app.otherElements["playPadGrid"].exists, "the pack did not open")
        UITestSupport.attachScreenshot("01-notice", to: self)
        checkDetails(in: app, from: notice.buttons["Details"], step: "02")

        XCTAssertFalse(notice.waitForExistence(timeout: 2), "the notice came back")
        XCTAssertTrue(app.otherElements["playPadGrid"].exists)
        UITestSupport.attachScreenshot("03-playing", to: self)
    }

    /// No sound of the pack can play: the play screen is not shown; details, retry and the pack
    /// list are offered instead.
    @MainActor
    func testAPackWithNoReadableSoundDoesNotOpen() {
        let app = launch("sound-none")
        defer { app.terminate() }
        open("No Sound Fixture", in: app)

        let failure = app.staticTexts["Can't open this pack's sounds"]
        XCTAssertTrue(failure.waitForExistence(timeout: 20), "no failure screen: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Can't read the file of 1 sound"].exists)
        XCTAssertFalse(app.otherElements["playPadGrid"].exists, "the play screen opened")
        UITestSupport.attachScreenshot("01-failure", to: self)
        checkDetails(in: app, from: app.buttons["soundLoadDetailsButton"], step: "02")

        app.buttons["soundLoadRetryButton"].tap()
        XCTAssertTrue(failure.waitForExistence(timeout: 20), "a retry of the same files changed the answer")
        XCTAssertFalse(app.otherElements["playPadGrid"].exists)
        UITestSupport.attachScreenshot("03-after-retry", to: self)

        app.buttons["soundLoadPackListButton"].tap()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 10), "did not return to the pack list")
        UITestSupport.attachScreenshot("04-pack-list", to: self)
    }
}
