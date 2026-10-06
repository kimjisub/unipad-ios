//
//  PlayUsageRecordUITests.swift
//  unipadUITests
//
//  Drives the real play screen to the situations whose play-start record is in question:
//  menu only, a practice mode chosen in the menu, a real pad tap, autoplay, and the order of
//  those. A UI test cannot read what the app recorded, so each test only walks the screen and
//  marks its steps in the test log (`PLAYUSAGE-UI <test> <step> <time>`); the records are read
//  from the app's own local-only analytics log while the tests run:
//
//    xcrun simctl spawn <udid> log stream --level info \
//      --predicate 'category == "AnalyticsLocal"' > analytics.log &
//
//  The app is launched with -UniPadFirebaseLocalOnly YES (UITestSupport), so nothing reaches
//  Firebase. Needs a pack titled "First Input Fixture" in the app's library (Documents/UniPack); the
//  unit tests in PlayUsageRecordTests describe the same pack:
//    info: title=First Input Fixture, producerName=Tester, buttonX=8, buttonY=8, chain=1, squareButton=true
//    keySound: "1 1 1 a.wav", "1 1 2 a.wav", "1 1 3 a.wav"   sounds/a.wav: silent 16-bit PCM
//    autoPlay: on 1 1 / delay 400 / on 1 2 / delay 400 / on 1 3
//
//  A real Launchpad cannot be attached to the simulator; MIDI input is covered in the unit tests.
//

import XCTest

final class PlayUsageRecordUITests: XCTestCase {

    private static let packTitle = "First Input Fixture"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()
    }

    // MARK: - Steps

    private static let markerTime: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()

    private func mark(_ step: String) {
        print("PLAYUSAGE-UI \(name) \(step) \(Self.markerTime.string(from: Date()))")
    }

    private func shot(_ label: String) {
        UITestSupport.attachScreenshot("\(name)-\(label)", to: self)
    }

    private func openProbePack() throws -> XCUIElement {
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30), "never reached home")
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", Self.packTitle)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "install test-fixtures/PlayUsage first")
        mark("open pack")
        title.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() } else { title.tap() }

        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "pad grid never appeared")
        XCTAssertTrue(app.buttons["line.3.horizontal"].waitForExistence(timeout: 10), "menu button never appeared")
        sleep(1)
        mark("pack ready")
        shot("1-ready")
        return grid
    }

    private func openMenu() {
        mark("open menu")
        app.buttons["line.3.horizontal"].tap()
        XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 5), "option panel never opened")
        shot("2-menu")
    }

    /// Picks a play mode in the menu; the app closes the menu itself.
    private func chooseMode(_ label: String) {
        mark("choose \(label)")
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(label) mode button in the menu")
        button.tap()
        mark("tapped \(label)")
        XCTAssertTrue(app.buttons["line.3.horizontal"].waitForExistence(timeout: 5), "menu did not close after choosing \(label)")
        sleep(1)
        shot("3-mode-\(label)")
    }

    private func closeMenu() {
        mark("close menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["line.3.horizontal"].waitForExistence(timeout: 5), "option panel never closed")
    }

    private func tapPad(_ grid: XCUIElement, row: Int = 3, column: Int = 3) {
        mark("tap pad row=\(row) col=\(column)")
        grid.coordinate(withNormalizedOffset: CGVector(dx: (CGFloat(column) + 0.5) / 8, dy: (CGFloat(row) + 0.5) / 8)).tap()
        mark("tapped pad row=\(row) col=\(column)")
        sleep(1)
        shot("4-after-tap")
    }

    /// Leaves through the menu's quit button, which pops the play screen.
    private func leaveToHome() {
        openMenu()
        mark("quit")
        app.buttons["rectangle.portrait.and.arrow.right"].tap()
        mark("tapped quit")
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 10), "did not return home")
        sleep(1)
        mark("home")
        shot("5-home")
    }

    // MARK: - Scenarios

    @MainActor
    func testU1MenuOnly() throws {
        _ = try openProbePack()
        openMenu()
        closeMenu()
        leaveToHome()
    }

    @MainActor
    func testU2StepModeChosenInMenuThenLeave() throws {
        _ = try openProbePack()
        openMenu()
        chooseMode("Step")
        leaveToHome()
    }

    @MainActor
    func testU3GuideModeChosenInMenuThenLeave() throws {
        _ = try openProbePack()
        openMenu()
        chooseMode("Guide")
        leaveToHome()
    }

    @MainActor
    func testU4ScreenPadTap() throws {
        let grid = try openProbePack()
        tapPad(grid)
        tapPad(grid, row: 3, column: 4)
        leaveToHome()
    }

    @MainActor
    func testU5AutoplayFromMenu() throws {
        _ = try openProbePack()
        openMenu()
        chooseMode("Autoplay")
        sleep(2)
        shot("3b-autoplay-running-or-done")
        leaveToHome()
    }

    @MainActor
    func testU6PadTapThenAutoplay() throws {
        let grid = try openProbePack()
        tapPad(grid)
        openMenu()
        chooseMode("Autoplay")
        sleep(2)
        leaveToHome()
    }

    @MainActor
    func testU7StepModeThenPadTap() throws {
        let grid = try openProbePack()
        openMenu()
        chooseMode("Step")
        tapPad(grid, row: 0, column: 0)
        leaveToHome()
    }

    @MainActor
    func testU9AutoplayThenFirstHumanTap() throws {
        let grid = try openProbePack()
        openMenu()
        chooseMode("Autoplay")
        sleep(2)
        tapPad(grid)
        tapPad(grid, row: 3, column: 4)
        leaveToHome()
    }

    @MainActor
    func testU8StepModeThenAutoplay() throws {
        _ = try openProbePack()
        openMenu()
        chooseMode("Step")
        openMenu()
        chooseMode("Autoplay")
        sleep(2)
        leaveToHome()
    }
}
