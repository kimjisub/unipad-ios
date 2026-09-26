//
//  SettingsBackNavigationTests.swift
//  unipadUITests
//
//  Settings hides the system navigation bar and draws its own back chevron, so
//  nothing but that button (and the size SwiftUI gives it) gets the user home.
//  These tests tap that button the way a user would and require both that it
//  works and that it is at least the 44pt Apple asks for, repeatedly and after
//  going through Theme, which is pushed on top of Settings.
//

import XCTest

final class SettingsBackNavigationTests: XCTestCase {

    private static let minimumTouchSize: CGFloat = 44

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        // A back that fails leaves the app on the wrong screen; every later step
        // would be measuring something else.
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UniPadFirebaseLocalOnly", "YES"]
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(home.waitForExistence(timeout: 30), "home never appeared")
    }

    private var home: XCUIElement { app.buttons["gearshape"] }
    private var settings: XCUIElement { app.buttons["Information"] }
    private var backButton: XCUIElement { app.buttons["chevron.left"].firstMatch }

    private func openSettings() {
        home.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "settings never opened")
    }

    private func assertComfortablyTappable(_ element: XCUIElement, _ screen: String) {
        let frame = element.frame
        XCTContext.runActivity(named: "\(screen) back button frame \(frame)") { _ in
            XCTAssertGreaterThanOrEqual(frame.width, Self.minimumTouchSize, "\(screen) back is \(frame.width)pt wide")
            XCTAssertGreaterThanOrEqual(frame.height, Self.minimumTouchSize, "\(screen) back is \(frame.height)pt tall")
        }
    }

    private func tapBack(from screen: String, expecting marker: XCUIElement) {
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "\(screen) has no back button")
        XCTAssertTrue(backButton.isHittable, "\(screen) back button is not hittable")
        backButton.tap()
        XCTAssertTrue(marker.waitForExistence(timeout: 10), "back from \(screen) did not arrive")
    }

    @MainActor
    func testSettingsBackIsLargeEnoughToTap() throws {
        openSettings()
        UITestSupport.attachScreenshot("settings", to: self)
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "settings has no back button")
        assertComfortablyTappable(backButton, "settings")
    }

    @MainActor
    func testSettingsBackReturnsHomeRepeatedly() throws {
        for round in 1...3 {
            XCTContext.runActivity(named: "round \(round)") { _ in
                openSettings()
                tapBack(from: "settings", expecting: home)
                XCTAssertFalse(settings.exists, "settings still on screen after back")
            }
        }
    }

    @MainActor
    func testBackThroughThemeReturnsHome() throws {
        openSettings()
        app.buttons["Theme"].tap()
        XCTAssertTrue(app.staticTexts["Theme"].firstMatch.waitForExistence(timeout: 10), "theme never opened")
        tapBack(from: "theme", expecting: settings)
        tapBack(from: "settings", expecting: home)
        UITestSupport.attachScreenshot("home-after-theme", to: self)
    }
}
