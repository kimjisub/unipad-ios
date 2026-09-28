import XCTest

/// Downloads a real pack from the store and waits until it is installed, so the downloader is
/// checked end to end (network, progress on screen, extraction, validation). Needs network access.
final class StoreDownloadTests: XCTestCase {

    private static let installTimeout: TimeInterval = 300

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDownloadingAStorePackInstallsIt() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30), "home never appeared")

        let list = UITestSupport.openStore(in: app, testCase: self)
        let downloadButton = app.buttons["Download"].firstMatch
        let rows = UITestSupport.storeRows(in: list)
        var index = 0
        while !downloadButton.exists {
            guard index < rows.count else {
                XCTFail("every store pack on screen is already downloaded")
                return
            }
            let row = rows.element(boundBy: index)
            if !row.isHittable { list.swipeUp() }
            row.tap()
            _ = downloadButton.waitForExistence(timeout: 2)
            index += 1
        }
        UITestSupport.attachScreenshot("store-download-selected", to: self)
        downloadButton.tap()

        let progress = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '%' AND label CONTAINS 'MB'")).firstMatch
        if progress.waitForExistence(timeout: 30) {
            UITestSupport.attachScreenshot("store-download-progress", to: self)
        }

        let installed = app.staticTexts["Downloaded"].firstMatch
        let done = installed.waitForExistence(timeout: Self.installTimeout)
        UITestSupport.attachScreenshot(done ? "store-download-installed" : "store-download-not-installed", to: self)
        XCTAssertTrue(done, "the pack was not installed within \(Int(Self.installTimeout)) s")
    }
}
