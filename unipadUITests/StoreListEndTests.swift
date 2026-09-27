import XCTest

final class StoreListEndTests: XCTestCase {

    private static let homeIndicatorInset: CGFloat = 21

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    /// Rotates before launching, so home is laid out once in the final orientation and the card
    /// is not tapped at coordinates left over from the rotation.
    private func launch(in orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30), "home never appeared")
    }

    private func openStore() -> XCUIElement {
        let back = app.buttons["chevron.left"].firstMatch
        for _ in 0..<3 where !back.exists {
            UITestSupport.revealHomeCard(.download, in: app).tap()
            _ = back.waitForExistence(timeout: 5)
        }
        let list = app.scrollViews["store.list"]
        if !list.waitForExistence(timeout: 30) {
            UITestSupport.attachScreenshot("store-not-loaded", to: self)
            XCTFail(back.exists ? "store list never loaded (no network on the simulator?)" : "download card did not open the store")
        }
        XCTAssertTrue(rows(in: list).firstMatch.waitForExistence(timeout: 15), "store list has no rows")
        return list
    }

    private func rows(in list: XCUIElement) -> XCUIElementQuery {
        list.descendants(matching: .any).matching(identifier: "store.row")
    }

    private func scrollToEnd(_ list: XCUIElement) -> XCUIElement {
        var previous = CGRect.null
        for _ in 0..<40 {
            list.swipeUp(velocity: .fast)
            let last = lowestVisibleRow(in: list)
            if last.frame == previous { return last }
            previous = last.frame
        }
        XCTFail("store list never reached its end")
        return lowestVisibleRow(in: list)
    }

    private func lowestVisibleRow(in list: XCUIElement) -> XCUIElement {
        let window = app.windows.firstMatch.frame
        let visible = rows(in: list).allElementsBoundByIndex.filter {
            $0.exists && !$0.frame.isEmpty && $0.frame.minY < window.maxY
        }
        return visible.max { $0.frame.maxY < $1.frame.maxY } ?? rows(in: list).firstMatch
    }

    private func assertLastRowClearsHomeIndicator(_ orientation: UIDeviceOrientation, _ name: String) {
        launch(in: orientation)
        let list = openStore()
        let last = scrollToEnd(list)
        UITestSupport.attachScreenshot("store-end-\(name)", to: self)

        let limit = app.windows.firstMatch.frame.maxY - Self.homeIndicatorInset
        XCTAssertLessThanOrEqual(
            last.frame.maxY, limit,
            "\(name): last row \(last.frame) ends under the home indicator (from \(limit))"
        )

        last.tap()
        let flag = NSPredicate(format: "label == %@ OR label == %@", "Download", "Downloaded")
        XCTAssertTrue(
            app.staticTexts.matching(flag).firstMatch.waitForExistence(timeout: 5),
            "\(name): tapping the last row did not select it"
        )
        UITestSupport.attachScreenshot("store-end-selected-\(name)", to: self)
    }

    @MainActor
    func testLastRowClearsHomeIndicatorLandscapeLeft() throws {
        assertLastRowClearsHomeIndicator(.landscapeLeft, "landscapeLeft")
    }

    @MainActor
    func testLastRowClearsHomeIndicatorLandscapeRight() throws {
        assertLastRowClearsHomeIndicator(.landscapeRight, "landscapeRight")
    }
}
