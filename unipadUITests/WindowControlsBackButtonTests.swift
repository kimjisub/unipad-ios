//
//  WindowControlsBackButtonTests.swift
//  unipadUITests
//
//  In a shrunk iPad window the system draws its window controls over the top
//  left corner, where Settings, Theme and the license screen put their own back
//  chevron. A touch there has to reach the chevron, not the window controls.
//
//  These windows are small enough that accessibility reports the chevron in the
//  window's own coordinates, and they keep the app's landscape layout when the
//  iPad is held upright, so the tests convert that position to a screen point
//  by hand and touch it through SpringBoard.
//

import XCTest

@MainActor
final class WindowControlsBackButtonTests: XCTestCase {

    /// The system stops a window at 375pt wide; asking for less gets the narrowest one.
    private static let narrowWidth: CGFloat = 250
    private static let mediumWidth: CGFloat = 800
    private static let dragHandleInset: CGFloat = 6

    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var app: XCUIApplication!

    private var screenOrigin: XCUICoordinate { springboard.coordinate(withNormalizedOffset: .zero) }
    private var window: XCUIElement { app.windows.firstMatch }
    private var home: XCUIElement { app.buttons["gearshape"] }
    private var settings: XCUIElement { app.buttons["Information"] }
    private var backButton: XCUIElement { UITestSupport.backButton(in: app) }

    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "only an iPad window can be resized")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments()
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

    /// The window stays centred while its corner is dragged, so both sides move.
    private func dragWindowCorner(to target: CGPoint) {
        let frame = window.frame
        let handle = CGVector(dx: frame.maxX - Self.dragHandleInset, dy: frame.maxY - Self.dragHandleInset)
        screenOrigin.withOffset(handle)
            .press(forDuration: 0.6, thenDragTo: screenOrigin.withOffset(CGVector(dx: target.x, dy: target.y)))
        sleep(2)
    }

    private func shrinkWindow(toWidth width: CGFloat) {
        for _ in 0..<3 where window.frame.width > width + 50 {
            let frame = window.frame
            dragWindowCorner(to: CGPoint(x: frame.midX + width / 2, y: frame.maxY - Self.dragHandleInset))
        }
        XCTAssertLessThan(window.frame.width, width + 150, "the window did not shrink: \(window.frame)")
    }

    private func fillScreen() {
        let screen = XCUIScreen.main.screenshot().image.size
        for _ in 0..<3 where window.frame.width < screen.width - 1 {
            dragWindowCorner(to: CGPoint(x: screen.width - Self.dragHandleInset, y: screen.height - Self.dragHandleInset))
        }
    }

    /// Where the middle of `element` is on screen. Accessibility reports a button in
    /// screen coordinates, except one reaching outside the window, which it reports
    /// in the window's own; an upright iPad turns the window's axes a quarter turn.
    private func screenPoint(of element: XCUIElement, upright: Bool) -> CGVector {
        let frame = window.frame
        let reported = element.frame
        if frame.contains(reported) {
            return CGVector(dx: reported.midX, dy: reported.midY)
        }
        if upright {
            return CGVector(dx: frame.maxX - reported.midY, dy: frame.minY + reported.midX)
        }
        return CGVector(dx: frame.minX + reported.midX, dy: frame.minY + reported.midY)
    }

    private func touchBack(upright: Bool, arrivingAt marker: XCUIElement, _ screen: String) {
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "\(screen) has no back button")
        let point = screenPoint(of: backButton, upright: upright)
        let name = "\(screen)-\(upright ? "upright" : "landscape")"
        UITestSupport.attachScreenshot("\(name)-before", to: self)
        XCTContext.runActivity(named: "touch \(point) in window \(window.frame), back \(backButton.frame)") { _ in
            screenOrigin.withOffset(point).tap()
        }
        let arrived = marker.waitForExistence(timeout: 5)
        UITestSupport.attachScreenshot("\(name)-after", to: self)
        XCTAssertTrue(arrived, "the back chevron of \(screen) did not respond to a touch")
    }

    private func openLicenses() {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open Source License")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Open Source License row is missing")
        let pane = app.scrollViews.containing(NSPredicate(format: "label BEGINSWITH %@", "Open Source License")).firstMatch
        for _ in 0..<12 where !row.isHittable { pane.swipeUp() }
        row.tap()
        XCTAssertTrue(app.staticTexts["openSourceLicenseText"].waitForExistence(timeout: 10), "licenses never opened")
    }

    private func walkBackButtons(upright: Bool, windowWidth: CGFloat?, throughStore: Bool = true) {
        if upright {
            XCUIDevice.shared.orientation = .portrait
            sleep(2)
        }
        if let windowWidth { shrinkWindow(toWidth: windowWidth) }
        UITestSupport.attachScreenshot("home-\(upright ? "upright" : "landscape")", to: self)
        home.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "settings never opened")

        app.buttons["Theme"].tap()
        XCTAssertTrue(app.staticTexts["Theme"].firstMatch.waitForExistence(timeout: 10), "theme never opened")
        touchBack(upright: upright, arrivingAt: settings, "theme")

        openLicenses()
        touchBack(upright: upright, arrivingAt: settings, "licenses")

        touchBack(upright: upright, arrivingAt: home, "settings")

        guard throughStore else { return }
        _ = UITestSupport.openStore(in: app, testCase: self)
        touchBack(upright: upright, arrivingAt: home, "store")
    }

    func testBackButtonsRespondInNarrowLandscapeWindow() {
        walkBackButtons(upright: false, windowWidth: Self.narrowWidth)
    }

    func testBackButtonsRespondInNarrowUprightWindow() {
        walkBackButtons(upright: true, windowWidth: Self.narrowWidth)
    }

    func testBackButtonsRespondInMediumWindow() {
        walkBackButtons(upright: false, windowWidth: Self.mediumWidth)
    }

    func testBackButtonsRespondInFullWindow() {
        walkBackButtons(upright: false, windowWidth: nil)
    }

    func testBackButtonsRespondInFullUprightWindow() {
        // The store's header sits under the status bar in this window, which takes the touch.
        walkBackButtons(upright: true, windowWidth: nil, throughStore: false)
    }
}
