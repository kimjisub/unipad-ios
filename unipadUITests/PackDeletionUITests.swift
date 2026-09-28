//
//  PackDeletionUITests.swift
//  unipadUITests
//

import XCTest

/// Delete confirmation on the home screen. The pack is copied into the app's
/// Documents/UniPack by the host before the run (a UI test cannot write into the
/// app's sandbox); without it the tests are skipped.
final class PackDeletionUITests: XCTestCase {

    static let packTitle = "UI Test Pack"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()
    }

    private var packRow: XCUIElement {
        app.staticTexts[Self.packTitle].firstMatch
    }

    private var deleteButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'trash' OR label == 'Delete'")).firstMatch
    }

    private func openDeleteConfirmation() throws {
        guard packRow.waitForExistence(timeout: 30) else {
            throw XCTSkip("'\(Self.packTitle)' is not installed in Documents/UniPack")
        }
        if !deleteButton.exists {
            packRow.tap()
        }
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), "Pack panel did not open")
        deleteButton.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "Delete confirmation did not appear")
        attach("delete_confirmation")
    }

    func testCancelKeepsPack() throws {
        try openDeleteConfirmation()

        app.alerts.firstMatch.buttons["Cancel"].tap()

        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 1))
        XCTAssertTrue(packRow.exists, "Cancel removed the pack from the list")
        attach("after_cancel")
    }

    /// Bookmarks the pack first so the host can check that a reinstall does not bring the bookmark back.
    func testAcceptRemovesPack() throws {
        guard packRow.waitForExistence(timeout: 30) else {
            throw XCTSkip("'\(Self.packTitle)' is not installed in Documents/UniPack")
        }
        packRow.tap()
        let bookmark = app.buttons.matching(NSPredicate(format: "identifier == 'bookmark' OR label == 'Bookmark'")).firstMatch
        if bookmark.waitForExistence(timeout: 5) {
            bookmark.tap()
        }
        try openDeleteConfirmation()

        app.alerts.firstMatch.buttons["Accept"].tap()

        let gone = NSPredicate(format: "exists == false")
        let removal = expectation(for: gone, evaluatedWith: app.staticTexts[Self.packTitle].firstMatch)
        wait(for: [removal], timeout: 10)
        attach("after_delete")
    }

    /// The home screen's total play count, shown while no pack is selected.
    private var totalPlayCount: XCUIElement {
        app.staticTexts["main.total.playCount"].firstMatch
    }

    private func readTotalPlayCount() -> Int? {
        guard totalPlayCount.waitForExistence(timeout: 10) else { return nil }
        return Int(totalPlayCount.label)
    }

    /// Needs the host to seed the pack's saved play count and to pass it as
    /// `TEST_RUNNER_UNIPAD_DELETED_PACK_PLAYS` to xcodebuild.
    func testAcceptUpdatesTotalPlayCountWithoutRelaunch() throws {
        guard let plays = ProcessInfo.processInfo.environment["UNIPAD_DELETED_PACK_PLAYS"].flatMap(Int.init) else {
            throw XCTSkip("The pack's play count is not set up by the host")
        }
        guard packRow.waitForExistence(timeout: 30) else {
            throw XCTSkip("'\(Self.packTitle)' is not installed in Documents/UniPack")
        }
        let before = try XCTUnwrap(readTotalPlayCount(), "Total play count is not shown")
        attach("total_before_delete")

        try openDeleteConfirmation()
        app.alerts.firstMatch.buttons["Accept"].tap()

        let removal = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: packRow)
        wait(for: [removal], timeout: 10)
        let expected = NSPredicate(format: "label == %@", String(before - plays))
        wait(for: [expectation(for: expected, evaluatedWith: totalPlayCount)], timeout: 5)
        attach("total_after_delete")
    }

    /// Cancelling leaves the saved plays, so the total must not move.
    func testCancelKeepsTotalPlayCount() throws {
        guard packRow.waitForExistence(timeout: 30) else {
            throw XCTSkip("'\(Self.packTitle)' is not installed in Documents/UniPack")
        }
        let before = try XCTUnwrap(readTotalPlayCount(), "Total play count is not shown")

        try openDeleteConfirmation()
        app.alerts.firstMatch.buttons["Cancel"].tap()
        // The open pack panel repeats the title, so deselect through the list row.
        app.scrollViews["main.packList"].staticTexts[Self.packTitle].firstMatch.tap()

        XCTAssertEqual(readTotalPlayCount(), before)
        attach("total_after_cancel")
    }

    /// Needs the host to lock the pack folder first (`chflags -R uchg`, so no file in it
    /// can be removed) and to pass
    /// `TEST_RUNNER_UNIPAD_EXPECT_DELETE_FAILURE=1` to xcodebuild.
    func testFailedDeleteShowsErrorAndAllowsRetry() throws {
        guard ProcessInfo.processInfo.environment["UNIPAD_EXPECT_DELETE_FAILURE"] == "1" else {
            throw XCTSkip("Deletion failure is not set up by the host")
        }
        guard packRow.waitForExistence(timeout: 30) else {
            throw XCTSkip("'\(Self.packTitle)' is not installed in Documents/UniPack")
        }
        let totalBefore = readTotalPlayCount()
        for attempt in 1...2 {
            try openDeleteConfirmation()
            app.alerts.firstMatch.buttons["Accept"].tap()

            let error = app.alerts["ERROR"]
            XCTAssertTrue(error.waitForExistence(timeout: 5), "No error alert after failed delete (attempt \(attempt))")
            XCTAssertTrue(error.staticTexts["An error has occurred."].exists)
            attach("delete_failure_alert_\(attempt)")

            error.buttons["OK"].tap()
            XCTAssertFalse(error.waitForExistence(timeout: 1), "Error alert did not close")
            XCTAssertTrue(packRow.waitForExistence(timeout: 5), "Pack vanished although its files could not be deleted")
            XCTAssertEqual(readTotalPlayCount(), totalBefore, "Total play count changed although the pack was kept")
            attach("after_failure_dismissed_\(attempt)")
        }
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
