//
//  PushIdentifierSettingsTests.swift
//  unipadUITests
//
//  The developer row in Settings copies whatever FCM addresses this install by.
//  In the token model it must stay exactly the "FCM Token" row it has always
//  been; in the installation-ID model it has to say so. Both runs are local-only,
//  so the stub answers instead of Firebase and the notice shown is the
//  "unavailable" one for the model on screen.
//

import XCTest

final class PushIdentifierSettingsTests: XCTestCase {

    private var app: XCUIApplication!

    /// The pane is laid out for the orientation the previous test left the device in, so each
    /// test starts from the same one.
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func openSettings(extraLaunchArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments() + extraLaunchArguments
        app.launch()
        UITestSupport.dismissSystemAlerts()
        let home = app.buttons["gearshape"]
        XCTAssertTrue(home.waitForExistence(timeout: 30), "home never appeared")
        home.tap()
        XCTAssertTrue(app.buttons["Information"].waitForExistence(timeout: 10), "settings never opened")
    }

    private func titled(_ title: String) -> NSPredicate {
        NSPredicate(format: "label BEGINSWITH %@", title)
    }

    private func row(titled title: String) -> XCUIElement {
        app.buttons.matching(titled(title)).firstMatch
    }

    /// The row sits at the bottom of the Information pane, below the fold in landscape.
    private func reveal(_ element: XCUIElement) {
        let pane = app.scrollViews.containing(titled(element.label)).firstMatch
        XCTAssertTrue(UITestSupport.scrollIntoView(element, in: pane, app: app, maxSwipes: 5),
                      "\(element.label) is never fully on screen")
        XCTAssertTrue(element.isHittable, "\(element) is never on screen")
    }

    private func assertAlertShows(_ message: String, name: String) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no alert after tapping the row")
        XCTAssertTrue(alert.staticTexts[message].exists, "alert does not say \"\(message)\"")
        UITestSupport.attachScreenshot("\(name)-alert", to: self)
        alert.buttons.firstMatch.tap()
    }

    private func checkTokenModel(_ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        openSettings()
        let tokenRow = row(titled: "FCM Token")
        XCTAssertTrue(tokenRow.waitForExistence(timeout: 10), "FCM Token row is missing")
        XCTAssertFalse(row(titled: "FCM Installation ID").exists)

        reveal(tokenRow)
        let name = "token-\(orientation == .landscapeLeft ? "left" : "right")"
        UITestSupport.attachScreenshot("\(name)-row", to: self)
        tokenRow.tap()
        assertAlertShows("FCM token unavailable", name: name)
    }

    private func checkInstallationModel(_ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        openSettings(extraLaunchArguments: ["-UniPadFakeInstallationIdModel", "YES"])
        let installationRow = row(titled: "FCM Installation ID")
        XCTAssertTrue(installationRow.waitForExistence(timeout: 10), "FCM Installation ID row is missing")
        XCTAssertFalse(row(titled: "FCM Token").exists)

        reveal(installationRow)
        let name = "installation-\(orientation == .landscapeLeft ? "left" : "right")"
        UITestSupport.attachScreenshot("\(name)-row", to: self)
        installationRow.tap()
        assertAlertShows("FCM installation ID unavailable", name: name)
    }

    @MainActor
    func testTokenModelKeepsTheFCMTokenRowLandscapeLeft() {
        checkTokenModel(.landscapeLeft)
    }

    @MainActor
    func testTokenModelKeepsTheFCMTokenRowLandscapeRight() {
        checkTokenModel(.landscapeRight)
    }

    @MainActor
    func testFakeInstallationModelShowsTheInstallationIDRowLandscapeLeft() {
        checkInstallationModel(.landscapeLeft)
    }

    @MainActor
    func testFakeInstallationModelShowsTheInstallationIDRowLandscapeRight() {
        checkInstallationModel(.landscapeRight)
    }
}
