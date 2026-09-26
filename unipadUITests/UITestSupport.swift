//
//  UITestSupport.swift
//  unipadUITests
//

import XCTest

enum UITestSupport {

    /// The app asks for notification permission during launch, so the first thing
    /// on screen is a system alert covering the home screen. That it appears at
    /// all, before the user has seen anything, is a finding recorded separately
    /// rather than papered over.
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

    static func attachScreenshot(_ name: String, to testCase: XCTestCase) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        testCase.add(a)
    }
}
