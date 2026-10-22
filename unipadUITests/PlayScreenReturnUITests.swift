import XCTest

/// The device screen opened from the connection banner covers the play screen; coming back from it
/// returns to the same performance. Lights are read from the pad grid's pixels, so the checks are
/// about what is drawn, not about sound.
final class PlayScreenReturnUITests: XCTestCase {
    @MainActor
    func testAutoplayAndLightsGoOnAfterReturningFromTheDeviceScreen() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments(library: "play-return")
        app.launchArguments += ["-UniPadReleaseMidiBanner", "YES"]
        app.launch()
        defer { app.terminate() }
        UITestSupport.dismissSystemAlerts()
        let list = app.scrollViews["main.packList"]
        XCTAssertTrue(list.waitForExistence(timeout: 30))
        let title = list.staticTexts.matching(NSPredicate(format: "label == %@", "Play Return Fixture")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the isolated library must stage the fixture")
        title.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        let grid = app.otherElements["playPadGrid"]
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30))
        XCTAssertTrue(menu.waitForExistence(timeout: 30))

        menu.tap()
        let autoplay = app.buttons["Autoplay"].firstMatch
        XCTAssertTrue(autoplay.waitForExistence(timeout: 5))
        autoplay.tap()
        let pause = app.buttons["pause.fill"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "autoplay did not start")
        XCTAssertFalse(try padsChanging(grid).isEmpty, "autoplay drew no lights before leaving")
        UITestSupport.attachScreenshot("return-01-autoplay-before", to: self)

        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "the connection banner is not shown")
        open.tap()
        let ok = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "OK")).firstMatch
        XCTAssertTrue(ok.waitForExistence(timeout: 10), "the device screen did not open")
        UITestSupport.attachScreenshot("return-02-device-screen", to: self)
        ok.tap()

        XCTAssertTrue(pause.waitForExistence(timeout: 15), "autoplay is not playing after coming back")
        UITestSupport.attachScreenshot("return-03-after-return", to: self)
        XCTAssertFalse(try padsChanging(grid).isEmpty, "no lights moved after coming back from the device screen")

        pause.tap()
        let resume = app.buttons["play.fill"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(try padsChanging(grid).isEmpty, "lights kept moving with autoplay paused")
        UITestSupport.attachScreenshot("return-04-paused", to: self)
        resume.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertFalse(try padsChanging(grid).isEmpty, "no lights moved after resuming autoplay")
        UITestSupport.attachScreenshot("return-05-resumed", to: self)

        // A pad pressed by hand lights again: the screen draws presses after the return.
        pause.tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        let still = try PadPixels(grid.screenshot())
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.9375, dy: 0.9375)).tap()
        let pressed = try PadPixels(grid.screenshot())
        UITestSupport.attachScreenshot("return-06-pressed", to: self)
        XCTAssertEqual(pressed.changedPads(comparedWith: still), ["8,8"], "a pressed pad drew no light after the return")
    }

    /// The pads whose colour changed over one second.
    @MainActor
    private func padsChanging(_ grid: XCUIElement) throws -> [String] {
        let first = try PadPixels(grid.screenshot())
        Thread.sleep(forTimeInterval: 1)
        return try PadPixels(grid.screenshot()).changedPads(comparedWith: first)
    }
}
