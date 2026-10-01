// Test-only overlay for baseline 5dd4cac. Never copy into the product sources.
import XCTest

final class PlayPadLayoutTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments()
        XCTAssertTrue(app.launchArguments.contains("-UniPadFirebaseLocalOnly"))
        app.launch()
    }

    private func evidence(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-tree"
        tree.lifetime = .keepAlways
        add(tree)
        print("CONFORMANCE \(name) \(Date().timeIntervalSince1970)")
    }

    @MainActor
    func testSyntheticPackInputAutoplayAndExit() throws {
        let list = app.scrollViews["main.packList"]
        XCTAssertTrue(list.waitForExistence(timeout: 30), "Pack list missing")
        let matches = list.staticTexts.matching(NSPredicate(format: "label == %@", "Conformance"))
        XCTAssertEqual(matches.count, 1, "Stage one unchanged fixture at a time; titles are shared")
        let title = matches.firstMatch
        if !title.isHittable {
            list.swipeUp()
        }
        XCTAssertTrue(title.isHittable, "Exact fixture title not reachable")
        evidence("01-exact-title")
        title.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5), "Pack selection did not expose Play")
        evidence("02-selected")
        play.tap()

        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "Player missing")
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        // The existing trace overlay proves the canvas received the touch.
        menu.tap()
        UITestSupport.setPlayOption("Feedback light", on: true, in: app)
        UITestSupport.setPlayOption("Trace Log", on: true, in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        evidence("03-player-idle")

        // AP-001 is 4 rows x 3 columns, square pads. Match PadGridView's
        // centering calculation instead of assuming the legacy 8 x 8 layout.
        let frame = grid.frame
        let cell = min(frame.width / 3, frame.height / 4)
        let originX = frame.minX + (frame.width - cell * 3) / 2
        let originY = frame.minY + (frame.height - cell * 4) / 2
        let firstPad = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: originX + cell / 2, dy: originY + cell / 2))
        print("CONFORMANCE press-start \(Date().timeIntervalSince1970) grid=\(frame) cell=\(cell)")
        firstPad.press(forDuration: 2)
        print("CONFORMANCE release-end \(Date().timeIntervalSince1970)")
        evidence("04-input-released")

        menu.tap()
        let auto = app.buttons["Autoplay"]
        XCTAssertTrue(auto.waitForExistence(timeout: 5), "Fixture must have autoplay")
        evidence("05-autoplay-option")
        print("CONFORMANCE autoplay-start \(Date().timeIntervalSince1970)")
        auto.tap()
        // AP-001 ends in 900 ms and removes transport in onEnd(). XCTest
        // waits for app idle, so inspect the video for the transient transport.
        XCTAssertTrue(grid.exists, "Player disappeared after Autoplay")
        evidence("06-autoplay-returned-player")
        sleep(2)
        evidence("07-autoplay-after-sequence")

        menu.tap()
        let quit = app.buttons["Quit"]
        XCTAssertTrue(quit.waitForExistence(timeout: 5), "Quit missing")
        evidence("08-quit-option")
        quit.tap()
        XCTAssertTrue(list.waitForExistence(timeout: 10), "Did not return to pack list")
        XCTAssertFalse(grid.exists, "Player still shown after Quit")
        evidence("09-returned-list")
        app.terminate()
    }
}
