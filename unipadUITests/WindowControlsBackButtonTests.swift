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
    /// A finger lands anywhere on the chevron, whose glyph is 12.5pt wide.
    private static let chevronTouches: [(edge: String, offset: CGFloat)] = [("left edge", -6), ("middle", 0), ("right edge", 6)]

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
        // An upright iPad turns the app on its side, where a swipe cannot scroll the pack list,
        // so the store card has to be on screen without scrolling.
        app.launchArguments += UITestSupport.englishLaunchArguments(library: "empty")
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

    private func shrinkWindow(toHeight height: CGFloat) {
        for _ in 0..<3 where window.frame.height > height + 50 {
            let frame = window.frame
            dragWindowCorner(to: CGPoint(x: frame.maxX - Self.dragHandleInset, y: frame.midY + height / 2))
        }
    }

    private func fillScreen() {
        let screen = XCUIScreen.main.screenshot().image.size
        for _ in 0..<3 where window.frame.width < screen.width - 1 {
            dragWindowCorner(to: CGPoint(x: screen.width - Self.dragHandleInset, y: screen.height - Self.dragHandleInset))
        }
    }

    private func assertWindowFillsScreen() {
        let screen = XCUIScreen.main.screenshot().image.size
        XCTAssertGreaterThanOrEqual(window.frame.width, screen.width - 1, "the window does not fill the screen: \(window.frame) of \(screen)")
    }

    /// Where a point `offset` along the chevron from its middle is on screen. Accessibility
    /// reports a button in screen coordinates, except one reaching outside the window, which
    /// it reports in the window's own; an upright iPad turns the window's axes a quarter turn.
    private func screenPoint(of element: XCUIElement, offset: CGFloat, upright: Bool) -> CGVector {
        let frame = window.frame
        let reported = element.frame
        if frame.contains(reported) {
            return upright
                ? CGVector(dx: reported.midX, dy: reported.midY + offset)
                : CGVector(dx: reported.midX + offset, dy: reported.midY)
        }
        if upright {
            return CGVector(dx: frame.maxX - reported.midY, dy: frame.minY + reported.midX + offset)
        }
        return CGVector(dx: frame.minX + reported.midX + offset, dy: frame.minY + reported.midY)
    }

    private func touchBack(upright: Bool, arrivingAt marker: XCUIElement, _ screen: String) {
        for (edge, offset) in Self.chevronTouches {
            XCTAssertTrue(backButton.waitForExistence(timeout: 5), "\(screen) has no back button")
            let point = screenPoint(of: backButton, offset: offset, upright: upright)
            let name = "\(screen)-\(upright ? "upright" : "landscape")-\(edge)"
            UITestSupport.attachScreenshot("\(name)-before", to: self)
            XCTContext.runActivity(named: "touch \(edge) \(point) in window \(window.frame), back \(backButton.frame)") { _ in
                screenOrigin.withOffset(point).tap()
            }
            let arrived = marker.waitForExistence(timeout: 5)
            UITestSupport.attachScreenshot("\(name)-after", to: self)
            XCTAssertTrue(arrived, "the \(edge) of the back chevron of \(screen) did not respond to a touch")
            guard edge != Self.chevronTouches.last?.edge else { return }
            reopen(screen)
        }
    }

    private func openTheme() {
        app.buttons["Theme"].tap()
        XCTAssertTrue(app.staticTexts["Theme"].firstMatch.waitForExistence(timeout: 10), "theme never opened")
    }

    private func openSettings() {
        home.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "settings never opened")
    }

    /// Goes back to `screen` from where its back chevron led.
    private func reopen(_ screen: String) {
        switch screen {
        case "theme": openTheme()
        case "licenses": openLicenses()
        case "settings": openSettings()
        default: _ = UITestSupport.openStore(in: app, testCase: self)
        }
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
        openSettings()

        openTheme()
        touchBack(upright: upright, arrivingAt: settings, "theme")

        openLicenses()
        touchBack(upright: upright, arrivingAt: settings, "licenses")

        touchBack(upright: upright, arrivingAt: home, "settings")

        guard throughStore else { return }
        _ = UITestSupport.openStore(in: app, testCase: self)
        touchBack(upright: upright, arrivingAt: home, "store")
    }

    /// Compares snapshot frames, which stay in the app's own coordinates when the iPad is upright.
    private func assertTitle(_ title: String, ownRow: Bool, _ screen: String) throws {
        let text = app.staticTexts[title].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "\(screen) has no title")
        UITestSupport.attachScreenshot("\(screen)-title", to: self)
        let titleFrame = try text.snapshot().frame
        let back = try backButton.snapshot().frame
        let appWindow = try window.snapshot().frame
        XCTContext.runActivity(named: "\(screen): title \(titleFrame), back \(back), window \(appWindow)") { _ in }
        if ownRow {
            XCTAssertGreaterThan(titleFrame.minY, back.midY, "the title of \(screen) is not under the chevron")
        } else {
            XCTAssertLessThan(abs(titleFrame.midY - back.midY), back.height / 2, "the title of \(screen) left the chevron's row")
        }
    }

    private func walkTitles(ownRow: Bool, upright: Bool = false) throws {
        openSettings()
        try assertTitle("Settings", ownRow: ownRow, "settings")
        openTheme()
        try assertTitle("Theme", ownRow: ownRow, "theme")
        screenOrigin.withOffset(screenPoint(of: backButton, offset: 0, upright: upright)).tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "theme did not go back to settings")
        openLicenses()
        try assertTitle("Open Source License", ownRow: ownRow, "licenses")
    }

    func testTitlesGetTheirOwnRowInNarrowWindow() throws {
        shrinkWindow(toWidth: Self.narrowWidth)
        try walkTitles(ownRow: true)
    }

    func testTitlesStayBesideChevronInFullWindow() throws {
        fillScreen()
        assertWindowFillsScreen()
        try walkTitles(ownRow: false)
    }

    /// An upright window that only gets narrower leaves the sideways app all of its width.
    func testTitlesStayBesideChevronInNarrowUprightWindow() throws {
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        shrinkWindow(toWidth: Self.narrowWidth)
        try walkTitles(ownRow: false, upright: true)
    }

    /// The height of an upright window is the width of the sideways app.
    func testTitlesGetTheirOwnRowInShortUprightWindow() throws {
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        shrinkWindow(toWidth: Self.narrowWidth)
        shrinkWindow(toHeight: Self.narrowWidth)
        try walkTitles(ownRow: true, upright: true)
    }

    func testTitlesStayBesideChevronInFullUprightWindow() throws {
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        fillScreen()
        assertWindowFillsScreen()
        try walkTitles(ownRow: false, upright: true)
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
        fillScreen()
        assertWindowFillsScreen()
        walkBackButtons(upright: false, windowWidth: nil)
    }

    func testBackButtonsRespondInFullUprightWindow() {
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        fillScreen()
        assertWindowFillsScreen()
        // The store's header sits under the status bar in this window, which takes the touch.
        walkBackButtons(upright: true, windowWidth: nil, throughStore: false)
    }
}
