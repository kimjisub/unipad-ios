//
//  UITestSupport.swift
//  unipadUITests
//

import XCTest

enum UITestSupport {

    /// Launch arguments for tests that find controls by their English text
    /// ("Information", "Theme", "Play", option names). The app follows the
    /// simulator's language, so these pin it to English to make the result the
    /// same whatever language the simulator was left in.
    static func englishLaunchArguments(library: String = "standard", token: String = UUID().uuidString,
                                       file: Bool = false) -> [String] {
        launchArguments(language: "en", locale: "en_US", library: library, token: token, file: file)
    }

    static func launchArguments(language: String, locale: String, library: String = "standard",
                                token: String = UUID().uuidString, file: Bool = false) -> [String] {
        var arguments = [
            "-UniPadFirebaseLocalOnly", "YES",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
        ]
        if ProcessInfo.processInfo.environment["UNIPAD_RELEASE_SUITE"] == "1" {
            arguments += ["-UniPadReleaseTest", token, "-UniPadUITestLibrary", library,
                          "-UniPadReleaseEmpty", library == "empty" ? "YES" : "NO",
                          "-UniPadReleaseFile", file ? "YES" : "NO"]
        }
        return arguments
    }

    /// Creates a recent-play record through the same controls the user uses.
    static func playAndReturn(_ title: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(title.waitForExistence(timeout: 30), "the test pack must be prepared")
        title.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        XCTAssertTrue(app.otherElements["playPadGrid"].waitForExistence(timeout: 30))
        app.buttons["line.3.horizontal"].tap()
        let quit = app.buttons["rectangle.portrait.and.arrow.right"]
        XCTAssertTrue(quit.waitForExistence(timeout: 5))
        quit.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        // Close the selected-pack panel so its total and recent packs are visible.
        title.tap()
        XCTAssertTrue(app.staticTexts["main.total.playCount"].waitForExistence(timeout: 5))
    }

