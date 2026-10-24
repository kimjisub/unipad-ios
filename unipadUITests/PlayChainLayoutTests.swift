import XCTest

/// Opens packs made for this check in a library of its own: a 4x3 pack with 24 chains, shaped
/// like conformance case INF-002, an 8x8 pack with 6 chains, shaped like the bundled Faded pack,
/// and a tall 8x4 pack (ReleaseTestSupport.makeChainLayoutPacks). The simulator's own packs are
/// neither used nor changed, so copies of Faded or of other conformance cases there cannot make a
/// title ambiguous. A missing or ambiguous pack fails this required regression check.
/// The bundled midifighter theme is selected so the play screen always shows a logo.
final class PlayChainLayoutTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments += UITestSupport.isolatedLibraryLaunchArguments() + ["-UniPadReleaseChainLayout", "YES"]
        app.launchArguments += ["-SelectedTheme", "bundled://midifighter"]
        app.launch()
        UITestSupport.dismissSystemAlerts()
    }

    private func openPack(title: String) {
        let list = app.scrollViews["main.packList"]
        XCTAssertTrue(list.waitForExistence(timeout: 30))
        let titles = list.staticTexts.matching(NSPredicate(format: "label == %@", title))
        for _ in 0..<40 {
            XCTAssertLessThan(titles.count, 2, "fixture title must be unique")
            if titles.count == 1 && UITestSupport.isFullyVisible(titles.firstMatch, in: app, within: list) { break }
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertEqual(titles.count, 1, "the \(title) pack was not prepared")
        titles.firstMatch.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 2) { alert.buttons.firstMatch.tap() }
        XCTAssertTrue(app.otherElements["playPadGrid"].waitForExistence(timeout: 30))
        UITestSupport.assertFullScreenLandscape(app)
    }

    /// Switches Pro Light Mode in the play menu, closes the menu and returns its button.
    private func setProLightMode(_ on: Bool) -> XCUIElement {
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        UITestSupport.setPlayOption("Pro Light Mode", on: on, in: app)
        UITestSupport.closePlayMenu(in: app)
        return menu
    }

    private func safeArea(_ window: CGRect) throws -> CGRect {
        switch "\(Int(window.width))x\(Int(window.height))" {
        case "874x402": return window.insetBy(dx: 62, dy: 0).divided(atDistance: window.height - 20, from: .minYEdge).slice
        case "844x390": return window.insetBy(dx: 47, dy: 0).divided(atDistance: window.height - 21, from: .minYEdge).slice
        // iPad Pro 11-inch (M5) on iOS 27.0, measured in a separate full-screen landscape UIKit app
        // with the status bar hidden and the home indicator set to auto-hide.
        case "1210x834": return window.divided(atDistance: window.height - 20, from: .minYEdge).slice
        default: throw XCTSkip("no independent safe-area reference for \(window)")
        }
    }

    private func assertChains(rows: Int, columns: Int, count: Int, pro: Bool, name: String) throws {
        let grid = app.otherElements["playPadGrid"]
        let menu = setProLightMode(pro)
        let safe = try safeArea(app.windows.firstMatch.frame)
        let bounds = safe.insetBy(dx: -1, dy: -1)
        let chains = (1...count).map { app.buttons["playChain.\($0)"] }
        let visibleChains = pro ? (1...24).map { app.buttons["playChain.\($0)"] } : chains
        let functions = pro ? (1...8).map { app.descendants(matching: .any)["playFunction.\($0)"] } : []
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "playChain.")).count, pro ? 24 : count)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "playFunction.")).count, pro ? 8 : 0)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "playFunction.")).count, 0,
                       "function lights must not be announced as chain buttons")
        // Each frame is read from the app once and compared here: every read is a query to the app,
        // and reading both frames for every pair of controls made this check take minutes.
        let gridFrame = grid.frame
        let menuFrame = menu.frame
        let logo = app.images["playLogo"]
        let logoFrame = logo.exists ? logo.frame : nil
        XCTAssertTrue(bounds.contains(gridFrame), "pads leave the safe area")
        XCTAssertEqual(gridFrame.midX, app.windows.firstMatch.frame.midX, accuracy: 1)
        // Pads are square up to the screen's pixel rounding.
        XCTAssertEqual(gridFrame.width / CGFloat(columns), gridFrame.height / CGFloat(rows),
                       accuracy: 1 / UIScreen.main.scale)
        var frames: [CGRect] = []
        for (index, button) in (visibleChains + functions).enumerated() {
            XCTAssertTrue(button.exists)
            let frame = button.frame
            XCTAssertTrue(bounds.contains(frame), "button \(index) leaves \(safe): \(frame)")
            XCTAssertTrue(button.isHittable)
            XCTAssertFalse(frame.insetBy(dx: 0.5, dy: 0.5).intersects(gridFrame), "chain covers a pad")
            XCTAssertFalse(frame.intersects(menuFrame), "chain covers the menu")
            if let logoFrame { XCTAssertFalse(frame.intersects(logoFrame), "chain covers the logo") }
            for other in frames {
                XCTAssertFalse(frame.insetBy(dx: 0.5, dy: 0.5).intersects(other), "chain touch areas overlap")
            }
            frames.append(frame)
        }
        UITestSupport.attachScreenshot("\(name)-layout", to: self)
        let selectedChains = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND selected == YES", "playChain."))
        for number in 1...count {
            let reference = number == 4 ? min(5, count) : 4
            chains[reference - 1].tap()
            XCTAssertTrue(chains[reference - 1].isSelected)
            chains[number - 1].tap()
            XCTAssertTrue(chains[number - 1].isSelected, "tap \(number) selected another chain")
            XCTAssertEqual(selectedChains.count, 1)
            print("CHAIN \(name) requested=\(number) selected=\(number) frame=\(chains[number - 1].frame)")
            UITestSupport.attachScreenshot("\(name)-chain-\(number)", to: self)
        }
        if pro {
            // Function keys may light up, but must never select a chain.
            for function in functions { function.tap() }
            XCTAssertTrue(chains[count - 1].isSelected)
        }
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5 / CGFloat(columns), dy: 0.5 / CGFloat(rows))).tap()
        XCTAssertTrue(menu.isHittable)
        menu.tap()
        XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 5))
        UITestSupport.attachScreenshot("\(name)-menu", to: self)
        app.buttons["rectangle.portrait.and.arrow.right"].tap()
        XCTAssertTrue(app.scrollViews["main.packList"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testEveryChainOfSmallPackCanBeSelected() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        openPack(title: "Chain Layout 4x3")
        try assertChains(rows: 4, columns: 3, count: 24, pro: false, name: "small-normal")
    }

    @MainActor
    func testEveryChainOfSmallPackInProLightModeCanBeSelected() throws {
        XCUIDevice.shared.orientation = .landscapeRight
        openPack(title: "Chain Layout 4x3")
        try assertChains(rows: 4, columns: 3, count: 24, pro: true, name: "small-pro")
    }

    @MainActor
    func testEightByEightPackChainsCanBeSelected() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        openPack(title: "Chain Layout 8x8")
        try assertChains(rows: 8, columns: 8, count: 6, pro: false, name: "eight-normal")
    }

    @MainActor
    func testEightByEightPackInProLightModeChainsCanBeSelected() throws {
        XCUIDevice.shared.orientation = .landscapeRight
        openPack(title: "Chain Layout 8x8")
        try assertChains(rows: 8, columns: 8, count: 6, pro: true, name: "eight-pro")
    }

    /// An 8x8 pack in normal mode fills the height of a large window and leaves no room for the
    /// logo, so `logoMayBeHidden` lets it go undrawn there; every other shape must show it, which
    /// also proves the theme took effect.
    private func assertLogoLayout(title: String, pro: Bool, name: String, logoMayBeHidden: Bool = false) throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        openPack(title: title)
        let menu = setProLightMode(pro)
        let logo = app.images["playLogo"]
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        let logoShown = logo.waitForExistence(timeout: 5)
        UITestSupport.attachScreenshot(name, to: self)
        guard logoShown else {
            print("LOGO \(name) hidden grid=\(grid.frame) menu=\(menu.frame)")
            XCTAssertTrue(logoMayBeHidden, "the bundled theme must show its logo")
            return
        }
        print("LOGO \(name) logo=\(logo.frame) grid=\(grid.frame) menu=\(menu.frame)")
        // The logo sits at the top, clear of the home indicator, so the window bounds it where no
        // measured safe area is known for this window size.
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(((try? safeArea(window)) ?? window).contains(logo.frame), "logo leaves the screen: \(logo.frame)")
        XCTAssertFalse(logo.frame.intersects(grid.frame), "logo covers the pads")
        XCTAssertFalse(logo.frame.intersects(menu.frame), "logo covers the menu")
        let controls = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "playChain.", "playFunction."))
        XCTAssertGreaterThan(controls.count, 0)
        for control in controls.allElementsBoundByIndex {
            XCTAssertFalse(logo.frame.intersects(control.frame), "logo covers \(control.identifier): \(control.frame)")
        }
    }

    @MainActor func testTallPackLogoInNormalMode() throws {
        try assertLogoLayout(title: "Chain Layout 8x4", pro: false, name: "logo-tall-normal")
    }
    @MainActor func testTallPackLogoInProLightMode() throws {
        try assertLogoLayout(title: "Chain Layout 8x4", pro: true, name: "logo-tall-pro")
    }
    @MainActor func testSquarePackLogoInNormalMode() throws {
        try assertLogoLayout(title: "Chain Layout 8x8", pro: false, name: "logo-square-normal", logoMayBeHidden: true)
    }
    @MainActor func testSquarePackLogoInProLightMode() throws {
        try assertLogoLayout(title: "Chain Layout 8x8", pro: true, name: "logo-square-pro")
    }
    @MainActor func testSmallPackLogoInNormalMode() throws {
        try assertLogoLayout(title: "Chain Layout 4x3", pro: false, name: "logo-small-normal")
    }
    @MainActor func testSmallPackLogoInProLightMode() throws {
        try assertLogoLayout(title: "Chain Layout 4x3", pro: true, name: "logo-small-pro")
    }
}
