import XCTest

/// Exercises iOS document opening, without substituting a notification or calling
/// the router directly. Fixtures are the three ZIPs in ExternalImportFixtures.
@MainActor
final class ExternalFileImportTests: XCTestCase {
    private var app: XCUIApplication!
    private var token: String!
    private var title: XCUIElement { app.staticTexts["main.importResult.title"] }
    private var ok: XCUIElement { app.buttons["main.importResult.ok"] }
    private var play: XCUIElement { app.buttons["main.importResult.playNow"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        token = UUID().uuidString
        app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments(library: "empty", token: token, file: true,
                                                                   isolated: true)
        app.launchEnvironment["XCTestConfigurationFilePath"] = "external-import-local-only"
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        XCTAssertTrue(UITestSupport.waitUntilHittable(app.buttons["gearshape"], timeout: 20))
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning {
            UITestSupport.attachScreenshot("external-import-final", to: self)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "external-import-final-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app?.terminate()
    }

    private func open(_ name: String) throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "zip"))
        app.open(url)
        XCTAssertTrue(title.waitForExistence(timeout: 30), "external \(name) import produced no result")
        UITestSupport.attachScreenshot("external-\(name)-result", to: self)
    }

    private func importWithPicker() throws {
        UITestSupport.revealHomeCard(.import, in: app).tap()
        // Every launch generates this same silent picker fixture in its isolated import folder.
        // The imported title below validates its content.
        try UITestSupport.selectPreparedArchive(token: token, in: app)

        XCTAssertTrue(title.waitForExistence(timeout: 30))
        XCTAssertEqual(title.label, "Pack imported!")
        XCTAssertEqual(app.staticTexts["main.importResult.packTitle"].label, "Downloaded Fixture")
        UITestSupport.attachScreenshot("internal-picker-result", to: self)
        ok.tap()
        XCTAssertFalse(title.exists)
    }

    private func assertNormal() {
        XCTAssertEqual(title.label, "Pack imported!")
        XCTAssertEqual(app.staticTexts["main.importResult.packTitle"].label, "External Import - Normal")
        XCTAssertTrue(play.isHittable)
        play.tap()
        XCTAssertTrue(app.descendants(matching: .any)["playPadGrid"].waitForExistence(timeout: 30))
        XCTAssertFalse(title.exists)
        UITestSupport.attachScreenshot("external-normal-play-now", to: self)
    }

    private func assertMissing() {
        XCTAssertEqual(title.label, "Warning")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "missing.wav")).firstMatch.exists)
        XCTAssertFalse(play.exists)
        XCTAssertTrue(ok.isHittable)
    }

    private func assertBroken() {
        XCTAssertEqual(title.label, "Import failed")
        XCTAssertFalse(play.exists)
        XCTAssertTrue(ok.isHittable)
        ok.tap()
        XCTAssertTrue(app.buttons["gearshape"].exists)
    }

    func testNormalFromEmptyLibrary() throws { try open("Normal"); assertNormal() }

    func testWindowsPathsWithDotsImportAndOpenForPlay() throws {
        try open("WindowsPaths")
        XCTAssertEqual(title.label, "Pack imported!")
        XCTAssertEqual(app.staticTexts["main.importResult.packTitle"].label, "Archive Paths")
        XCTAssertTrue(play.isHittable)
        play.tap()
        let grid = app.descendants(matching: .any)["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30))
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.125, dy: 0.125)).tap()
        UITestSupport.attachScreenshot("windows-paths-ready-to-play", to: self)
    }

    func testAnEmptyWebsiteDoesNotShowAButton() throws {
        try open("EmptyWebsite")
        XCTAssertEqual(title.label, "Pack imported!")
        ok.tap()
        let list = app.scrollViews["main.packList"]
        XCTAssertTrue(list.waitForExistence(timeout: 30))
        let pack = list.staticTexts["Empty Website"].firstMatch
        XCTAssertTrue(pack.waitForExistence(timeout: 15))
        pack.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["main.pack.website"].exists)
        UITestSupport.attachScreenshot("empty-website-pack-panel", to: self)
    }

    func testAWebsiteWithoutASchemeOpensItsHTTPSAddress() throws {
        try open("SchemeLessWebsite")
        XCTAssertEqual(title.label, "Pack imported!")
        ok.tap()
        let list = app.scrollViews["main.packList"]
        XCTAssertTrue(list.waitForExistence(timeout: 30))
        let pack = list.staticTexts["Website Address"].firstMatch
        XCTAssertTrue(pack.waitForExistence(timeout: 15))
        pack.tap()
        let website = app.buttons["main.pack.website"]
        XCTAssertTrue(website.waitForExistence(timeout: 15))
        website.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20))
        defer { safari.terminate(); app.activate() }
        // .invalid needs no live website. This checks the browser destination, not page loading.
        let address = safari.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS[c] 'example.invalid' OR label CONTAINS[c] 'example.invalid'"))
            .firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        let capture = XCTAttachment(screenshot: safari.screenshot())
        capture.name = "scheme-less-website-browser-destination"
        capture.lifetime = .keepAlways
        add(capture)
    }

    /// The pack folder sits next to a readme.txt at the top of the archive.
    func testPackFolderBesideAReadmeImports() throws {
        try open("BesideReadme")
        XCTAssertEqual(title.label, "Pack imported!")
        XCTAssertEqual(app.staticTexts["main.importResult.packTitle"].label, "External Import - Beside Readme")
        XCTAssertTrue(play.isHittable)
    }
    func testMissingFromEmptyLibrary() throws { try open("Missing"); assertMissing() }
    func testBrokenFromEmptyLibrary() throws { try open("Broken"); assertBroken() }
    func testNormalAfterPickerResult() throws { try importWithPicker(); try open("Normal"); assertNormal() }
    func testMissingAfterPickerResult() throws { try importWithPicker(); try open("Missing"); assertMissing() }
    func testBrokenAfterPickerResult() throws { try importWithPicker(); try open("Broken"); assertBroken() }

    func testNormalWhenExternalOpenLaunchesTheApp() throws {
        app.terminate()
        try open("Normal")
        assertNormal()
    }

    func testConsecutiveExternalImportsReplaceTheResult() throws {
        try open("Normal")
        XCTAssertEqual(app.staticTexts["main.importResult.packTitle"].label, "External Import - Normal")
        ok.tap()
        try open("Missing"); assertMissing()
        ok.tap()
        try open("Broken"); assertBroken()
        try open("Normal"); assertNormal()
    }
}
