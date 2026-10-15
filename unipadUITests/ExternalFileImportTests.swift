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
        let files = app.collectionViews["File View"]
        XCTAssertTrue(files.waitForExistence(timeout: 20))
        let appFolder = app.navigationBars.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "UniPad,")).firstMatch
        let back = app.buttons["DOC.navBarButton.backInHistory"]
        for _ in 0..<12 {
            if appFolder.exists { return }
            guard back.exists && back.isEnabled else { break }
            back.tap()
        }
        for label in ["On My iPhone", "On My iPad", "UniPad"] {
            let item = app.cells
                .matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")).firstMatch
            if item.waitForExistence(timeout: 2), item.isHittable { item.tap() }
        }
    }

    private func pickerItem(named name: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")
        let files = app.collectionViews["File View"]
        var previousFirstVisible: String?
        for _ in 0..<40 {
            let first = files.cells.allElementsBoundByIndex.first {
                $0.frame.midY > app.navigationBars.firstMatch.frame.maxY && $0.frame.midY < files.frame.maxY - 64
            }?.label
            if first == previousFirstVisible { break }
            previousFirstVisible = first
            files.swipeDown()
        }
        for _ in 0..<40 {
            let item = app.cells.matching(predicate).firstMatch
            if item.exists && (item.label == name || item.label.hasPrefix(name + ",")) {
                let center = item.frame.midY
                let top = app.navigationBars.firstMatch.frame.maxY
                let bottom = files.frame.maxY - 64
                // A clipped cell can report hittable while its center is behind a system bar.
                if center > top && center < bottom && item.isHittable { return item }
                if center <= top { files.swipeDown(); continue }
            }
            files.swipeUp()
        }
        return app.cells.matching(predicate).firstMatch
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

    func testBothImportPathsPopulateLibrary() throws {
        try importWithPicker()
        XCTAssertTrue(app.staticTexts["Downloaded Fixture"].firstMatch.waitForExistence(timeout: 10))
        UITestSupport.attachScreenshot("internal-picker-library", to: self)
        try open("Normal")
        ok.tap()
        XCTAssertTrue(app.staticTexts["Downloaded Fixture"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["JIS307 - Normal"].firstMatch.waitForExistence(timeout: 10))
        UITestSupport.attachScreenshot("both-import-paths-library", to: self)
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
