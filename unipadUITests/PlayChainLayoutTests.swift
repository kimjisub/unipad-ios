import XCTest

/// Install the unchanged 4x3, 24-chain Conformance pack and the bundled 8x8 Faded pack
/// in Documents/UniPack before running. Missing fixtures fail this required regression check.
final class PlayChainLayoutTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments += UITestSupport.englishLaunchArguments()
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
        XCTAssertEqual(titles.count, 1, "install the required fixture first")
        titles.firstMatch.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 2) { alert.buttons.firstMatch.tap() }
        XCTAssertTrue(app.otherElements["playPadGrid"].waitForExistence(timeout: 30))
    }

    private func safeArea(_ window: CGRect) throws -> CGRect {
        switch "\(Int(window.width))x\(Int(window.height))" {
        case "874x402": return window.insetBy(dx: 62, dy: 0).divided(atDistance: window.height - 20, from: .minYEdge).slice
        case "844x390": return window.insetBy(dx: 47, dy: 0).divided(atDistance: window.height - 21, from: .minYEdge).slice
        // iPad Pro 11-inch (M4), measured in a separate fullscreen UIKit window.
        case "1210x834": return window.divided(atDistance: window.height - 25, from: .minYEdge).slice
        default: throw XCTSkip("no independent safe-area reference for \(window)")
        }
    }

    private func assertChains(rows: Int, columns: Int, count: Int, pro: Bool, name: String) throws {
        let grid = app.otherElements["playPadGrid"]
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        UITestSupport.setPlayOption("Pro Light Mode", on: pro, in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        let safe = try safeArea(app.windows.firstMatch.frame)
        let bounds = safe.insetBy(dx: -1, dy: -1)
        let chains = (1...count).map { app.buttons["playChain.\($0)"] }
        let visibleChains = pro ? (1...24).map { app.buttons["playChain.\($0)"] } : chains
        let functions = pro ? (1...8).map { app.buttons["playFunction.\($0)"] } : []
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "playChain.")).count, pro ? 24 : count)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "playFunction.")).count, pro ? 8 : 0)
        XCTAssertTrue(bounds.contains(grid.frame), "pads leave the safe area")
        XCTAssertEqual(grid.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1)
        XCTAssertEqual(grid.frame.width / CGFloat(columns), grid.frame.height / CGFloat(rows), accuracy: 0.01)
        let logo = app.images["playLogo"]
        for (index, button) in (visibleChains + functions).enumerated() {
            XCTAssertTrue(button.exists)
            XCTAssertTrue(bounds.contains(button.frame), "button \(index) leaves \(safe): \(button.frame)")
            XCTAssertTrue(button.isHittable)
            XCTAssertFalse(button.frame.insetBy(dx: 0.5, dy: 0.5).intersects(grid.frame), "chain covers a pad")
            XCTAssertFalse(button.frame.intersects(menu.frame), "chain covers the menu")
            if logo.exists { XCTAssertFalse(button.frame.intersects(logo.frame), "chain covers the logo") }
            for other in (visibleChains + functions).dropFirst(index + 1) {
                XCTAssertFalse(button.frame.insetBy(dx: 0.5, dy: 0.5).intersects(other.frame), "chain touch areas overlap")
            }
        }
        UITestSupport.attachScreenshot("\(name)-layout", to: self)
        for number in 1...count {
            let reference = number == 4 ? min(5, count) : 4
            chains[reference - 1].tap()
            XCTAssertEqual(chains[reference - 1].value as? String, "selected")
            chains[number - 1].tap()
            XCTAssertEqual(chains[number - 1].value as? String, "selected", "tap \(number) selected another chain")
            XCTAssertEqual(chains.filter { ($0.value as? String) == "selected" }.count, 1)
            print("CHAIN \(name) requested=\(number) selected=\(number) frame=\(chains[number - 1].frame)")
            UITestSupport.attachScreenshot("\(name)-chain-\(number)", to: self)
        }
        if pro {
            // Function keys may light up, but must never select a chain.
            for function in functions { function.tap() }
            XCTAssertEqual(chains[count - 1].value as? String, "selected")
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
        openPack(title: "Conformance")
        try assertChains(rows: 4, columns: 3, count: 24, pro: false, name: "small-normal")
    }

    @MainActor
    func testEveryChainOfSmallPackInProLightModeCanBeSelected() throws {
        XCUIDevice.shared.orientation = .landscapeRight
        openPack(title: "Conformance")
        try assertChains(rows: 4, columns: 3, count: 24, pro: true, name: "small-pro")
    }

    @MainActor
    func testEightByEightPackChainsCanBeSelected() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        openPack(title: "Alan Walker - Faded")
        try assertChains(rows: 8, columns: 8, count: 6, pro: false, name: "eight-normal")
    }

    @MainActor
    func testEightByEightPackInProLightModeChainsCanBeSelected() throws {
        XCUIDevice.shared.orientation = .landscapeRight
        openPack(title: "Alan Walker - Faded")
        try assertChains(rows: 8, columns: 8, count: 6, pro: true, name: "eight-pro")
    }
}
