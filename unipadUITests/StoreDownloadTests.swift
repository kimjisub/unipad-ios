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
            guard UITestSupport.scrollIntoView(row, in: list, app: app) else {
                XCTFail("store row \(index) never scrolled into view")
                return
            }
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

    @MainActor
    func testInterruptedDownloadRecovers() throws {
        try downloadSlowFixture(interrupt: true, visitHome: false)
    }

    @MainActor
    func testDownloadContinuesDuringBriefHomeVisit() throws {
        try downloadSlowFixture(interrupt: false, visitHome: true)
    }

    @MainActor
    private func downloadSlowFixture(interrupt: Bool, visitHome: Bool) throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments() + [
            "-UniPadReleaseTest", UUID().uuidString,
            "-UniPadReleaseSlowDownload", "YES",
            "-UniPadReleaseInterruptDownload", interrupt ? "YES" : "NO",
        ]
        app.launch()
        defer { app.terminate() }
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        let list = UITestSupport.openStore(in: app, testCase: self)
        let row = UITestSupport.storeRows(in: list)
            .containing(NSPredicate(format: "label == %@", "Downloaded Fixture")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        app.buttons["Download"].firstMatch.tap()
        let decline = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons
            .matching(NSPredicate(format: "label IN %@", ["Don't Allow", "허용 안 함"])).firstMatch
        if decline.waitForExistence(timeout: 3) { decline.tap() }
        let progress = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '%' AND label CONTAINS 'MB'")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 15))
        UITestSupport.attachScreenshot("slow-download-in-progress", to: self)
        if visitHome {
            XCUIDevice.shared.press(.home)
            // Stay away for five seconds while the fixture sends the remaining bytes.
            let unreachable = NSPredicate(value: false)
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: unreachable, object: app)], timeout: 5)
            app.activate()
        }
        let done = row.staticTexts["Downloaded"].waitForExistence(timeout: 30)
        UITestSupport.attachScreenshot(done ? "slow-download-installed" : "slow-download-failed", to: self)
        XCTAssertTrue(done, "download did not recover and install")
    }
}
