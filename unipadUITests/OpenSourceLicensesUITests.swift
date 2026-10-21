//
//  OpenSourceLicensesUITests.swift
//  unipadUITests
//
//  Settings' "Open Source License" row has to show the notices of the components
//  built into this app inside the app, not send the user to a web page.
//

import XCTest

final class OpenSourceLicensesUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()
        let home = app.buttons["gearshape"]
        XCTAssertTrue(home.waitForExistence(timeout: 30), "home never appeared")
        home.tap()
        XCTAssertTrue(app.buttons["Information"].waitForExistence(timeout: 10), "settings never opened")
    }

    private func button(titled title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private var licenseText: XCUIElement {
        app.staticTexts["openSourceLicenseText"]
    }

    private func openLicenses() {
        let row = button(titled: "Open Source License")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Open Source License row is missing")
        let pane = app.scrollViews.containing(NSPredicate(format: "label BEGINSWITH %@", "Open Source License")).firstMatch
        XCTAssertTrue(UITestSupport.scrollIntoView(row, in: pane, app: app, maxSwipes: 5),
                      "Open Source License row is never fully on screen")
        UITestSupport.attachScreenshot("settings-row", to: self)
        row.tap()
    }

    private func select(_ name: String, expecting phrase: String) {
        let component = button(titled: name)
        XCTAssertTrue(component.waitForExistence(timeout: 10), "\(name) is not listed")
        component.tap()
        let shown = NSPredicate(format: "label CONTAINS %@", phrase)
        let arrived = XCTNSPredicateExpectation(predicate: shown, object: licenseText)
        XCTAssertEqual(XCTWaiter().wait(for: [arrived], timeout: 10), .completed,
                       "\(name) license text does not mention \"\(phrase)\"")
        UITestSupport.attachScreenshot("license-\(name)", to: self)
    }

    @MainActor
    func testLicensesOpenInsideTheApp() throws {
        openLicenses()
        XCTAssertTrue(licenseText.waitForExistence(timeout: 10), "no license text in the app")
        XCTAssertEqual(app.state, .runningForeground, "the row left the app")
        UITestSupport.attachScreenshot("licenses", to: self)

        select("libogg", expecting: "Xiph.org Foundation")
        select("libvorbis", expecting: "Xiph.org Foundation")
        select("Firebase Apple SDK", expecting: "Apache License")

        UITestSupport.tapBack(in: app)
        XCTAssertTrue(app.buttons["Information"].waitForExistence(timeout: 10), "back did not return to settings")
    }
}
