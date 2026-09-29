//
//  PlayPadLayoutTests.swift
//  unipadUITests
//
//  Opens the first installed pack and checks the play screen's layout with real
//  input: the pad grid sits on the window's centre line, the chain column and the
//  menu stay clear of each other and reachable, and pads answer where they are
//  drawn. Needs a pack in the library; ios_shots.sh installs one.
//
//  Pad presses are attached as screenshots rather than asserted on. The trace
//  log is switched on and the LEDs off first, so each dot in the last shot marks
//  where a tap was received and can be compared with the pad drawn under it.
//

import XCTest

final class PlayPadLayoutTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()
    }

    private func openFirstPack() throws {
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30), "never reached home")
        let packTitles = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", " - "))
        guard packTitles.count > 0 else { throw XCTSkip("no pack in the library") }
        let title = packTitles.element(boundBy: 0)
        title.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() } else { title.tap() }
    }

    @MainActor
    func testPadsAreCentredAndReachable() throws {
        try openFirstPack()

        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "pad grid never appeared")
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "menu button never appeared")
        sleep(1)
        UITestSupport.attachScreenshot("play-idle", to: self)

        let window = app.windows.firstMatch.frame
        XCTAssertEqual(grid.frame.midX, window.midX, accuracy: 1, "pad grid is off the window's centre line")

        let cell = grid.frame.width / 8
        let chainColumnRight = grid.frame.maxX + cell
        XCTAssertLessThanOrEqual(chainColumnRight, menu.frame.minX, "right chain column runs under the menu")

        menu.tap()
        XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 5), "option panel never opened")
        UITestSupport.setPlayOption("Trace Log", on: true, in: app)
        UITestSupport.setPlayOption("LED", on: false, in: app)
        UITestSupport.attachScreenshot("option-panel", to: self)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "option panel never closed")
        sleep(1)

        // Corners and the four centre pads around the phantom diamond.
        let pads: [(row: Int, col: Int)] = [(0, 0), (0, 7), (7, 0), (7, 7), (3, 3), (3, 4), (4, 3), (4, 4)]
        for pad in pads {
            let point = grid.coordinate(withNormalizedOffset: CGVector(
                dx: (CGFloat(pad.col) + 0.5) / 8,
                dy: (CGFloat(pad.row) + 0.5) / 8
            ))
            point.tap()
        }
        sleep(1)
        UITestSupport.attachScreenshot("pads-traced", to: self)

        let secondChain = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: grid.frame.maxX + cell / 2,
            dy: grid.frame.minY + cell * 1.5
        ))
        secondChain.tap()
        sleep(1)
        UITestSupport.attachScreenshot("chain-2", to: self)

        XCTAssertTrue(menu.isHittable, "menu button is covered")
        menu.tap()
        XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 5), "option panel never opened")
        UITestSupport.attachScreenshot("option-panel-again", to: self)
    }
}
