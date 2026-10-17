//
//  PackDeletionUITests.swift
//  unipadUITests
//

import XCTest

/// Each check gets an isolated generated pack. Play counts are created through UI input;
/// deletion failures protect the generated pack and exercise the real file removal path.
final class PackDeletionUITests: XCTestCase {

    static let packTitle = "UI Test Pack"

    private var app: XCUIApplication!
    private let token = UUID().uuidString
    private var expectsDeleteFailure: Bool { name.contains("testFailedDelete") }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments(library: "deletion", token: token)
            + ["-UniPadUITestDeleteFailure", expectsDeleteFailure ? "YES" : "NO"]
        app.launch()
        UITestSupport.dismissSystemAlerts()
    }

    override func tearDownWithError() throws {
        if expectsDeleteFailure {
            app.terminate()
            app.launchArguments = UITestSupport.englishLaunchArguments(library: "deletion", token: token)
                + ["-UniPadUITestDeleteFailure", "NO"]
            app.launch()
            XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30), "the protected fixture must be unlocked")
        }
        app.terminate()
    }

    private var packRow: XCUIElement {
        app.scrollViews["main.packList"].staticTexts[Self.packTitle].firstMatch
    }

    private var deleteButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'trash' OR label == 'Delete'")).firstMatch
    }

    private func openDeleteConfirmation() throws {
        XCTAssertTrue(packRow.waitForExistence(timeout: 30), "the fixture must prepare \(Self.packTitle)")
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
        XCTAssertTrue(packRow.waitForExistence(timeout: 30), "the fixture must prepare \(Self.packTitle)")
        packRow.tap()
        let bookmark = app.buttons.matching(NSPredicate(format: "identifier == 'bookmark' OR label == 'Bookmark'")).firstMatch
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        bookmark.tap()
        XCTAssertTrue(app.buttons["bookmark.fill"].waitForExistence(timeout: 5))
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

    /// Playing first creates a nonzero count, without host-prepared database rows.
    func testAcceptUpdatesTotalPlayCountWithoutRelaunch() throws {
        UITestSupport.playAndReturn(packRow, in: app)
        let plays = 1
        let before = try XCTUnwrap(readTotalPlayCount(), "Total play count is not shown")
        XCTAssertEqual(before, plays)
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
        UITestSupport.playAndReturn(packRow, in: app)
        let before = try XCTUnwrap(readTotalPlayCount(), "Total play count is not shown")
        XCTAssertEqual(before, 1)

        try openDeleteConfirmation()
        app.alerts.firstMatch.buttons["Cancel"].tap()
        // The open pack panel repeats the title, so deselect through the list row.
        app.scrollViews["main.packList"].staticTexts[Self.packTitle].firstMatch.tap()

        XCTAssertEqual(readTotalPlayCount(), before)
        attach("total_after_cancel")
    }

    /// The fixture protects all its files; both failed attempts must retain the pack and count.
    func testFailedDeleteShowsErrorAndAllowsRetry() throws {
        UITestSupport.playAndReturn(packRow, in: app)
        let totalBefore = try XCTUnwrap(readTotalPlayCount())
        XCTAssertEqual(totalBefore, 1)
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
