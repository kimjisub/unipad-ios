import XCTest

/// Stage one original pack in the existing isolated test library before running this check.
/// UNIPAD_WARNING_TOKEN identifies that library; UNIPAD_WARNING_KIND is sound, info or none.
final class PackWarningUITests: XCTestCase {
    @MainActor
    func testStagedPackWarningInputAndExit() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let token = environment["UNIPAD_WARNING_TOKEN"], UUID(uuidString: token) != nil,
              let kind = environment["UNIPAD_WARNING_KIND"] else {
            throw XCTSkip("stage a pack and provide its isolated library token and warning kind")
        }
        XCTAssertTrue(["sound", "info", "none"].contains(kind))
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments()
        app.launchArguments += ["-UniPadReleaseTest", token]
        app.launch()
        defer { app.terminate() }

        let list = app.scrollViews["main.packList"]
        XCTAssertTrue(list.waitForExistence(timeout: 30))
        // The metadata-error sample has an empty title. Its only card still has an LED label.
        let card = list.staticTexts.matching(identifier: "LED ●")
        XCTAssertTrue(card.firstMatch.waitForExistence(timeout: 30))
        XCTAssertEqual(card.count, 1, "the isolated library must contain exactly one pack")
        UITestSupport.attachScreenshot("01-pack-list", to: self)
        card.firstMatch.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()

        let warning = app.alerts["Warning"]
        if kind == "none" {
            XCTAssertFalse(warning.waitForExistence(timeout: 6), "a valid pack must not warn")
        } else {
            let appeared = warning.waitForExistence(timeout: 15)
            UITestSupport.attachScreenshot("02-pack-warning", to: self)
            XCTAssertTrue(appeared, "pack warning was lost")
            let expected = kind == "sound"
                ? "keySound : [1 1 1 nope.wav] sound was not found"
                : "info : title was missing\ninfo : producerName was missing"
            XCTAssertTrue(warning.staticTexts[expected].exists, "warning content: \(warning.debugDescription)")
            warning.buttons["Accept"].tap()
        }

        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 15))
        XCTAssertFalse(warning.exists, "warning appeared again after dismissal")
        UITestSupport.attachScreenshot("03-ready-to-play", to: self)
        let menu = app.buttons["line.3.horizontal"]
        menu.tap()
        UITestSupport.setPlayOption("Feedback light", on: true, in: app)
        UITestSupport.setPlayOption("Trace Log", on: true, in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()

        // All three staged samples have a centred square grid, three columns and four rows.
        let cell = min(grid.frame.width / 3, grid.frame.height / 4)
        let pad = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: grid.frame.midX - cell * 1.5 + cell / 2,
            dy: grid.frame.midY - cell * 2 + cell / 2
        ))
        print("PACK_WARNING press-start \(Date().timeIntervalSince1970) grid=\(grid.frame)")
        pad.press(forDuration: 2)
        print("PACK_WARNING release-end \(Date().timeIntervalSince1970)")
        XCTAssertTrue(grid.exists, "player disappeared after pad press and release")
        XCTAssertFalse(warning.exists, "warning appeared again after input")
        UITestSupport.attachScreenshot("04-after-pad-release", to: self)
        menu.tap()
        let quit = app.buttons["rectangle.portrait.and.arrow.right"]
        XCTAssertTrue(quit.waitForExistence(timeout: 5))
        quit.tap()
        XCTAssertTrue(list.waitForExistence(timeout: 15), "quit did not return to the pack list")
        XCTAssertFalse(grid.exists)
        XCTAssertEqual(app.state, .runningForeground)
        UITestSupport.attachScreenshot("05-returned-to-list", to: self)
    }
}
