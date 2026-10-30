//
//  StoreBackButtonStatusBarTests.swift
//  unipadUITests
//
//  With an iPad held upright, the full-size window's top safe area is shorter than
//  the status bar, and the status bar takes every touch inside its band. The store's
//  back chevron has to stay below that band whichever way the iPad is turned.
//
//  The touch goes through SpringBoard at a screen point, because only a touch placed
//  on the screen is taken by the status bar; a tap on the element can miss the problem.
//

import XCTest

@MainActor
final class StoreBackButtonStatusBarTests: XCTestCase {

    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var app: XCUIApplication!

    private var home: XCUIElement { app.buttons["gearshape"] }

    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "only an iPad gets the short safe area")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(home.waitForExistence(timeout: 30), "home never appeared")
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func turn(_ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        sleep(2)
    }

    private func touchBackButton(_ name: String) {
        let frame = UITestSupport.backButton(in: app).frame
        UITestSupport.attachScreenshot("\(name)-before", to: self)
        XCTContext.runActivity(named: "touch back chevron at \(frame)") { _ in
            springboard.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
                .tap()
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

    func testBackButtonRespondsAfterTurningUprightInStore() {
        _ = UITestSupport.openStore(in: app, testCase: self)
        turn(.portrait)
        touchBackButton("turned-upright")
    }

    func testBackButtonRespondsAfterTurningBackToLandscape() {
        turn(.portrait)
        _ = UITestSupport.openStore(in: app, testCase: self)
        turn(.landscapeLeft)
        touchBackButton("turned-landscape")
    }
}
