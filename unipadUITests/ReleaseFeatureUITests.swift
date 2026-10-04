import XCTest

/// Uses a fresh, silent pack for every test; never needs a pack installed by hand.
final class ReleaseFeatureUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        let token = ProcessInfo.processInfo.environment["UNIPAD_TARGET_FIXTURE_TOKEN"] ?? UUID().uuidString
        app.launchArguments = UITestSupport.englishLaunchArguments() + ["-UniPadReleaseTest", token]
        return app
    }

    private func openPack(_ title: String = "Release Fixture - Tests", in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 20))
        let row = app.staticTexts[title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the suite must prepare its own pack")
        row.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Play"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["playPadGrid"].waitForExistence(timeout: 15))
    }

    private func choose(_ mode: String, in app: XCUIApplication) {
        app.buttons["line.3.horizontal"].tap()
        XCTAssertTrue(app.buttons[mode].firstMatch.waitForExistence(timeout: 5))
        app.buttons[mode].firstMatch.tap()
    }

    @MainActor
    func testEmptyLibraryAndSettingsReturn() {
        let app = makeApp()
        defer { app.terminate() }
        app.launchArguments += ["-UniPadReleaseEmpty", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Play your first UniPack"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Release Fixture - Tests"].exists)
        app.buttons["gearshape"].tap()
        XCTAssertTrue(app.buttons["Information"].waitForExistence(timeout: 5))
        UITestSupport.tapBack(in: app)
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSharedCodeConfirmationInstallsAndOpensPack() {
        let app = makeApp()
        defer { app.terminate() }
        app.launchArguments += ["-UniPadReleaseEmpty", "YES", "-UniPadReleaseURL", "unipad://unipack?code=release-test"]
        app.launch()
        XCTAssertTrue(app.buttons["Accept"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Downloaded Fixture"].exists)
        UITestSupport.attachScreenshot("release-share-confirmation", to: self)
        app.buttons["Accept"].tap()
        XCTAssertTrue(app.staticTexts["Success"].waitForExistence(timeout: 10))
        UITestSupport.attachScreenshot("release-share-success", to: self)
        openPack("Downloaded Fixture", in: app)
    }

    @MainActor
    func testChainButtonsAndAutoplayPauseResumeStop() {
        let app = makeApp()
        defer { app.terminate() }
        app.launch()
        openPack(in: app)
        let secondChain = app.descendants(matching: .any)["play.chain.1"].firstMatch
        XCTAssertTrue(secondChain.waitForExistence(timeout: 5))
        UITestSupport.tapOnScreen(secondChain, in: app)
        XCTAssertEqual(secondChain.value as? String, "selected")
        choose("Autoplay", in: app)
        let transport = app.buttons["play.autoplay.toggle"]
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        XCTAssertEqual(transport.value as? String, "playing")
        transport.tap()
        XCTAssertEqual(transport.value as? String, "paused")
        transport.tap()
        XCTAssertEqual(transport.value as? String, "playing")
        UITestSupport.attachScreenshot("release-autoplay-resumed", to: self)
        choose("Autoplay", in: app)
        XCTAssertFalse(transport.exists, "selecting the active mode stops playback")
    }

    @MainActor
    func testFilePickerImportResultAndPlay() throws {
        let app = makeApp()
        defer { app.terminate() }
        app.launchArguments += ["-UniPadReleaseEmpty", "YES", "-UniPadReleaseFile", "YES"]
        let token = try XCTUnwrap(app.launchArguments.lastIndex(of: "-UniPadReleaseTest").map { app.launchArguments[$0 + 1] })
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 20))
        UITestSupport.revealHomeCard(.import, in: app).tap()
        let cancel = try XCTUnwrap(UITestSupport.settledFilePickerCancelButton(in: app, timeout: 20))
        XCTAssertTrue(cancel.exists)

        func tapRow(_ names: [String]) {
            let predicate = NSPredicate(format: "label IN %@", names)
            let row = app.descendants(matching: .any).matching(predicate).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "missing file picker row: \(names)")
            XCTAssertTrue(UITestSupport.waitUntilHittable(row, timeout: 5), "file picker row must be tappable")
            row.tap()
        }
        let browse = app.buttons["Browse"].firstMatch
        if browse.exists { browse.tap() }
        tapRow(["On My iPhone"])
        tapRow(["UniPad", "unipad"])
        let fileCell = app.cells.containing(.staticText, identifier: "ReleaseFixture-\(token).zip").firstMatch
        let icon = fileCell.images.firstMatch
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), "the file picker must show its folder contents")
        // Browse directly: Spotlight may not have indexed this newly created file.
        let search = app.searchFields.firstMatch
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(search.exists && tabs.exists)
        let window = app.windows.firstMatch.frame
        let viewport = CGRect(x: window.minX, y: search.frame.maxY + 4,
                              width: window.width, height: tabs.frame.minY - search.frame.maxY - 8)
        func iconIsVisible() -> Bool {
            icon.exists && viewport.contains(icon.frame) && icon.isHittable
        }
        // Names can be reported as tappable behind the search bar. Require the full icon
        // inside the actual content area, using short drags so a row cannot be overshot.
        for _ in 0..<25 {
            if iconIsVisible() { break }
            let high = list.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.40))
            let low = list.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.62))
            if icon.exists && icon.frame.minY < viewport.minY {
                high.press(forDuration: 0.1, thenDragTo: low, withVelocity: .slow, thenHoldForDuration: 0.2)
            } else {
                low.press(forDuration: 0.1, thenDragTo: high, withVelocity: .slow, thenHoldForDuration: 0.2)
            }
        }
        XCTAssertTrue(fileCell.waitForExistence(timeout: 5))
        XCTAssertTrue(iconIsVisible(), "the actual file icon must be visible before selecting it")
        UITestSupport.attachScreenshot("release-file-picker-ready", to: self)
        icon.tap()
        XCTAssertTrue(app.buttons["main.importResult.playNow"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["main.importResult.packTitle"].label.contains("Downloaded Fixture"))
        UITestSupport.attachScreenshot("release-file-import-result", to: self)
        app.buttons["main.importResult.playNow"].tap()
        XCTAssertTrue(app.otherElements["playPadGrid"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testDeleteThenReimportStartsWithoutBookmarkOrPlayHistory() {
        let app = makeApp()
        defer { app.terminate() }
        app.launchArguments += ["-UniPadReleaseEmpty", "YES", "-UniPadReleaseURL", "unipad://unipack?code=release-test"]
        app.launch()
        XCTAssertTrue(app.buttons["Accept"].waitForExistence(timeout: 15))
        app.buttons["Accept"].tap()
        openPack("Downloaded Fixture", in: app)
        app.buttons["line.3.horizontal"].tap()
        app.buttons["rectangle.portrait.and.arrow.right"].tap()
        let title = app.scrollViews["main.packList"].staticTexts["Downloaded Fixture"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let plays = app.staticTexts["main.pack.playCount"]
        if !plays.exists { title.tap() }
        XCTAssertTrue(plays.waitForExistence(timeout: 5))
        XCTAssertEqual(plays.label, "1")
        app.buttons["bookmark"].tap()
        XCTAssertTrue(app.buttons["bookmark.fill"].waitForExistence(timeout: 5))
        app.buttons["trash"].tap()
        app.alerts.firstMatch.buttons["Accept"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: title)
        wait(for: [gone], timeout: 10)
        UITestSupport.attachScreenshot("release-deleted-bookmarked-pack", to: self)

        // Same test token preserves the store and library; the share link installs the same pack ID.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Accept"].waitForExistence(timeout: 15))
        app.buttons["Accept"].tap()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 15))
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        if !plays.exists { title.tap() }
        XCTAssertTrue(plays.waitForExistence(timeout: 5))
        XCTAssertEqual(plays.label, "0")
        XCTAssertTrue(app.buttons["bookmark"].exists)
        XCTAssertFalse(app.buttons["bookmark.fill"].exists)
        UITestSupport.attachScreenshot("release-reimport-without-history", to: self)
    }

    @MainActor
    func testPreparedPackOpensAndBackgroundReturnStaysResponsive() throws {
        if ProcessInfo.processInfo.environment["UNIPAD_TARGET_EVIDENCE"] != nil {
            try checkTargetReleaseAppSettingsReturn()
            return
        }
        let app = makeApp()
        defer { app.terminate() }
        app.launchArguments += ["-UniPadReleaseRepeat", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 20))
        let title = app.staticTexts["Release Fixture - Tests"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the suite must prepare its own pack")
        title.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Play"].firstMatch.tap()
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 15))
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625)).tap()
        XCTAssertEqual(grid.value as? String, "1,1", "a voice must still be playing before backgrounding")
        UITestSupport.attachScreenshot("release-play-before-background", to: self)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625)).tap()
        XCTAssertEqual(grid.value as? String, "1,2", "foreground input must request a new sound")
        XCTAssertEqual(grid.value as? String, "1,2", "repeat voice must be active before switching apps")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625)).tap()
        XCTAssertEqual(grid.value as? String, "1,3", "input after Settings must request a new sound")
        UITestSupport.attachScreenshot("release-play-after-settings", to: self)
        app.buttons["line.3.horizontal"].tap()
        XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 5))
        app.buttons["rectangle.portrait.and.arrow.right"].tap()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 10))
        UITestSupport.attachScreenshot("release-home-after-background", to: self)
    }

    /// Drives an independently built, ordinary Release app. The host checks process
    /// continuity at acknowledged checkpoints; no product test identifiers are used.
    @MainActor
    private func checkTargetReleaseAppSettingsReturn() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try XCTUnwrap(environment["UNIPAD_TARGET_EVIDENCE"]))
        let app = XCUIApplication(bundleIdentifier: "kim.jisub.unipad")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["XCTestConfigurationFilePath": "release-target-local-only"]
        defer { app.terminate() }

        @discardableResult
        func checkpoint(_ name: String) throws -> [String: String] {
            try Data().write(to: directory.appendingPathComponent(name + ".ready"), options: .atomic)
            let response = directory.appendingPathComponent(name + ".ack")
            let deadline = Date().addingTimeInterval(30)
            while !FileManager.default.fileExists(atPath: response.path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            let data = try Data(contentsOf: response)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            XCTAssertNil(result["error"], result["error"] ?? "")
            return result
        }
        func capture(_ name: String) throws {
            try app.debugDescription.write(to: directory.appendingPathComponent(name + "-tree.txt"), atomically: true, encoding: .utf8)
            // The host owns native screenshots; do not retain an XCTest screenshot
            // transaction while waiting for simctl to capture the same display.
            try checkpoint("capture-" + name)
        }

        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        try capture("target-home")
        let title = app.staticTexts["Release Fixture - Tests"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Play"].firstMatch.tap()
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "both versions expose the player menu")
        menu.tap()
        UITestSupport.setPlayOption("Trace Log", on: true, in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))

        // Both versions put the menu at the centre of a 56-point trailing
        // strip. Infer the landscape safe area from this common control rather
        // than using the candidate-only grid identifier or one device's pixels.
        let window = app.windows.firstMatch.frame
        let trailing = window.maxX - menu.frame.midX - 28
        let safeWidth = window.width - trailing * 2
        let safeHeight = (menu.frame.midY - window.minY) * 2
        XCTAssertGreaterThan(window.width, window.height)
        XCTAssertGreaterThanOrEqual(trailing, 0)
        XCTAssertGreaterThan(safeWidth, 300)
        XCTAssertGreaterThan(safeHeight, 200)
        let cell = min(safeHeight / 8, (safeWidth - 56) / 10)
        let oldCenter = (safeWidth - 56) / 2
        let newCenter = min(safeWidth / 2, safeWidth - 56 - cell * 5)
        XCTAssertLessThan(abs(oldCenter - newCenter), cell, "the two pad interiors must overlap")
        let commonCenter = (oldCenter + newCenter) / 2
        let geometry: [String: Double] = ["width": window.width, "height": window.height,
                                         "left": window.minX + trailing + min(oldCenter, newCenter) - cell * 4,
                                         "top": menu.frame.midY - cell * 4,
                                         "right": window.minX + trailing + max(oldCenter, newCenter) + cell * 4,
                                         "bottom": menu.frame.midY + cell * 4]
        try JSONSerialization.data(withJSONObject: geometry).write(to: directory.appendingPathComponent("geometry.json"))
        func input(column: CGFloat) {
            app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: window.minX + trailing + commonCenter + cell * (column - 3.5),
                         dy: menu.frame.midY - cell * 3.5)).tap()
            // Let the fixture's transient LED end. The retained trace proves input.
            Thread.sleep(forTimeInterval: 2)
        }
        try capture("before-input")
        input(column: 0)
        try capture("before-settings")
        try checkpoint("before-settings")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        // Ordinary apps may be suspended while Settings owns the foreground.
        // Both are background states; the host independently rejects a changed PID.
        let background = app.wait(for: .runningBackground, timeout: 5)
            || app.wait(for: .runningBackgroundSuspended, timeout: 5)
        let backgroundState = ["appState": app.state.rawValue]
        try JSONSerialization.data(withJSONObject: backgroundState).write(
            to: directory.appendingPathComponent("background-state.json"), options: .atomic)
        XCTAssertTrue(background, "target background state: \(app.state.rawValue)")
        let response = try checkpoint("in-settings")
        if response["restart"] == "true" {
            // Explicit launch reapplies the local-only environment. On this
            // simulator, automatic activation after termination omitted it.
            app.launch()
        } else {
            app.activate()
        }
        try checkpoint("after-return")
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "return must preserve the player")
        XCTAssertFalse(app.buttons["gearshape"].exists, "a relaunched home screen is a failure")
        try capture("after-return")
        // A different mapped pad tests foreground input without retriggering the
        // public version's known finite-repeat stop defect (fixed in PR #51).
        // The instrumented branch still retriggers the repeat pad after each return.
        input(column: 1)
        try capture("after-input")
        try checkpoint("after-input")
        // Exit/stop while repeating is covered by PlaybackStopUITests on the
        // instrumented source; this target comparison ends on the returned player.
    }

}
