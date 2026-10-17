import XCTest

/// Install Fixtures/PlaybackStop in Documents/UniPack before running; missing content fails the
/// check. Pad input XCUITest's public gestures can aim at pads, through the real touch path: one
/// finger dragged across pads (D), and the app leaving and returning with no finger held (part of
/// G). After each gesture every pad must look as it did before it: a pressed pad is drawn with the
/// theme's pressed image, so a pad left lit by lost input shows in the comparison. Several fingers at once (A, B, C, E, F),
/// released cancelled touches (G) and a finger resting beside the pads (I) are covered by
/// MultiTouchPlayTests through the same pad view. Not covered anywhere: a finger held while the
/// app leaves, since XCUITest cannot hold a press during another action. The public
/// several-finger gestures (`tap(withNumberOfTaps:numberOfTouches:)`, `pinch`,
/// `rotate`) place fingers by the element's size, and the pad grid is occluded in the
/// accessibility tree by the larger theme image, so their fingers miss the pads.
/// Synthetic input, not physical fingers.
final class MultiTouchPlayUITests: XCTestCase {
    private let app = XCUIApplication()
    private var grid: XCUIElement { app.otherElements["playPadGrid"] }

    @MainActor
    func testDraggedPadsGoDarkAndStayDarkAfterLeavingAndReturning() throws {
        continueAfterFailure = true
        app.launchArguments += UITestSupport.englishLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()
        UITestSupport.openPlaybackStopFixture(in: app)
        // Trace Log draws the tap path over the pads; it is left on by other checks.
        let menu = app.buttons["line.3.horizontal"]
        let exit = app.buttons["rectangle.portrait.and.arrow.right"]
        menu.tap()
        XCTAssertTrue(exit.waitForExistence(timeout: 5), "option panel never opened")
        UITestSupport.setPlayOption("Trace Log", on: false, in: app)
        let marginOffset = CGVector(dx: 0.1, dy: 0.5)
        app.coordinate(withNormalizedOffset: marginOffset).tap()
        // The menu button stays on screen under the open panel, so wait for a panel button to go.
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: exit)
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 5), .completed, "option panel never closed")
        XCTAssertTrue(UITestSupport.waitForHiddenWindowsPillToGo(timeout: 30), "the system pill stayed over the pads")
        let idle = try settledPads()
        UITestSupport.attachScreenshot("01-idle", to: self)

        pad(3, 3).press(forDuration: 0.3, thenDragTo: pad(3, 4))
        try expectNoPadLit(comparedWith: idle, after: "D drag to the next pad")
        pad(0, 0).press(forDuration: 0.2, thenDragTo: pad(7, 7))
        try expectNoPadLit(comparedWith: idle, after: "D drag across the grid")

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(grid.waitForExistence(timeout: 15), "the play screen did not come back")
        // The iPadOS window pill can stay until the app receives input. Use the same empty
        // margin that closed the options panel, without sending another touch to a pad.
        let appFrame = app.frame
        let marginPoint = CGPoint(x: appFrame.minX + appFrame.width * marginOffset.dx,
                                  y: appFrame.minY + appFrame.height * marginOffset.dy)
        let gridFrame = grid.frame
        guard !appFrame.isEmpty, !gridFrame.isEmpty, !gridFrame.contains(marginPoint) else {
            XCTFail("the system pill dismissal point must be outside the pads")
            return
        }
        app.coordinate(withNormalizedOffset: marginOffset).tap()
        XCTAssertTrue(UITestSupport.waitForHiddenWindowsPillToGo(timeout: 30), "the system pill stayed over the pads")
        try expectNoPadLit(comparedWith: idle, after: "G leaving and returning to the app with no finger held")
        UITestSupport.attachScreenshot("02-after-gestures", to: self)

        menu.tap()
        XCTAssertTrue(exit.waitForExistence(timeout: 5), "the screen stopped answering")
        exit.tap()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 10), "exit left the screen unresponsive")
    }

    @MainActor
    private func pad(_ row: Int, _ col: Int) -> XCUICoordinate {
        grid.coordinate(withNormalizedOffset: CGVector(dx: (CGFloat(col) + 0.5) / 8, dy: (CGFloat(row) + 0.5) / 8))
    }

    /// The pads' pixels once two consecutive shots agree, so a fading press is not compared.
    @MainActor
    private func settledPads() throws -> PadPixels {
        var last = try PadPixels(grid.screenshot())
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            let next = try PadPixels(grid.screenshot())
            if next.changedPads(comparedWith: last).isEmpty { return next }
            last = next
        }
        return last
    }

    @MainActor
    private func expectNoPadLit(comparedWith idle: PadPixels, after gesture: String) throws {
        let now = try settledPads()
        let changed = now.changedPads(comparedWith: idle)
        if !changed.isEmpty {
            UITestSupport.attachScreenshot("lit-after-\(gesture)", to: self)
        }
        XCTAssertEqual(changed, [], "pads (row, column from 1) still differ from idle after \(gesture)")
    }
}
