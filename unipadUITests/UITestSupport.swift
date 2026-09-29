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
    static func englishLaunchArguments() -> [String] {
        launchArguments(language: "en", locale: "en_US")
    }

    static func launchArguments(language: String, locale: String) -> [String] {
        [
            "-UniPadFirebaseLocalOnly", "YES",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
        ]
    }

    /// Clears system alerts left over the app when a test starts. The app itself
    /// asks for notification permission only when a store download starts, never
    /// at launch, so on a fresh install there is normally nothing to clear here.
    static func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            var tapped = false
            for label in ["허용 안 함", "Don't Allow", "허용", "Allow", "OK", "확인"] {
                let b = springboard.buttons[label]
                if b.waitForExistence(timeout: 2) {
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
        var lastFrame = CGRect.null
        let settled = NSPredicate { _, _ in
            guard cancel.exists, bar.frame.width == screenWidth else {
                lastFrame = .null
                return false
            }
            let frame = cancel.frame
            defer { lastFrame = frame }
            return frame == lastFrame
        }
        let expectation = XCTNSPredicateExpectation(predicate: settled, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed ? cancel : nil
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

    static func attachScreenshot(_ name: String, to testCase: XCTestCase) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        testCase.add(a)
    }
}
