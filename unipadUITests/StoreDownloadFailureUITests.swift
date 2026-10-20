import XCTest

/// A store pack whose file is gone from the server must say so: the row keeps reading "Failed"
/// after the download stops, and the pack can still be downloaded again. Runs on the offline store
/// fixture, where "Missing Fixture" answers 404.
final class StoreDownloadFailureUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    @MainActor
    func testFailedDownloadStaysMarkedFailed() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = UITestSupport.isolatedLibraryLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30), "home never appeared")

        let list = UITestSupport.openStore(in: app, testCase: self)
        let row = UITestSupport.storeRows(in: list).containing(NSPredicate(format: "label == %@", "Missing Fixture")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the missing-file fixture is not in the store")
        row.tap()

        let download = app.buttons["Download"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5), "selecting the pack did not offer a download")
        download.tap()
        UITestSupport.dismissSystemAlerts()

        let failed = row.staticTexts["Failed"]
        let shown = failed.waitForExistence(timeout: 15)
        UITestSupport.attachScreenshot(shown ? "store-download-failed" : "store-download-failure-not-shown", to: self)
        XCTAssertTrue(shown, "the row never said the download failed")

        // Nothing else happens until the user acts, so the mark must still be there a while later.
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: failed)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 3), .timedOut, "the failure mark disappeared on its own")
        XCTAssertTrue(download.isHittable, "the pack can no longer be downloaded again")
    }
}