    /// Select the archive generated for this launch, through the system file picker.
    /// Browsing avoids relying on Spotlight to have indexed a freshly created file.
    static func selectPreparedArchive(token: String, in app: XCUIApplication) throws {
        _ = try XCTUnwrap(settledFilePickerCancelButton(in: app, timeout: 20))
        func tapRow(_ names: [String]) {
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label IN %@", names)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "missing file picker row: \(names)")
            XCTAssertTrue(waitUntilHittable(row, timeout: 5))
            row.tap()
        }
        let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "둘러보기", "Durchsuchen"])).firstMatch
        if browse.exists { browse.tap() }
        tapRow(["On My iPhone", "나의 iPhone", "Auf meinem iPhone"])
        tapRow(["UniPad", "unipad"])
        let cell = app.cells.containing(.staticText, identifier: "ReleaseFixture-\(token).zip").firstMatch
        let icon = cell.images.firstMatch
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(search.exists && tabs.exists)
        let window = app.windows.firstMatch.frame
        let viewport = CGRect(x: window.minX, y: search.frame.maxY + 4, width: window.width,
                              height: tabs.frame.minY - search.frame.maxY - 8)
        func visible() -> Bool { icon.exists && viewport.contains(icon.frame) && icon.isHittable }
        let deadline = Date().addingTimeInterval(60)
        while !visible() && Date() < deadline {
            // The collection view also extends underneath the search bar and tabs.
            // Drag inside the unobscured viewport, towards its centre, rather than
            // using a fixed fraction of the covered collection view.
            let frame = icon.exists ? icon.frame : CGRect.null
            let moveDown = !frame.isNull && frame.midY < viewport.midY
            let distance = frame.isNull ? viewport.height * 0.65 :
                min(viewport.height * 0.65, max(16, abs(frame.midY - viewport.midY)))
            let x = viewport.minX + viewport.width * 0.8
            let high = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: x, dy: viewport.midY - distance / 2))
            let low = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: x, dy: viewport.midY + distance / 2))
            if moveDown {
                high.press(forDuration: 0.1, thenDragTo: low, withVelocity: .slow, thenHoldForDuration: 0.2)
            } else {
                low.press(forDuration: 0.1, thenDragTo: high, withVelocity: .slow, thenHoldForDuration: 0.2)
            }
        }
        if !visible() {
            attachPickerDiagnostics(in: app, details: "archive \(icon.frame), viewport \(viewport)")
        }
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        XCTAssertTrue(visible(), "the archive icon must be visible before selecting it")
        icon.tap()
    }

    /// Clears system alerts left over the app when a test starts. The app itself
    /// asks for notification permission only when a store download starts, never
    /// at launch, so on a fresh install there is normally nothing to clear here.
    static func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            guard springboard.alerts.firstMatch.waitForExistence(timeout: 1) else { return }
            var tapped = false
            for label in ["허용 안 함", "Don't Allow", "허용", "Allow", "OK", "확인"] {
                let b = springboard.buttons[label]
                if b.exists && b.isHittable {
                    b.tap()
                    tapped = true
                    break
                }
            }
            if !tapped { break }
        }
    }

    /// The back chevron every pushed screen draws for itself (the navigation bar is hidden).
    static func backButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["chevron.left"].firstMatch
    }

    /// Taps the middle of the part of `element` that is on screen, the way a finger would.
    ///
    /// On a screen with no side safe area (iPhone SE in landscape) Settings' back
    /// button starts at x = -4 because its 44pt tap area reaches past the glyph.
    /// On iOS 27 `XCUIElement.tap()` on that button never reaches the app, while
    /// touches anywhere inside it (x = 2 to 46) go back home, so the tap is sent to
    /// a screen point instead.
    static func tapOnScreen(_ element: XCUIElement, in app: XCUIApplication) {
        let visible = element.frame.intersection(app.windows.firstMatch.frame)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: visible.midX, dy: visible.midY))
            .tap()
    }

    static func tapBack(in app: XCUIApplication) {
        tapOnScreen(backButton(in: app), in: app)
    }

    /// Waits until `element` is on screen where a tap would reach it. An element
    /// is listed while a system sheet still covers it or while its screen is
    /// still settling; tapping it then makes XCUITest scroll to it first and the
    /// tap goes nowhere.
    static func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: element)
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
    }

    /// The system file picker's cancel button, once the picker has settled.
    ///
    /// The picker runs in its own process and lays itself out several times as it
    /// opens: as a sheet, as a split view whose sidebar has a cancel button of its
    /// own, and with a phone-width bar, before it fills the screen. Its cancel
    /// button is listed at each of those places in turn, and XCUITest waits only
    /// for the app to go idle, not the picker, so a tap aimed at an earlier layout
    /// lands on empty space once the picker has moved on, and the picker stays
    /// open. The button is returned only once it sits in the full-width bar the
    /// picker ends in and has stopped moving. Its label is in the app's language.
    static func settledFilePickerCancelButton(in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement? {
        let bar = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        let cancel = bar.buttons
            .matching(NSPredicate(format: "label IN %@", ["Cancel", "취소", "Cancelar", "Abbrechen"]))
            .firstMatch
        let screenWidth = app.windows.firstMatch.frame.width
        let didSettle = waitForSettledFrame(timeout: timeout,
            waitForArrival: { cancel.waitForExistence(timeout: $0) },
            frame: {
                guard cancel.exists, bar.frame.width == screenWidth else { return nil }
                return cancel.frame
            })
        guard didSettle else {
            attachPickerDiagnostics(in: app, details:
                "initial window width \(screenWidth), window \(app.windows.firstMatch.frame), " +
                "navigation \(bar.exists ? bar.frame : .null), cancel exists \(cancel.exists)")
            return nil
        }
        return cancel
    }

    /// Requires two consecutive samples of the same final control frame.
    static func waitForSettledFrame(timeout: TimeInterval,
                                    waitForArrival: (TimeInterval) -> Bool,
                                    frame: @escaping () -> CGRect?) -> Bool {
        // Accessibility discovery can finish near its deadline on a hosted runner.
        // Give the two stable-frame samples their own bounded wait after arrival.
        guard waitForArrival(timeout) else { return false }
        var lastFrame = CGRect.null
        let settled = NSPredicate { _, _ in
            guard let current = frame() else {
                lastFrame = .null
                return false
            }
            defer { lastFrame = current }
            return current == lastFrame
        }
        let expectation = XCTNSPredicateExpectation(predicate: settled, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private static func attachPickerDiagnostics(in app: XCUIApplication, details: String) {
        XCTContext.runActivity(named: "File picker did not settle: " + details) { activity in
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)
            let tree = XCTAttachment(string: details + "\n" + app.debugDescription)
            tree.name = "file-picker-state"
            tree.lifetime = .keepAlways
            activity.add(tree)
        }
    }

    /// The home screen's download and import cards. They sit in the middle of an
    /// empty list and after the last pack of a full one, so a long list has to be
    /// scrolled before the card can be tapped. Packs load after home appears, so
    /// this keeps scrolling until the deadline rather than for a fixed count.
    enum HomeCard: String {
        case download = "main.guide.download"
        case `import` = "main.guide.import"
    }

    static func revealHomeCard(_ card: HomeCard, in app: XCUIApplication, timeout: TimeInterval = 60) -> XCUIElement {
        let element = app.buttons[card.rawValue].firstMatch
        let list = app.scrollViews["main.packList"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { break }
            if list.exists {
                list.swipeUp()
            } else {
                _ = element.waitForExistence(timeout: 1)
            }
        }
        return element
    }

    /// Opens the store from the home card and waits until its list has rows.
    static func openStore(in app: XCUIApplication, testCase: XCTestCase) -> XCUIElement {
        let back = backButton(in: app)
        for _ in 0..<3 where !back.exists {
            revealHomeCard(.download, in: app).tap()
            _ = back.waitForExistence(timeout: 5)
        }
        let list = app.scrollViews["store.list"]
        if !list.waitForExistence(timeout: 30) {
            attachScreenshot("store-not-loaded", to: testCase)
            XCTFail(back.exists ? "store list never loaded (no network on the simulator?)" : "download card did not open the store")
        }
        XCTAssertTrue(storeRows(in: list).firstMatch.waitForExistence(timeout: 15), "store list has no rows")
        return list
    }

    static func storeRows(in list: XCUIElement) -> XCUIElementQuery {
        list.descendants(matching: .any).matching(identifier: "store.row")
    }

    /// Sets a play option switch in the open option panel. The row is one combined
    /// accessibility element labelled with the option's name.
    /// The option panel scrolls on a landscape iPhone, so the switch is first brought into view.
    /// Each row carries a long-press gesture over its whole width, so only the toggle at the
    /// trailing edge flips the value.
    static func setPlayOption(_ label: String, on: Bool, in app: XCUIApplication) {
        let row = app.switches[label].firstMatch
        guard row.waitForExistence(timeout: 5) else {
            XCTFail("no \(label) option in the menu")
            return
        }
        let panel = app.scrollViews.firstMatch
        let inView = { panel.frame.contains(row.frame) }
        for _ in 0..<6 where !inView() {
            if row.frame.midY < panel.frame.midY { panel.swipeDown(velocity: .slow) } else { panel.swipeUp(velocity: .slow) }
        }
        guard inView() else {
            XCTFail("\(label) option never scrolled into view")
            return
        }

        let isOn: () -> Bool = { (row.value as? String) == "1" }
        guard isOn() != on else { return }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(isOn(), on, "\(label) option did not switch")
    }

    static func attachScreenshot(_ name: String, to testCase: XCTestCase) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        testCase.add(a)
    }
}
