import XCTest

/// JIS-313: exercise iOS document opening, without substituting a notification or
/// calling the router directly. Fixtures are the three ZIPs used by JIS-307 QA.
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
        app.launchArguments = [
            "-UniPadFirebaseLocalOnly", "YES",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UniPadReleaseTest", token, "-UniPadReleaseEmpty", "YES",
            "-UniPadReleaseFile", "YES",
        ]
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
        let file = app.cells
            .matching(NSPredicate(format: "label BEGINSWITH %@", "ReleaseFixture-")).firstMatch
        if !file.waitForExistence(timeout: 3) {
            for label in ["Browse", "On My iPhone", "UniPad"] {
                let item = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")).firstMatch
                if item.waitForExistence(timeout: 2), item.isHittable { item.tap() }
            }
        }
        // Every launch generates this same silent picker fixture. Its UUID is
        // for filename isolation; the imported title below validates its content.
        XCTAssertTrue(file.waitForExistence(timeout: 10), "generated picker fixture is missing")
        file.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        XCTAssertEqual(title.label, "Pack imported!")
        XCTAssertEqual(app.staticTexts["main.importResult.packTitle"].label, "Downloaded Fixture")
        UITestSupport.attachScreenshot("internal-picker-result", to: self)
        ok.tap()
        XCTAssertFalse(title.exists)
    }

    private func assertNormal() {
        XCTAssertEqual(title.label, "Pack imported!")
        XCTAssertEqual(app.staticTexts["main.importResult.packTitle"].label, "JIS307 - Normal")
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
        XCTAssertEqual(app.staticTexts["main.importResult.packTitle"].label, "JIS307 - Normal")
        ok.tap()
        try open("Missing"); assertMissing()
        ok.tap()
        try open("Broken"); assertBroken()
        try open("Normal"); assertNormal()
    }
}
