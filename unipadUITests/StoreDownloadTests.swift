import XCTest

/// `testDownloadingAStorePackInstallsIt` downloads a real pack from the real store into the
/// simulator's own library; the other checks download a fixture pack from fixture answers in a
/// library of their own.
final class StoreDownloadTests: XCTestCase {

    private static let installTimeout: TimeInterval = 300
    /// Store rows passed as already downloaded before the check gives up.
    private static let maxDownloadedRows = 40

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Downloads a real pack from the store and waits until it is installed, so the downloader is
    /// checked end to end (network, progress on screen, extraction, validation). Needs network
    /// access. Packs that earlier runs downloaded stay in the library, so the first rows can
    /// already be downloaded and the pack to download can be below the visible part of the list.
    @MainActor
    func testDownloadingAStorePackInstallsIt() throws {
        if UITestSupport.isReleaseSuite {
            throw XCTSkip("real store not checked: UNIPAD_RELEASE_SUITE=1 answers from fixtures")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30), "home never appeared")

        let list = UITestSupport.openStore(in: app, testCase: self)
        XCTAssertFalse(UITestSupport.storeRows(in: list)
            .containing(NSPredicate(format: "label == %@", "Downloaded Fixture")).firstMatch.exists,
                       "the store answered from fixtures, not the real store")
        let downloadButton = app.buttons["Download"].firstMatch
        try selectFirstPackNotDownloaded(in: list, app: app)
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 5), "the selected pack shows no Download button")
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

    /// Selects store rows from the top until one is not downloaded yet. A row is found again by
    /// its title: the list builds rows lazily and drops those scrolled away, so an index names a
    /// different row after every scroll.
    @MainActor
    private func selectFirstPackNotDownloaded(in list: XCUIElement, app: XCUIApplication) throws {
        let rows = UITestSupport.storeRows(in: list)
        var passed = Set<String>()
        while passed.count < Self.maxDownloadedRows {
            guard let title = try storeRowTitles(in: list).first(where: { !passed.contains($0) }) else {
                // Every row built so far is downloaded: move the list on to build the next ones.
                list.swipeUp(velocity: .slow)
                if try storeRowTitles(in: list).allSatisfy(passed.contains) {
                    XCTFail("every store pack is already downloaded (\(passed.count) rows)")
                    return
                }
                continue
            }
            let row = rows.containing(NSPredicate(format: "label == %@", title)).firstMatch
            guard UITestSupport.scrollIntoView(row, in: list, app: app) else {
                XCTFail("store row \"\(title)\" never scrolled into view")
                return
            }
            row.tap()
            // The selected row's flag reads whether the pack is in the library. The side panel is
            // not read: it fades from the previous row's details for half a second.
            let downloaded = row.staticTexts["Downloaded"]
            let notDownloaded = row.staticTexts["Download"]
            let answered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                downloaded.exists || notDownloaded.exists
            }, object: nil)
            guard XCTWaiter().wait(for: [answered], timeout: 5) == .completed else {
                XCTFail("store row \"\(title)\" did not show whether it is downloaded")
                return
            }
            if notDownloaded.exists { return }
            passed.insert(title)
        }
        XCTFail("the first \(Self.maxDownloadedRows) store packs are all downloaded")
    }

    /// Titles of the store rows the list has built, top first. A row shows its flag text (only
    /// while selected), then its title above its producer, then "LED ●" and "AUTOPLAY ●"; the
    /// title is the top text of the column right of the flag.
    private func storeRowTitles(in list: XCUIElement) throws -> [String] {
        func rows(in snapshot: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
            snapshot.identifier == "store.row" ? [snapshot] : snapshot.children.flatMap(rows(in:))
        }
        func texts(in snapshot: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
            (snapshot.elementType == .staticText ? [snapshot] : []) + snapshot.children.flatMap(texts(in:))
        }
        return try rows(in: list.snapshot())
            .sorted { $0.frame.minY < $1.frame.minY }
            .compactMap { row in
                let names = texts(in: row).filter { !$0.label.contains("●") && !$0.label.isEmpty }
                guard let column = names.map(\.frame.minX).max() else { return nil }
                return names.filter { $0.frame.minX == column }.min { $0.frame.minY < $1.frame.minY }?.label
            }
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
        app.launchArguments = UITestSupport.isolatedLibraryLaunchArguments() + [
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
