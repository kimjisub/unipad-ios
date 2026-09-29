//
//  MainSearchUITests.swift
//  unipadUITests
//

import XCTest

/// Pack search on the home screen. The host copies the sample pack "Alan Walker - Faded"
/// (producer "Otarygen, 김지섭, K1A2") and two small packs, "Sunflower" by "Post Malone" and
/// "봄날" by "방탄소년단", into the app's Documents/UniPack before the run; without them the test is skipped.
final class MainSearchUITests: XCTestCase {

    private static let faded = "Alan Walker - Faded"
    private static let sunflower = "Sunflower"
    private static let spring = "봄날"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()
    }

    private func row(_ title: String) -> XCUIElement {
        app.scrollViews["main.packList"].staticTexts[title].firstMatch
    }

    private var searchField: XCUIElement {
        app.textFields.firstMatch
    }

    private func search(_ text: String) {
        searchField.tap()
        searchField.typeText(text)
    }

    /// Deletes the query one character at a time, the way a user clears it.
    private func clearSearch() {
        let current = searchField.value as? String ?? ""
        searchField.tap()
        searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }

    private func expectOnly(_ visible: [String], _ step: String) {
        for title in visible {
            XCTAssertTrue(row(title).waitForExistence(timeout: 5), "\(step): '\(title)' is missing")
        }
        for title in [Self.faded, Self.sunflower, Self.spring] where !visible.contains(title) {
            XCTAssertFalse(row(title).exists, "\(step): '\(title)' should be filtered out")
        }
        UITestSupport.attachScreenshot(step, to: self)
    }

    @MainActor
    func testSearchFiltersAndSurvivesPlay() throws {
        guard row(Self.faded).waitForExistence(timeout: 30), row(Self.sunflower).exists, row(Self.spring).exists else {
            throw XCTSkip("the search test packs are not installed in Documents/UniPack")
        }
        UITestSupport.attachScreenshot("01-library", to: self)

        app.buttons["magnifyingglass"].tap()
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "search field never appeared")

        search("faded")
        expectOnly([Self.faded], "02-title-faded")
        clearSearch()

        search("post")
        expectOnly([Self.sunflower], "03-producer-post")
        clearSearch()

        search("봄날")
        expectOnly([Self.spring], "04-korean-title")
        clearSearch()

        search("김지섭")
        expectOnly([Self.faded], "05-korean-producer")
        clearSearch()

        search("zzz")
        XCTAssertTrue(app.staticTexts["No results found"].waitForExistence(timeout: 5), "empty result message missing")
        expectOnly([], "06-no-results")
        clearSearch()
        expectOnly([Self.faded, Self.sunflower, Self.spring], "07-cleared")

        // The keyboard's autocorrect rewrites an English word ("faded" → "fades") once the row is tapped.
        search("김지섭")
        searchField.typeText("\n")
        row(Self.faded).tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5), "Play never appeared for the selected pack")
        play.tap()
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "play screen never opened")
        UITestSupport.attachScreenshot("08-play", to: self)
        menu.tap()
        let quit = app.buttons["rectangle.portrait.and.arrow.right"]
        XCTAssertTrue(quit.waitForExistence(timeout: 5), "option panel never opened")
        quit.tap()

        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 10), "never returned home")
        expectOnly([Self.faded], "09-back-home-search-kept")

        clearSearch()
        expectOnly([Self.faded, Self.sunflower, Self.spring], "10-cleared-after-play")
        // Recent packs sit in the total panel, which shows only while no pack is selected
        // and drops them when the keyboard leaves too little height.
        searchField.typeText("\n")
        if app.buttons["bookmark"].firstMatch.exists {
            row(Self.faded).tap()
        }
        XCTAssertTrue(app.staticTexts["Last Played"].waitForExistence(timeout: 5), "recent packs never showed the play")
        UITestSupport.attachScreenshot("11-recent", to: self)
    }
}
