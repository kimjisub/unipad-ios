import XCTest

/// The device screen opened from the connection banner covers the play screen; coming back from it
/// returns to the same performance. Lights are read from the pad grid's pixels, so the checks are
/// about what is drawn, not about sound.
final class PlayScreenReturnUITests: XCTestCase {
    /// A pack closed from the play screen leaves the main screen working: the same pack opens again.
    @MainActor
    func testClosingAPackReturnsToTheMainScreenAndItOpensAgain() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments(library: "play-return")
        app.launch()
        defer { app.terminate() }
        UITestSupport.dismissSystemAlerts()
        let list = app.scrollViews["main.packList"]
        let title = list.staticTexts.matching(NSPredicate(format: "label == %@", "Play Return Fixture")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "the isolated library must stage the fixture")

        for round in 1...2 {
            // The pack stays selected on the way back, so a second tap would close it.
            if round == 1 { title.tap() }
            let play = app.buttons["Play"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 5), "round \(round): the pack did not show Play")
            play.tap()
            let menu = app.buttons["line.3.horizontal"]
            XCTAssertTrue(menu.waitForExistence(timeout: 30), "round \(round): the play screen never became ready")
            UITestSupport.attachScreenshot("reopen-\(round)-1-play", to: self)

            menu.tap()
            let exit = app.buttons["rectangle.portrait.and.arrow.right"]
            XCTAssertTrue(exit.waitForExistence(timeout: 5), "round \(round): the menu has no exit")
            exit.tap()
            XCTAssertTrue(UITestSupport.waitUntilHittable(title, timeout: 15), "round \(round): the main screen did not come back")
            UITestSupport.attachScreenshot("reopen-\(round)-2-main", to: self)
        }
    }

    @MainActor
    func testAutoplayWaitsForManualResumeAfterReturningFromTheDeviceScreen() throws {
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

        let resume = app.buttons["play.fill"].firstMatch
        let waitsForPlay = resume.waitForExistence(timeout: 15)
        UITestSupport.attachScreenshot("return-03-after-return", to: self)
        XCTAssertTrue(waitsForPlay, "returning from the device screen must wait for Play")
        XCTAssertFalse(pause.exists, "returning from the device screen must not resume autoplay")
        XCTAssertTrue(try padsChanging(grid).isEmpty, "old lights moved before a manual resume")
        Thread.sleep(forTimeInterval: 10)
        XCTAssertTrue(resume.exists)
        XCTAssertFalse(pause.exists)
        XCTAssertTrue(try padsChanging(grid).isEmpty, "old lights resumed while waiting for Play")
        resume.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertFalse(try padsChanging(grid).isEmpty, "new autoplay lights did not start after Play")
        UITestSupport.attachScreenshot("return-03-manually-resumed", to: self)

        pause.tap()
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

    /// The sounds fail to load while the user reads the device screen over the play screen. The
    /// device screen stays until the user leaves it; then the play screen says its sounds cannot
    /// open, and its pack list button goes back to the list.
    @MainActor
    func testASoundLoadFailingUnderTheDeviceScreenTellsAfterTheReturn() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments(library: "sound-failure")
        app.launchArguments += ["-UniPadReleaseMidiBanner", "YES", "-UniPadReleaseHoldSoundLoad", "YES"]
        app.launch()
        defer { app.terminate() }
        UITestSupport.dismissSystemAlerts()
        let list = app.scrollViews["main.packList"]
        let title = list.staticTexts.matching(NSPredicate(format: "label == %@", "Sound Failure Fixture")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 60), "the isolated library must stage the fixture")
        title.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        let started = ProcessInfo.processInfo.systemUptime
        func record(_ step: String) {
            let seconds = ProcessInfo.processInfo.systemUptime - started
            let note = XCTAttachment(string: "\(step): \(String(format: "%.3f", seconds))s after Play")
            note.name = step
            note.lifetime = .keepAlways
            add(note)
        }
        record("play-tap-start")
        play.tap()

        // The sound count appears once the engine reads the sounds; opening the device screen
        // before that would only restart the load when the play screen is shown again.
        let soundProgress = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", ".*\\(\\d+/\\d+\\)")).firstMatch
        XCTAssertTrue(soundProgress.waitForExistence(timeout: 30), "the sounds never started loading")
        record("sound-progress-visible")
        let loadState = app.otherElements["test.soundLoadState"]
        let holding = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "holding"), object: loadState)
        XCTAssertEqual(XCTWaiter.wait(for: [holding], timeout: 5), .completed, "the loader must wait for connection help")
        XCTAssertFalse(app.staticTexts["Can't open this pack's sounds"].exists, "failure arrived before the screen was covered")
        UITestSupport.attachScreenshot("failure-00-loading-held", to: self)
        XCTAssertFalse(app.alerts.firstMatch.exists, "the pack warned on opening, so more than its sounds failed")
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "the connection banner is not shown")
        open.tap()
        let ok = app.buttons["midi.confirm"]
        XCTAssertTrue(ok.waitForExistence(timeout: 10), "the device screen did not open")
        // Reading the connection help stops the device screen from confirming itself after 5 s.
        app.buttons["midi.help.open"].tap()
        let closeHelp = app.buttons["midi.help.close"]
        XCTAssertTrue(closeHelp.waitForExistence(timeout: 5), "the connection help did not open")
        record("connection-help-visible")
        // Observe the actual failure applied to the covered play screen before returning. A delay
        // cannot establish this, and an already-failed pack never reaches the required held state.
        let failedUnderCover = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "failed-under-cover"), object: loadState)
        XCTAssertEqual(XCTWaiter.wait(for: [failedUnderCover], timeout: 30), .completed,
                       "the sounds must fail while the device screen covers Play: \(loadState.label)")
        record("failure-applied-under-cover")
        let timeline = XCTAttachment(string: loadState.label)
        timeline.name = "sound-load-order"
        timeline.lifetime = .keepAlways
        add(timeline)
        closeHelp.tap()
        // Closing help restores the selection controls' accessibility and focus asynchronously.
        // Its close button disappearing alone does not mean OK can receive the next tap yet.
        XCTAssertTrue(UITestSupport.waitUntilHittable(ok, timeout: 5), "the device screen did not become available after closing help")
        XCTAssertFalse(closeHelp.exists, "the connection help did not close")
        UITestSupport.attachScreenshot("failure-01-device-screen", to: self)

        // The real failure has completed; it must leave the device screen in place.
        XCTAssertTrue(ok.exists && ok.isHittable, "the failed load closed the device screen instead of the play screen")
        UITestSupport.attachScreenshot("failure-02-after-the-load", to: self)
        ok.tap()

        let failure = app.staticTexts["Can't open this pack's sounds"]
        XCTAssertTrue(failure.waitForExistence(timeout: 15), "the play screen did not say its sounds failed")
        record("failure-visible-after-return")
        UITestSupport.attachScreenshot("failure-03-after-the-return", to: self)
        XCTAssertFalse(soundProgress.exists, "the sounds were still loading when the device screen closed; nothing was checked")
        app.buttons["soundLoadPackListButton"].tap()
        XCTAssertTrue(UITestSupport.waitUntilHittable(title, timeout: 15), "the pack list button did not go back to the list")
    }

    /// The pads whose colour changed over one second.
    @MainActor
    private func padsChanging(_ grid: XCUIElement) throws -> [String] {
        let first = try PadPixels(grid.screenshot())
        Thread.sleep(forTimeInterval: 1)
        return try PadPixels(grid.screenshot()).changedPads(comparedWith: first)
    }
}
