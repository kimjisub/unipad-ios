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

    static func attachScreenshot(_ name: String, to testCase: XCTestCase) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        testCase.add(a)
    }
}
