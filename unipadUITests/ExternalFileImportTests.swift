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

    private func browsePickerToDocuments() {
        let back = app.buttons["DOC.navBarButton.backInHistory"]
        for _ in 0..<8 {
            guard back.exists && back.isEnabled else { break }
            back.tap()
        }
        for label in ["Browse", "On My iPhone", "On My iPad", "UniPad"] {
            let item = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")).firstMatch
            if item.waitForExistence(timeout: 2), item.isHittable { item.tap() }
        }
    }

    private func pickerItem(named name: String) -> XCUIElement {
        let item = app.cells.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
        let files = app.collectionViews["File View"]
        for _ in 0..<40 {
            if item.exists && item.isHittable { return item }
            files.swipeUp()
        }
        return item
    }

    private func importWithPicker(dismissResult: Bool = true) throws {
        UITestSupport.revealHomeCard(.import, in: app).tap()
        let fixtureName = "ReleaseFixture-\(token!)"
        browsePickerToDocuments()
        let file = pickerItem(named: fixtureName + ".zip")
        XCTAssertTrue(file.waitForExistence(timeout: 20), "generated picker fixture is missing")
        file.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        XCTAssertEqual(title.label, "Pack imported!")
        XCTAssertEqual(app.staticTexts["main.importResult.packTitle"].label, "Downloaded Fixture")
        UITestSupport.attachScreenshot("internal-picker-result", to: self)
        if dismissResult {
            ok.tap()
            XCTAssertFalse(title.exists)
        }
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
    func testPickerImportCanBePlayed() throws {
        try importWithPicker(dismissResult: false)
        XCTAssertTrue(play.isHittable)
        play.tap()
        XCTAssertTrue(app.descendants(matching: .any)["playPadGrid"].waitForExistence(timeout: 30))
        XCTAssertFalse(title.exists)
        let grid = app.descendants(matching: .any)["playPadGrid"]
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625)).tap()
        XCTAssertEqual(app.state, .runningForeground)
        UITestSupport.attachScreenshot("internal-picker-play-now", to: self)
    }

    func testImportedFoldersKeepArchiveNames() throws {
        try importWithPicker()
        XCTAssertTrue(app.staticTexts["Downloaded Fixture"].firstMatch.waitForExistence(timeout: 10))
        UITestSupport.attachScreenshot("internal-picker-library", to: self)
        try open("Normal")
        ok.tap()

        UITestSupport.revealHomeCard(.import, in: app).tap()
        func folder(_ name: String) -> XCUIElement {
            app.cells.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
        }
        // The token names this test's private library, under Documents/ReleaseTests.
        browsePickerToDocuments()
        for name in ["ReleaseTests", token!, "UniPack"] {
            let item = pickerItem(named: name)
            XCTAssertTrue(item.waitForExistence(timeout: 20), "imported library folder is missing: \(name)")
            item.tap()
        }
        let pickedFolderExists = folder("ReleaseFixture-\(token!)").waitForExistence(timeout: 10)
        let externalFolderExists = folder("Normal").waitForExistence(timeout: 10)
        UITestSupport.attachScreenshot("imported-folder-names", to: self)
        XCTAssertTrue(pickedFolderExists, "the picked pack lost its archive name")
        XCTAssertTrue(externalFolderExists, "the externally opened pack lost its archive name")
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
        XCTAssertEqual(app.staticTexts["main.importResult.packTitle"].label, "JIS307 - Normal")
        ok.tap()
        try open("Missing"); assertMissing()
        ok.tap()
        try open("Broken"); assertBroken()
        try open("Normal"); assertNormal()
    }
}
