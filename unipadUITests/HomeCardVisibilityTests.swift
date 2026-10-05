import XCTest

/// Each run has its own offline library so both home layouts are exercised,
/// regardless of the packs a previous simulator user installed.
final class HomeCardVisibilityTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func launch(empty: Bool, orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments()
        if !app.launchArguments.contains("-UniPadReleaseTest") {
            app.launchArguments += ["-UniPadReleaseTest", UUID().uuidString]
        }
        app.launchArguments += ["-UniPadReleaseEmpty", empty ? "YES" : "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons[UITestSupport.HomeCard.download.rawValue].firstMatch.waitForExistence(timeout: 10))
        let list = app.scrollViews["main.packList"]
        if empty {
            let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: list)
            XCTAssertEqual(XCTWaiter().wait(for: [absent], timeout: 10), .completed)
        } else {
            XCTAssertTrue(list.waitForExistence(timeout: 10), "fixture packs never loaded")
        }
    }

    private func assertCardsAreRevealedPromptly(_ name: String) {
        for card in [UITestSupport.HomeCard.download, .import] {
            let start = Date()
            let element = UITestSupport.revealHomeCard(card, in: app, timeout: 20)
            let elapsed = Date().timeIntervalSince(start)
            let timing = XCTAttachment(string: "\(card.rawValue): \(elapsed) seconds (20 second deadline)")
            timing.name = "\(name)-\(card.rawValue)-timing"
            timing.lifetime = .keepAlways
            add(timing)
            UITestSupport.attachScreenshot("\(name)-\(card.rawValue)", to: self)
            XCTAssertLessThan(elapsed, 10, "visible card consumed the reveal deadline")
            XCTAssertTrue(app.windows.firstMatch.frame.contains(element.frame), "card is still outside the window")
            XCTAssertTrue(element.isHittable, "card is covered")
        }
    }

    @MainActor
    func testEmptyLibraryLandscapeLeft() {
        launch(empty: true, orientation: .landscapeLeft)
        assertCardsAreRevealedPromptly("empty-left")
    }

    @MainActor
    func testEmptyLibraryLandscapeRight() {
        launch(empty: true, orientation: .landscapeRight)
        assertCardsAreRevealedPromptly("empty-right")
    }

    @MainActor
    func testPopulatedLibraryLandscapeLeft() {
        launch(empty: false, orientation: .landscapeLeft)
        assertCardsAreRevealedPromptly("packs-left")
    }

    @MainActor
    func testPopulatedLibraryLandscapeRight() {
        launch(empty: false, orientation: .landscapeRight)
        assertCardsAreRevealedPromptly("packs-right")
    }

    @MainActor
    func testEmptySearchLandscapeRight() {
        launch(empty: false, orientation: .landscapeRight)
        app.buttons["magnifyingglass"].firstMatch.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("zz-no-such-pack-zz\n")
        let keyboardGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [keyboardGone], timeout: 5), .completed)
        XCTAssertFalse(app.scrollViews["main.packList"].exists)
        assertCardsAreRevealedPromptly("search-empty-right")
    }
}
