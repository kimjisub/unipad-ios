// Test-only overlay for baseline 5dd4cac. Never copy into the product sources.
import XCTest

final class PlayPadLayoutTests: XCTestCase {
    private var app: XCUIApplication!
    private var fixtureTitle: String { ProcessInfo.processInfo.environment["CONFORMANCE_TITLE"] ?? "Conformance" }
    private var sample: String { ProcessInfo.processInfo.environment["CONFORMANCE_SAMPLE"] ?? "AP-001" }


    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments()
        XCTAssertTrue(app.launchArguments.contains("-UniPadFirebaseLocalOnly"))
        app.launch()
    }

    private func evidence(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-tree"
        tree.lifetime = .keepAlways
        add(tree)
        print("CONFORMANCE \(name) \(Date().timeIntervalSince1970)")
    }

    @MainActor
    private func exactFixtureTitle(in list: XCUIElement) -> XCUIElement? {
        if fixtureTitle.isEmpty { return blankFixtureCard(in: list) }
        let matches = list.staticTexts.matching(NSPredicate(format: "label == %@", fixtureTitle))
        // The guiding actions row is the list's last row, after every pack card.
        let listEnd = list.descendants(matching: .any).matching(identifier: "main.guide.download").firstMatch
        var swipes = 0
        var stalls = 0
        var counts: [Int] = []
        var previousPosition: String?
        // Printed before every exit: with continueAfterFailure off, a failed
        // assertion stops the test and skips `defer`, losing the record.
        func record() {
            print("CONFORMANCE title-search swipes=\(swipes) stalls=\(stalls) counts=\(counts.map(String.init).joined(separator: ","))")
        }
        func fail(_ message: String) -> XCUIElement? {
            record()
            XCTFail(message)
            return nil
        }
        if !waitForPackCards(in: list, listEnd: listEnd) {
            return fail("Pack list shows no pack cards within 30 s")
        }
        while true {
            let count = matches.count
            counts.append(count)
            if count >= 2 {
                return fail("Multiple exact fixture titles in main.packList")
            }
            if swipes >= 40 {
                return fail("Exact fixture title missing: 40-swipe limit")
            }
            if count == 1 && matches.firstMatch.isHittable {
                record()
                // Recheck immediately before returning the element for selection.
                XCTAssertEqual(matches.count, 1, "Stage one unchanged fixture at a time; titles are shared")
                XCTAssertTrue(matches.firstMatch.isHittable, "Exact fixture title not reachable")
                return matches.firstMatch
            }
            if listEnd.isHittable {
                return fail(count == 1
                    ? "Exact fixture title not hittable: end of pack list"
                    : "Exact fixture title missing: end of pack list")
            }
            // A drag that did not move the list is retried; it still counts toward the limit.
            let first = list.staticTexts.element(boundBy: 0)
            let position = first.exists ? "\(first.label)@\(first.frame.minY)" : "none"
            if previousPosition == position {
                stalls += 1
            }
            previousPosition = position
            scrollOneStep(list)
            swipes += 1
        }
    }

    /// While the first load runs the list holds only the guiding actions row, which
    /// would read as the end of the list. Pack cards sit above that row, so a first
    /// label above it (or with the row off screen) means the cards have arrived.
    @MainActor
    private func waitForPackCards(in list: XCUIElement, listEnd: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        repeat {
            let first = list.staticTexts.element(boundBy: 0)
            if first.exists && !(listEnd.exists && first.frame.minY >= listEnd.frame.minY) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    /// Drags a little over half the list height and holds before lifting, so the
    /// list stops where the finger stops: consecutive screens overlap and no card
    /// is flung past unseen. A quick swipe without the hold was lost on iOS 26.3.
    @MainActor
    private func scrollOneStep(_ list: XCUIElement) {
        let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    // Empty Text is omitted from accessibility. A blank-title/producer card
    // has only the two indicator labels. Preparation rejects a second blank title.
    @MainActor
    private func blankFixtureCard(in list: XCUIElement) -> XCUIElement? {
        let listEnd = list.descendants(matching: .any).matching(identifier: "main.guide.download").firstMatch
        XCTAssertTrue(waitForPackCards(in: list, listEnd: listEnd))
        for _ in 0..<40 {
            let labels = list.staticTexts.allElementsBoundByIndex.filter { $0.exists }
            let candidates = labels.filter { indicator in
                guard indicator.label == "LED ●", indicator.isHittable else { return false }
                return !labels.contains { text in
                    !text.label.isEmpty && text.label != "LED ●" && text.label != "AUTOPLAY ●"
                        && abs(text.frame.midY - indicator.frame.midY) < 30
                }
            }
            XCTAssertLessThanOrEqual(candidates.count, 1, "Ambiguous blank fixture card")
            if let card = candidates.first { return card }
            if listEnd.isHittable { break }
            scrollOneStep(list)
        }
        XCTFail("Blank fixture card missing")
        return nil
    }

    @MainActor
    private func acceptPackWarning() {
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 2) {
            evidence("02-warning")
            let accept = alert.buttons.firstMatch
            XCTAssertTrue(accept.exists)
            accept.tap()
        } else {
            print("CONFORMANCE warning absent sample=\(sample)")
        }
    }

    @MainActor
    private func inspectChains(_ grid: XCUIElement) {
        let frame = grid.frame
        let cell = min(frame.width / 3, frame.height / 4)
        let screen = app.windows.firstMatch.frame
        // Chain bars contain eight square buttons centred on the 4x3 grid.
        // Prefer centres, but also inspect the visible part of clipped buttons.
        for chain in 1...24 {
            let point: CGPoint
            if chain <= 8 {
                point = CGPoint(x: frame.maxX + cell / 2,
                                y: frame.midY - cell * 4 + cell * (CGFloat(chain - 1) + 0.5))
            } else if chain <= 16 {
                point = CGPoint(x: frame.midX - cell * 4 + cell * (CGFloat(16 - chain) + 0.5),
                                y: frame.maxY + cell / 2)
            } else {
                point = CGPoint(x: frame.minX - cell / 2,
                                y: frame.midY - cell * 4 + cell * (CGFloat(24 - chain) + 0.5))
            }
            let centreOnScreen = screen.contains(point)
            let visible = CGRect(x: point.x - cell / 2, y: point.y - cell / 2,
                                 width: cell, height: cell).intersection(screen)
            // Floating-point rounding can leave a subpixel sliver at an edge.
            let reachable = !visible.isNull && visible.width >= 1 && visible.height >= 1
            let tapPoint = centreOnScreen ? point : CGPoint(x: visible.midX, y: visible.midY)
            print("CONFORMANCE chain=\(chain) point=\(point) centreOnScreen=\(centreOnScreen) visible=\(visible) reachable=\(reachable) tapPoint=\(tapPoint)")
            if reachable {
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: tapPoint.x, dy: tapPoint.y)).tap()
                evidence("chain-\(chain)")
            }
        }
    }

    @MainActor
    func testSyntheticPackInputAutoplayAndExit() throws {
        let list = app.scrollViews["main.packList"]
        XCTAssertTrue(list.waitForExistence(timeout: 30), "Pack list missing")
        guard let title = exactFixtureTitle(in: list) else { return }
        evidence("01-exact-title")
        title.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5), "Pack selection did not expose Play")
        evidence("02-selected")
        play.tap()
        acceptPackWarning()

        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "Player missing")
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        // The existing trace overlay proves the canvas received the touch.
        menu.tap()
        UITestSupport.setPlayOption("Feedback light", on: true, in: app)
        UITestSupport.setPlayOption("Trace Log", on: true, in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        evidence("03-player-idle")

        // The approved samples have 4 rows x 3 columns, square pads. Match PadGridView's
        // centering calculation instead of assuming the legacy 8 x 8 layout.
        let frame = grid.frame
        let cell = min(frame.width / 3, frame.height / 4)
        let originX = frame.minX + (frame.width - cell * 3) / 2
        let originY = frame.minY + (frame.height - cell * 4) / 2
        let firstPad = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: originX + cell / 2, dy: originY + cell / 2))
        print("CONFORMANCE press-start \(Date().timeIntervalSince1970) grid=\(frame) cell=\(cell)")
        firstPad.press(forDuration: 2)
        print("CONFORMANCE release-end \(Date().timeIntervalSince1970)")
        evidence("04-input-released")
        if sample == "KS-004" || sample == "KL-004" {
            for index in 2...3 {
                firstPad.press(forDuration: 1)
                evidence("04-input-\(index)")
            }
        }
        if sample == "INF-002" { inspectChains(grid) }


        menu.tap()
        let auto = app.buttons["Autoplay"]
        if auto.waitForExistence(timeout: 2) {
            evidence("05-autoplay-option")
            print("CONFORMANCE autoplay-start \(Date().timeIntervalSince1970)")
            auto.tap()
            XCTAssertTrue(grid.exists, "Player disappeared after Autoplay")
            evidence("06-autoplay-returned-player")
            sleep(2)
            evidence("07-autoplay-after-sequence")
            if sample == "AP-001" {
                // A later capture distinguishes completion from a transient or
                // stale screenshot without changing the fixture's timing.
                sleep(8)
                evidence("07-autoplay-after-ten-seconds")
            }
        } else {
            XCTAssertNotEqual(ProcessInfo.processInfo.environment["CONFORMANCE_HAS_AUTOPLAY"], "YES",
                              "Autoplay file exists but menu item is missing")
            evidence("05-no-autoplay-option")
            print("CONFORMANCE autoplay skipped sample=\(sample)")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        }

        menu.tap()
        let quit = app.buttons["Quit"]
        XCTAssertTrue(quit.waitForExistence(timeout: 5), "Quit missing")
        evidence("08-quit-option")
        quit.tap()
        XCTAssertTrue(list.waitForExistence(timeout: 10), "Did not return to pack list")
        XCTAssertFalse(grid.exists, "Player still shown after Quit")
        evidence("09-returned-list")
        app.terminate()
    }
}
