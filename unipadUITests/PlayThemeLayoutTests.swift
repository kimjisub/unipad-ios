import XCTest

/// A theme's `playbg` is drawn around the pad grid: themes such as `sskin` and `midifighter`
/// paint a device body in the middle of the image, and the pads must land on that body
/// (unipad-ios#37) while keeping their size and staying out of the home indicator area.
final class PlayThemeLayoutTests: XCTestCase {

    /// A theme given here is pinned in the argument domain, which also hides what the Theme
    /// screen saves, so the walk through the Theme screen launches without one.
    private func launch(theme: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments()
        if let theme { app.launchArguments += ["-SelectedTheme", theme] }
        app.launch()
        UITestSupport.dismissSystemAlerts()
        return app
    }

    /// Opens the sample pack Faded, or the first pack when the library has no Faded, and returns
    /// the title it opened.
    @discardableResult
    private func openFirstPack(in app: XCUIApplication) throws -> String {
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30), "never reached home")
        let packTitles = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", " - "))
        guard packTitles.count > 0 else { throw XCTSkip("no pack in the library") }
        let faded = packTitles.matching(NSPredicate(format: "label CONTAINS[c] %@", "Faded")).firstMatch
        let title = faded.exists ? faded : packTitles.element(boundBy: 0)
        let name = title.label
        title.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() } else { title.tap() }
        return name
    }

    /// Landscape safe-area insets measured on each simulator, taken independently of the app so a
    /// layout that ignores the safe area cannot pass by reporting it as zero.
    private static let landscapeSafeAreas: [String: (side: CGFloat, bottom: CGFloat)] = [
        "844x390": (47, 21),   // iPhone 16e
        "874x402": (62, 20),   // iPhone 17 Pro
    ]

    private func safeArea(of window: CGRect) throws -> CGRect {
        let key = "\(Int(window.width))x\(Int(window.height))"
        guard let insets = Self.landscapeSafeAreas[key] else {
            throw XCTSkip("no reference safe area for a \(key) screen")
        }
        return CGRect(x: window.minX + insets.side, y: window.minY,
                      width: window.width - insets.side * 2, height: window.height - insets.bottom)
    }

    /// Pro Light Mode adds a chain row above and below the grid, as packs with more than 8
    /// chains do, so the rows are checked against the safe area too.
    private func assertGridSitsOnBackground(theme: String, orientation: UIDeviceOrientation, chainRows: Bool) throws {
        XCUIDevice.shared.orientation = orientation
        let app = launch(theme: theme)
        try openFirstPack(in: app)
        let label = "[\(theme) \(orientation == .landscapeLeft ? "left" : "right")\(chainRows ? " chain rows" : "")]"

        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "\(label) pad grid never appeared")
        let background = app.images["playBackground"]
        XCTAssertTrue(background.waitForExistence(timeout: 5), "\(label) theme background never appeared")
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "\(label) menu button never appeared")
        if chainRows {
            menu.tap()
            XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 5), "\(label) option panel never opened")
            UITestSupport.setPlayOption("Pro Light Mode", on: true, in: app)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
            XCTAssertTrue(menu.waitForExistence(timeout: 5), "\(label) option panel never closed")
        }
        sleep(1)
        UITestSupport.attachScreenshot("play-\(label)", to: self)

        let window = app.windows.firstMatch.frame
        let logo = app.images["playLogo"]
        let logoFrame = logo.exists ? "\(logo.frame)" : "none"
        XCTContext.runActivity(named: "\(label) window \(window) background \(background.frame) grid \(grid.frame) menu \(menu.frame) logo \(logoFrame)") { _ in }

        XCTAssertTrue(background.frame.insetBy(dx: -1, dy: -1).contains(window), "\(label) theme image \(background.frame) leaves part of the screen bare")
        XCTAssertLessThanOrEqual(background.frame.height, window.height * 1.1, "\(label) theme image is blown up past the screen \(background.frame)")
        XCTAssertEqual(grid.frame.midX, background.frame.midX, accuracy: 1, "\(label) pad grid is beside the theme's body")
        XCTAssertEqual(grid.frame.midY, background.frame.midY, accuracy: 1, "\(label) pad grid is above or below the theme's body")

        let safe = try safeArea(of: window)
        let rowCount: CGFloat = chainRows ? 10 : 8
        let cell = grid.frame.width / 8
        let padsTop = grid.frame.minY - (chainRows ? cell : 0)
        let padsBottom = grid.frame.maxY + (chainRows ? cell : 0)
        XCTAssertEqual(cell * rowCount, safe.height, accuracy: 1.5, "\(label) pads are not sized to the safe area's height \(grid.frame)")
        XCTAssertGreaterThanOrEqual(padsTop, safe.minY - 1, "\(label) pads run past the top of the safe area \(grid.frame)")
        XCTAssertLessThanOrEqual(padsBottom, safe.maxY + 1, "\(label) pads reach into the home indicator area below \(safe.maxY): bottom \(padsBottom)")
        XCTAssertGreaterThanOrEqual(grid.frame.minX - cell, safe.minX - 1, "\(label) left chain column runs past the leading safe area \(grid.frame)")
        XCTAssertTrue(safe.contains(menu.frame), "\(label) menu button \(menu.frame) is outside the safe area \(safe)")
        if logo.exists {
            XCTAssertTrue(safe.contains(logo.frame), "\(label) logo \(logo.frame) is outside the safe area \(safe)")
        }
        app.terminate()
    }

    /// Opens the first pack and compares every theme image seen on screen while it loads with the
    /// one the pads first appear on: the theme must not grow or move when play starts.
    private func assertThemeHoldsStillWhileOpening(theme: String, orientation: UIDeviceOrientation) throws {
        XCUIDevice.shared.orientation = orientation
        let app = launch(theme: theme)
        let label = "[\(theme) \(orientation == .landscapeLeft ? "left" : "right") opening]"
        // `playBackdrop` is the separate loading fill the play screen used to draw, so this check
        // also catches it coming back.
        let themeImage = app.images.matching(NSPredicate(format: "identifier IN %@", ["playBackdrop", "playBackground"])).firstMatch
        let grid = app.otherElements["playPadGrid"]
        let pack = try openFirstPack(in: app)

        var loadingFrames: [CGRect] = []
        let deadline = Date().addingTimeInterval(60)
        while !grid.exists, Date() < deadline {
            if themeImage.exists { loadingFrames.append(themeImage.frame) }
        }
        XCTAssertTrue(grid.waitForExistence(timeout: 5), "\(label) pad grid never appeared")
        let playing = app.images["playBackground"]
        XCTAssertTrue(playing.waitForExistence(timeout: 5), "\(label) theme background never appeared")
        let playFrame = playing.frame
        let seen = Set(loadingFrames.map { "\($0)" }).sorted().joined(separator: " ")
        XCTContext.runActivity(named: "\(label) pack \(pack) window \(app.windows.firstMatch.frame) loading \(loadingFrames.count) samples \(seen) play \(playFrame)") { _ in }

        XCTAssertFalse(loadingFrames.isEmpty, "\(label) the theme was never seen while the pack loaded")
        for frame in loadingFrames where !Self.sameFrame(frame, playFrame) {
            XCTFail("\(label) theme moves or changes size when play starts: \(frame) while loading → \(playFrame)")
            break
        }
        app.terminate()
    }

    private static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5 && abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
    }

    @MainActor
    func testSskinHoldsStillWhilePackOpens() throws {
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            try assertThemeHoldsStillWhileOpening(theme: "bundled://sskin", orientation: orientation)
        }
    }

    @MainActor
    func testMidifighterHoldsStillWhilePackOpens() throws {
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            try assertThemeHoldsStillWhileOpening(theme: "bundled://midifighter", orientation: orientation)
        }
    }

    @MainActor
    func testThemePickedOnThemeScreenLaysOutPlay() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30), "never reached home")
        app.buttons["gearshape"].tap()
        XCTAssertTrue(app.buttons["Theme"].waitForExistence(timeout: 10), "settings never opened")
        app.buttons["Theme"].tap()
        let row = app.staticTexts["UniPad S Skin"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "sskin is not in the theme list")
        row.tap()
        let apply = app.buttons["Apply"].firstMatch
        if apply.waitForExistence(timeout: 5) { apply.tap() }
        UITestSupport.attachScreenshot("walk-1-theme-applied", to: self)
        for _ in 0..<2 where !app.buttons["gearshape"].exists {
            app.buttons["chevron.left"].firstMatch.tap()
            _ = app.buttons["gearshape"].waitForExistence(timeout: 5)
        }

        try openFirstPack(in: app)
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "pad grid never appeared")
        let background = app.images["playBackground"]
        XCTAssertTrue(background.waitForExistence(timeout: 5), "theme background never appeared")
        sleep(1)
        UITestSupport.attachScreenshot("walk-2-play", to: self)
        XCTAssertEqual(grid.frame.midX, background.frame.midX, accuracy: 1, "pad grid is beside the theme's body")
        XCTAssertEqual(grid.frame.midY, background.frame.midY, accuracy: 1, "pad grid is above or below the theme's body")

        for (row, col) in [(0, 0), (3, 4), (7, 7)] {
            grid.coordinate(withNormalizedOffset: CGVector(dx: (CGFloat(col) + 0.5) / 8, dy: (CGFloat(row) + 0.5) / 8)).tap()
        }
        let cell = grid.frame.width / 8
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: grid.frame.maxX + cell / 2, dy: grid.frame.minY + cell * 1.5)).tap()
        sleep(1)
        UITestSupport.attachScreenshot("walk-3-pads-chain-2", to: self)

        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(menu.isHittable, "menu button is covered")
        menu.tap()
        let quit = app.buttons["rectangle.portrait.and.arrow.right"]
        XCTAssertTrue(quit.waitForExistence(timeout: 5), "option panel never opened")
        UITestSupport.attachScreenshot("walk-4-menu", to: self)
        quit.tap()
        // Home comes back with the pack's detail panel still open over the settings button.
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 10), "quitting play did not return home")
        XCTAssertFalse(grid.exists, "the play screen is still up after quitting")
        UITestSupport.attachScreenshot("walk-5-home", to: self)
    }

    @MainActor
    func testGridSitsOnSskinBackground() throws {
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            for chainRows in [false, true] {
                try assertGridSitsOnBackground(theme: "bundled://sskin", orientation: orientation, chainRows: chainRows)
            }
        }
    }

    @MainActor
    func testGridSitsOnMidifighterBackground() throws {
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            for chainRows in [false, true] {
                try assertGridSitsOnBackground(theme: "bundled://midifighter", orientation: orientation, chainRows: chainRows)
            }
        }
    }
}
