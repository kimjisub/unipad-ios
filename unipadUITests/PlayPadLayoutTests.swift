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
        app.launchArguments += ["-UniPadFirebaseLocalOnly", "YES"]
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

    /// Sets a play option switch through the menu. The row is one combined
    /// accessibility element labelled with the option's name.
    /// The option panel scrolls on a landscape iPhone, so the switch is first brought into view.
    /// Each row carries a long-press gesture over its whole width, so only the toggle at the
    /// trailing edge flips the value.
    private func setOption(_ label: String, on: Bool) {
        let row = app.switches[label].firstMatch
        guard row.waitForExistence(timeout: 5) else {
            XCTFail("no \(label) option in the menu")
            return
        }
        let panel = app.scrollViews.firstMatch
        let inView = { panel.frame.contains(row.frame) }
        for _ in 0..<6 where !inView() {
            if row.frame.midY < panel.frame.midY { panel.swipeDown(velocity: .slow) } else { panel.swipeUp(velocity: .slow) }
        }
        guard inView() else {
            XCTFail("\(label) option never scrolled into view")
            return
        }

        let isOn: () -> Bool = { (row.value as? String) == "1" }
        guard isOn() != on else { return }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(isOn(), on, "\(label) option did not switch")
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
        setOption("Trace Log", on: true)
        setOption("LED", on: false)
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
