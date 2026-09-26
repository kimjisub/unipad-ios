//
//  HomeGuidingCardsTests.swift
//  unipadUITests
//
//  The home screen reaches the store and file import only through the two
//  described cards; the top bar keeps search and nothing else. These tests make
//  sure the cards still lead somewhere, that the bar did not grow the duplicate
//  icons back, and that search, settings and rotation survive around them.
//

import XCTest

final class HomeGuidingCardsTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments += ["-UniPadFirebaseLocalOnly", "YES"]
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(home.waitForExistence(timeout: 30), "home never appeared")
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private var home: XCUIElement { app.buttons["gearshape"] }
    private var backButton: XCUIElement { app.buttons["chevron.left"].firstMatch }

    /// The top bar with search only exists once there is at least one pack.
    private func requireTopBar() throws -> XCUIElement {
        let search = app.buttons["magnifyingglass"].firstMatch
        guard search.waitForExistence(timeout: 30) else {
            throw XCTSkip("the list is empty, so the top bar is not shown")
        }
        return search
    }

    @MainActor
    func testTopBarHasNoDuplicateStoreOrImportIcons() throws {
        _ = try requireTopBar()
        UITestSupport.attachScreenshot("home", to: self)
        XCTAssertFalse(app.buttons["cart"].exists, "the top bar still has a cart icon")
        XCTAssertFalse(app.buttons["folder"].exists, "the top bar still has a folder icon")
        XCTAssertTrue(UITestSupport.revealHomeCard(.download, in: app).isHittable, "download card is not reachable")
        XCTAssertTrue(UITestSupport.revealHomeCard(.import, in: app).isHittable, "import card is not reachable")
    }

    @MainActor
    func testDownloadCardOpensStoreAndReturnsHome() throws {
        UITestSupport.revealHomeCard(.download, in: app).tap()
        XCTAssertTrue(backButton.waitForExistence(timeout: 10), "download card did not open the store")
        XCTAssertFalse(home.exists, "still on home after tapping the download card")
        UITestSupport.attachScreenshot("store-from-card", to: self)
        backButton.tap()
        XCTAssertTrue(home.waitForExistence(timeout: 10), "back from the store did not arrive home")
    }

    @MainActor
    func testImportCardOpensFilePicker() throws {
        UITestSupport.revealHomeCard(.import, in: app).tap()
        // The picker is a system sheet; its cancel button is the one control
        // every locale and iOS version shows.
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "취소"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "import card did not open the file picker")
        UITestSupport.attachScreenshot("file-picker-from-card", to: self)
        cancel.tap()
        XCTAssertTrue(home.waitForExistence(timeout: 10), "home did not come back after cancelling the picker")
    }

    @MainActor
    func testSearchStillOpensFromTopBar() throws {
        let search = try requireTopBar()
        search.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), "search field did not open")
        UITestSupport.attachScreenshot("search-open", to: self)
        search.tap()
        XCTAssertFalse(app.textFields.firstMatch.waitForExistence(timeout: 2), "search field did not close")
    }

    @MainActor
    func testCardsStayWhenSearchFindsNothing() throws {
        try requireTopBar().tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "search field did not open")
        field.tap()
        // In landscape the keyboard covers the cards, so return has to put it
        // away before the cards can be reached.
        field.typeText("zz-no-such-pack-zz\n")
        let keyboardGone = NSPredicate(format: "exists == false")
        let dismissal = expectation(for: keyboardGone, evaluatedWith: app.keyboards.firstMatch)
        wait(for: [dismissal], timeout: 5)
        let card = app.buttons[UITestSupport.HomeCard.download.rawValue].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no download card when search finds nothing")
        XCTAssertTrue(app.buttons[UITestSupport.HomeCard.import.rawValue].exists, "no import card when search finds nothing")
        XCTAssertTrue(card.isHittable, "download card is covered after the keyboard went away")
        UITestSupport.attachScreenshot("search-empty", to: self)
        card.tap()
        XCTAssertTrue(backButton.waitForExistence(timeout: 10), "download card in empty search did not open the store")
    }

    @MainActor
    func testSettingsStillOpensFromHome() throws {
        home.tap()
        XCTAssertTrue(app.buttons["Information"].waitForExistence(timeout: 10), "settings never opened")
        backButton.tap()
        XCTAssertTrue(home.waitForExistence(timeout: 10), "back from settings did not arrive home")
    }

    @MainActor
    func testCardsSurviveRotation() throws {
        for orientation in [UIDeviceOrientation.landscapeRight, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(home.waitForExistence(timeout: 5), "home lost after rotating to \(orientation.rawValue)")
            let card = UITestSupport.revealHomeCard(.download, in: app)
            XCTAssertTrue(card.isHittable, "download card not reachable after rotating to \(orientation.rawValue)")
            UITestSupport.attachScreenshot("rotated-\(orientation.rawValue)", to: self)
        }
    }
}
