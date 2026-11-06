//
//  StoreBackButtonStatusBarTests.swift
//  unipadUITests
//
//  With an iPad held upright, the full-size window's top safe area is shorter than
//  the status bar, and the status bar takes every touch inside its band. The store's
//  back chevron has to stay below that band whichever way the iPad is turned, and so
//  do the home screen's top controls.
//
//  The touch goes to a screen point, because only a touch placed on the screen is
//  taken by the status bar; a tap on the element can miss the problem.
//

import XCTest

@MainActor
final class StoreBackButtonStatusBarTests: XCTestCase {

    private static let dragHandleInset: CGFloat = 6

    private var app: XCUIApplication!

    private var home: XCUIElement { app.buttons["gearshape"] }

    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "only an iPad gets the short safe area")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = UITestSupport.isolatedLibraryLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(home.waitForExistence(timeout: 30), "home never appeared")
    }

    override func tearDownWithError() throws {
        guard app != nil else { return }
        // iPadOS remembers a window size per orientation, so each one is restored.
        fillScreen()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        fillScreen()
    }

    private var window: XCUIElement { app.windows.firstMatch }

    /// The window stays centred while its corner is dragged, so both sides move.
    private func dragWindowCorner(to target: CGVector) {
        let frame = window.frame
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard").coordinate(withNormalizedOffset: .zero)
        screen.withOffset(CGVector(dx: frame.maxX - Self.dragHandleInset, dy: frame.maxY - Self.dragHandleInset))
            .press(forDuration: 0.6, thenDragTo: screen.withOffset(target))
        sleep(2)
    }

    private var screenSize: CGSize {
        let shot = XCUIScreen.main.screenshot().image
        let scale = shot.scale / UIScreen.main.scale
        return CGSize(width: shot.size.width * scale, height: shot.size.height * scale)
    }

    private func fillScreen() {
        let screen = screenSize
        for _ in 0..<3 where window.frame.width < screen.width - 1 {
            dragWindowCorner(to: CGVector(dx: screen.width - Self.dragHandleInset, dy: screen.height - Self.dragHandleInset))
        }
    }

    /// Stands the iPad up in a window of the full screen: iPadOS keeps a smaller window an earlier
    /// test left behind, and the status bar does not reach one.
    private func standUp(_ orientation: UIDeviceOrientation = .portrait) {
        turn(orientation)
        fillScreen()
        XCTAssertEqual(window.frame.size, screenSize, "the upright window does not fill the screen")
    }

    /// How far below the window's top the chevron sits. An upright iPad keeps the app's landscape
    /// layout, turning its top toward the screen's right edge.
    private var backButtonDropInUprightWindow: CGFloat {
        window.frame.maxX - UITestSupport.backButton(in: app).frame.maxX
    }

    private func turn(_ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        sleep(2)
    }

    private func touchBackButton(_ name: String) {
        let backButton = UITestSupport.backButton(in: app)
        UITestSupport.attachScreenshot("\(name)-before", to: self)
        XCTContext.runActivity(named: "touch back chevron at \(backButton.frame)") { _ in
            UITestSupport.tapOnScreen(backButton, in: app)
        }
        let closed = home.waitForExistence(timeout: 5)
        UITestSupport.attachScreenshot("\(name)-after", to: self)
        XCTAssertTrue(closed, "the store's back chevron did not respond to a touch")
    }

    func testBackButtonRespondsWhenStoreOpensUpright() {
        standUp()
        _ = UITestSupport.openStore(in: app, testCase: self)
        touchBackButton("opened-upright")
    }

    func testBackButtonRespondsWhenStoreOpensUprightFromLandscapeRight() {
        turn(.landscapeRight)
        standUp()
        _ = UITestSupport.openStore(in: app, testCase: self)
        touchBackButton("opened-upright-from-right")
    }

    func testBackButtonRespondsWhenStoreOpensUpsideDown() {
        standUp(.portraitUpsideDown)
        _ = UITestSupport.openStore(in: app, testCase: self)
        touchBackButton("opened-upside-down")
    }

    func testBackButtonRespondsWhenStoreOpensUpsideDownFromLandscapeRight() {
        turn(.landscapeRight)
        standUp(.portraitUpsideDown)
        _ = UITestSupport.openStore(in: app, testCase: self)
        touchBackButton("opened-upside-down-from-right")
    }

    func testShorterUprightWindowDoesNotMakeRoomForTheStatusBar() {
        standUp()
        _ = UITestSupport.openStore(in: app, testCase: self)
        let fullWindowDrop = backButtonDropInUprightWindow

        for height: CGFloat in [600, 375] {
            let frame = window.frame
            dragWindowCorner(to: CGVector(dx: frame.midX + height / 2, dy: frame.maxY - Self.dragHandleInset))
            UITestSupport.attachScreenshot("upright-window-\(height)", to: self)
            XCTAssertLessThan(window.frame.width, frame.width, "the window did not shrink")
            XCTAssertLessThan(backButtonDropInUprightWindow, fullWindowDrop,
                              "the status bar does not reach a \(window.frame) window")
        }
    }

    func testBackButtonRespondsAfterTurningUprightInStore() {
        _ = UITestSupport.openStore(in: app, testCase: self)
        standUp()
        touchBackButton("turned-upright")
    }

    func testBackButtonReturnsToItsPlaceAfterTurningBackToLandscape() {
        _ = UITestSupport.openStore(in: app, testCase: self)
        let landscapeFrame = UITestSupport.backButton(in: app).frame
        touchBackButton("opened-landscape")

        standUp()
        _ = UITestSupport.openStore(in: app, testCase: self)
        turn(.landscapeLeft)
        XCTAssertEqual(UITestSupport.backButton(in: app).frame, landscapeFrame,
                       "the store kept the upright window's clearance after turning back")
        touchBackButton("turned-landscape")
    }

    // MARK: - Home screen

    private static let sortMethodNames = ["Title", "Producer", "Play Count", "Last Opened Date", "Download Date"]

    func testHomeTopControlsRespondInFullUprightWindow() {
        standUp()
        touchHomeTopControls("home-upright")
    }

    func testHomeTopControlsRespondInFullUpsideDownWindow() {
        standUp(.portraitUpsideDown)
        touchHomeTopControls("home-upside-down")
    }

    /// Every control along the top of the home screen, each touched where a finger would and
    /// put back the way it was.
    private func touchHomeTopControls(_ name: String) {
        let search = app.buttons["magnifyingglass"]
        let field = app.textFields.firstMatch
        touch(search, "\(name)-search-open", responds: { field.waitForExistence(timeout: 5) })
        touch(search, "\(name)-search-close", responds: { field.waitForNonExistence(timeout: 5) })

        let order = sortOrderButton
        let orderIdentifier = order.identifier
        let flipped = app.buttons[orderIdentifier == "chevron.down" ? "chevron.up" : "chevron.down"]
        touch(order, "\(name)-sort-order", responds: { flipped.waitForExistence(timeout: 5) })
        touch(flipped, "\(name)-sort-order-back", responds: { self.app.buttons[orderIdentifier].waitForExistence(timeout: 5) })

        touchSortMenu(name)

        let row = app.scrollViews["main.packList"].staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", " - ")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the fixture library has no pack")
        row.tap()
        let bookmark = app.buttons["bookmark"]
        let bookmarked = app.buttons["bookmark.fill"]
        touch(bookmark, "\(name)-bookmark", responds: { bookmarked.waitForExistence(timeout: 5) })
        touch(bookmarked, "\(name)-bookmark-back", responds: { bookmark.waitForExistence(timeout: 5) })

        let alert = app.alerts.firstMatch
        touch(app.buttons["trash"], "\(name)-delete", responds: { alert.waitForExistence(timeout: 5) })
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "the delete question did not close")

        let backButton = UITestSupport.backButton(in: app)
        touch(home, "\(name)-settings", responds: { backButton.waitForExistence(timeout: 5) })
        UITestSupport.tapBack(in: app)
        XCTAssertTrue(home.waitForExistence(timeout: 5), "Settings' back chevron did not return home")
    }

    private var sortOrderButton: XCUIElement {
        let down = app.buttons["chevron.down"]
        return down.waitForExistence(timeout: 5) ? down : app.buttons["chevron.up"]
    }

    /// Opens the sort menu and picks the method already in use. Picking it resets the order to
    /// that method's default, so the order the test found is put back afterwards.
    private func touchSortMenu(_ name: String) {
        let orderIdentifier = sortOrderButton.identifier
        let names = app.buttons.matching(NSPredicate(format: "label IN %@", Self.sortMethodNames))
        let menu = names.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the sort menu is not on the home screen")
        let menuFrame = menu.frame
        let current = menu.label
        touch(menu, "\(name)-sort-menu", responds: { names.element(boundBy: 1).waitForExistence(timeout: 5) })
        let item = app.buttons.matching(NSPredicate(format: "label == %@", current)).allElementsBoundByIndex
            .first { $0.frame != menuFrame }
        XCTAssertNotNil(item, "the sort menu lists no \(current)")
        item?.tap()
        XCTAssertTrue(names.element(boundBy: 1).waitForNonExistence(timeout: 5), "the sort menu did not close")
        if sortOrderButton.identifier != orderIdentifier {
            UITestSupport.tapOnScreen(sortOrderButton, in: app)
            XCTAssertTrue(app.buttons[orderIdentifier].waitForExistence(timeout: 5), "the sort order was not put back")
        }
    }

    /// How far below the window's top `element` starts. The app keeps its landscape layout on an
    /// upright iPad, so its top is the screen's left or right edge, whichever is nearer.
    private func depthBelowWindowTop(_ element: XCUIElement) -> CGFloat {
        min(window.frame.maxX - element.frame.maxX, element.frame.minX - window.frame.minX)
    }

    private func touch(_ element: XCUIElement, _ name: String, responds: () -> Bool) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(name): the control is not on screen")
        UITestSupport.attachScreenshot("\(name)-before", to: self)
        XCTContext.runActivity(named: "touch \(name) at \(element.frame), \(depthBelowWindowTop(element))pt below the window's top") { _ in
            UITestSupport.tapOnScreen(element, in: app)
        }
        let responded = responds()
        UITestSupport.attachScreenshot("\(name)-after", to: self)
        XCTAssertTrue(responded, "\(name): the control did not respond to a touch")
    }
}
