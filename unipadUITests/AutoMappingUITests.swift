import XCTest

/// The menu's auto mapping and restore, in English, on the silent PlaybackStop fixture: the two
/// confirmations, the saved autoPlay surviving a new launch and the swap back to the old one.
final class AutoMappingUITests: XCTestCase {
    @MainActor
    func testMappingAsksFirstSavesAcrossLaunchesAndRestores() {
        continueAfterFailure = false
        let orientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = orientation }
        XCUIDevice.shared.orientation = .landscapeLeft
        let token = UUID().uuidString
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.launchArguments(language: "en", locale: "en_US", token: token, isolated: true)
        app.launch()
        defer { app.terminate() }
        UITestSupport.dismissSystemAlerts()
        UITestSupport.openPlaybackStopFixture(in: app)
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        menu.tap()

        let map = app.buttons["autoMapping"]
        let restore = app.buttons["restoreAutoPlay"]
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        XCTAssertFalse(restore.isEnabled, "a pack never mapped has no backup to restore")
        XCTAssertTrue(app.staticTexts["No saved backup"].exists || restore.label.contains("No saved backup"))
        UITestSupport.attachScreenshot("mapping-01-no-backup", to: self)

        map.tap()
        let question = app.alerts["Fit the autoplay?"]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        UITestSupport.attachScreenshot("mapping-02-confirm", to: self)
        question.buttons["Cancel"].tap()
        XCTAssertFalse(restore.isEnabled, "cancelling must change nothing")

        map.tap()
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        question.buttons["Fit"].tap()
        XCTAssertTrue(app.staticTexts["Autoplay saved. You can restore the previous version from the menu."].waitForExistence(timeout: 20))
        UITestSupport.attachScreenshot("mapping-03-saved", to: self)
        XCTAssertTrue(enabled(restore))

        // A new launch reads the pack from disk.
        app.terminate()
        app.launchArguments = UITestSupport.launchArguments(language: "en", locale: "en_US", token: token, isolated: true)
        app.launch()
        UITestSupport.dismissSystemAlerts()
        UITestSupport.openPlaybackStopFixture(in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        menu.tap()
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        XCTAssertTrue(enabled(restore), "the backup did not survive a new launch")

        restore.tap()
        let restoreQuestion = app.alerts["Restore the previous backup?"]
        XCTAssertTrue(restoreQuestion.waitForExistence(timeout: 5))
        UITestSupport.attachScreenshot("mapping-04-confirm-restore", to: self)
        restoreQuestion.buttons["Restore"].tap()
        XCTAssertTrue(app.staticTexts["Previous autoplay restored. You can swap back from the menu."].waitForExistence(timeout: 10))
        UITestSupport.attachScreenshot("mapping-05-restored", to: self)
        XCTAssertTrue(enabled(restore), "the replaced version must stay one restore away")
    }

    private func enabled(_ element: XCUIElement) -> Bool {
        element.waitForExistence(timeout: 5)
            && XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)], timeout: 5) == .completed
    }
}
