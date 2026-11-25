import XCTest

/// Requires the local demo Firebase emulators on ports 5051 and 9051. Never uses production data.
final class StoreDownloadAccountingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["UNIPAD_DOWNLOAD_ACCOUNTING_EMULATOR"] == "1" else {
            throw XCTSkip("Requires the local demo download-accounting emulators")
        }
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    @MainActor
    func testEachSeparateSavedDownloadAddsOne() async throws {
        try await seed(enabled: true)
        for expected in [101, 102] {
            launch()
            try download("Downloaded Fixture", expecting: "Downloaded")
            try await waitForCount("saved", expected)
            app.terminate()
        }
    }

    @MainActor
    func testInterruptedTransferAddsOneAfterSaving() async throws {
        try await seed(enabled: true)
        launch(arguments: ["-UniPadReleaseSlowDownload", "YES", "-UniPadReleaseInterruptDownload", "YES"])
        try download("Downloaded Fixture", expecting: "Downloaded")
        try await waitForCount("saved", 101)
    }

    @MainActor
    func testTerminationBeforeSavingDoesNotAddOne() async throws {
        try await seed(enabled: true)
        // Keep the transfer running long enough to stop it before publication.
        launch(arguments: ["-UniPadReleaseSlowDownload", "YES", "-UniPadReleaseSlowDownloadMB", "24"])
        let row = try startDownload("Downloaded Fixture")
        let progress = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "%", "MB")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 15))
        XCTAssertFalse(row.staticTexts["Downloaded"].exists)
        UITestSupport.attachScreenshot("accounting-terminated-during-transfer", to: self)
        app.terminate()
        try await Task.sleep(for: .seconds(6))
        let beforeRelaunch = try await count("saved")
        XCTAssertEqual(beforeRelaunch, 100)
        // Reuse the same launch arguments and library, without starting a new download.
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        try await Task.sleep(for: .seconds(6))
        let afterRelaunch = try await count("saved")
        XCTAssertEqual(afterRelaunch, 100)
        UITestSupport.attachScreenshot("accounting-relaunched-without-completion", to: self)
    }

    @MainActor
    func testFailedTransferDoesNotAddOne() async throws {
        try await seed(enabled: true)
        launch()
        try download("Missing Fixture", expecting: "Failed")
        // Cover the accounting request's timeout so a late notification cannot hide behind the UI.
        try await Task.sleep(for: .seconds(6))
        let count = try await count("missing")
        XCTAssertEqual(count, 200)
    }

    @MainActor
    func testDisabledAccountingStillSavesThePack() async throws {
        try await seed(enabled: false)
        launch()
        try download("Downloaded Fixture", expecting: "Downloaded")
        let count = try await count("saved")
        XCTAssertEqual(count, 100)
    }

    @MainActor
    private func launch(arguments: [String] = []) {
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = UITestSupport.isolatedLibraryLaunchArguments() + [
            "-UniPadDownloadAccountingEmulator", "YES",
        ] + arguments
        app.launchEnvironment["CFNETWORK_DIAGNOSTICS"] = "3"
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30), "home never appeared")
    }

    @MainActor
    private func download(_ title: String, expecting status: String) throws {
        let row = try startDownload(title)
        XCTAssertTrue(row.staticTexts[status].waitForExistence(timeout: 60), "download never reached \(status)")
        UITestSupport.attachScreenshot("accounting-after-download", to: self)
    }

    @MainActor
    private func startDownload(_ title: String) throws -> XCUIElement {
        let list = UITestSupport.openStore(in: app, testCase: self)
        let row = UITestSupport.storeRows(in: list)
            .containing(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let download = app.buttons["Download"].firstMatch
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: download)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        UITestSupport.attachScreenshot("accounting-before-download", to: self)
        download.tap()
        UITestSupport.dismissSystemAlerts()
        return row
    }

    @MainActor
    private func seed(enabled: Bool) async throws {
        let store: [String: [String: Any]] = [
            "saved": ["code": "release-test", "downloadCount": 100],
            "missing": ["code": "release-test-1", "downloadCount": 200],
        ]
        _ = try await database("store", value: JSONSerialization.data(withJSONObject: store))
        _ = try await database("downloadAccounting", value: JSONSerialization.data(
            withJSONObject: ["config": ["enabled": enabled]]))
    }

    @MainActor
    private func count(_ item: String) async throws -> Int {
        let data = try await database("store/\(item)/downloadCount")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? Int)
    }

    @MainActor
    private func waitForCount(_ item: String, _ expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            let actual = try await count(item)
            if actual == expected { return }
            guard ContinuousClock.now < deadline else {
                XCTFail("saved count \(actual), expected \(expected)")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func database(_ path: String, value: Data? = nil) async throws -> Data {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:9051/\(path).json?ns=demo-unipad"))
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = value == nil ? "GET" : "PUT"
        request.httpBody = value
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return data
    }
}
