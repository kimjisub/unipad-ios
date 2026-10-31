//
//  StoreBackButtonStatusBarTests.swift
//  unipadUITests
//
//  With an iPad held upright, the full-size window's top safe area is shorter than
//  the status bar, and the status bar takes every touch inside its band. The store's
//  back chevron has to stay below that band whichever way the iPad is turned.
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

    private func fillScreen() {
        let screen = XCUIScreen.main.screenshot().image.size
        for _ in 0..<3 where window.frame.width < screen.width - 1 {
            dragWindowCorner(to: CGVector(dx: screen.width - Self.dragHandleInset, dy: screen.height - Self.dragHandleInset))
        }
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
        turn(.portrait)
        _ = UITestSupport.openStore(in: app, testCase: self)
        touchBackButton("opened-upright")
    }

    func testShorterUprightWindowDoesNotMakeRoomForTheStatusBar() {
        turn(.portrait)
        fillScreen()
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
        turn(.portrait)
        touchBackButton("turned-upright")
    }

    func testBackButtonReturnsToItsPlaceAfterTurningBackToLandscape() {
        _ = UITestSupport.openStore(in: app, testCase: self)
        let landscapeFrame = UITestSupport.backButton(in: app).frame
        touchBackButton("opened-landscape")

        turn(.portrait)
        _ = UITestSupport.openStore(in: app, testCase: self)
        turn(.landscapeLeft)
        XCTAssertEqual(UITestSupport.backButton(in: app).frame, landscapeFrame,
                       "the store kept the upright window's clearance after turning back")
        touchBackButton("turned-landscape")
    }
}
