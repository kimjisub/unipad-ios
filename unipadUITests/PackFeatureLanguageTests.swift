import XCTest

final class PackFeatureLanguageTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    @MainActor
    private func check(language: String, locale: String, autoplay: String, large: Bool) {
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.isolatedLibraryLaunchArguments(language: language, locale: locale)
        if large {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        defer { app.terminate() }
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        let prefix = "\(language)-\(large ? "accessibility-xxxl" : "default")"

        let home = app.scrollViews["main.packList"]
        let indicator = home.staticTexts["\(autoplay) ●"].firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5), "home must translate the autoplay indicator")
        UITestSupport.attachScreenshot("\(prefix)-home", to: self)

        let store = UITestSupport.openStore(in: app, testCase: self)
        let row = UITestSupport.storeRows(in: store).containing(.staticText, identifier: "Downloaded Fixture").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.staticTexts["\(autoplay) ●"].exists, "store rows must translate the shared indicator")
        UITestSupport.attachScreenshot("\(prefix)-store-list", to: self)

        row.tap()
        let badge = app.staticTexts[autoplay].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "store details must translate the autoplay badge")
        if badge.exists {
            XCTAssertTrue(app.windows.firstMatch.frame.contains(badge.frame), "the badge must remain on screen")
        }
        UITestSupport.attachScreenshot("\(prefix)-store-detail", to: self)
    }

    @MainActor func testEnglish() {
        check(language: "en", locale: "en_US", autoplay: "Autoplay", large: false)
    }

    @MainActor func testKorean() {
        check(language: "ko", locale: "ko_KR", autoplay: "자동재생", large: false)
    }

    @MainActor func testJapanese() {
        check(language: "ja", locale: "ja_JP", autoplay: "\u{81ea}\u{52d5}\u{518d}\u{751f}", large: false)
    }

    @MainActor func testEnglishLargestText() {
        check(language: "en", locale: "en_US", autoplay: "Autoplay", large: true)
    }

    @MainActor func testKoreanLargestText() {
        check(language: "ko", locale: "ko_KR", autoplay: "자동재생", large: true)
    }

    @MainActor func testJapaneseLargestText() {
        check(language: "ja", locale: "ja_JP", autoplay: "\u{81ea}\u{52d5}\u{518d}\u{751f}", large: true)
    }
}
