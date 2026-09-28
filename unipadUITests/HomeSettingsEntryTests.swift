//
//  HomeSettingsEntryTests.swift
//  unipadUITests
//
//  Settings used to be an unlabeled gear at the bottom of the left panel, and it
//  disappeared whenever a pack was selected. It now sits in the home screen's top
//  bar with its name. These tests require, in each shipped language checked here
//  and at the largest text size, that the button says "Settings" in that language,
//  sits near the top, is fully on screen and large enough to tap, and opens
//  Settings — also while a pack is selected. Recent packs in the left panel must
//  not cover the download and import cards.
//

import XCTest

final class HomeSettingsEntryTests: XCTestCase {

    private struct Language {
        let code: String
        let locale: String
        /// `setting` and `settings_info` in that language's Localizable.strings.
        let settings: String
        let information: String
    }

    private static let english = Language(code: "en", locale: "en_US", settings: "Settings", information: "Information")
    private static let korean = Language(code: "ko", locale: "ko_KR", settings: "설정", information: "정보")
    private static let german = Language(code: "de", locale: "de_DE", settings: "Einstellungen", information: "Informationen")

    private static let minimumTouchSize: CGFloat = 44

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private var settingsButton: XCUIElement { app.buttons["gearshape"] }

    private func launch(_ language: Language, largeText: Bool = false) {
        app = XCUIApplication()
        app.launchArguments += UITestSupport.launchArguments(language: language.code, locale: language.locale)
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 30), "[\(language.code)] home never appeared")
    }

    private func assertSettingsEntry(_ language: Language, _ state: String) {
        let window = app.windows.firstMatch.frame
        let frame = settingsButton.frame
        XCTContext.runActivity(named: "[\(language.code)] \(state): settings \(frame) in \(window)") { _ in
            XCTAssertEqual(settingsButton.label, language.settings, "[\(language.code)] \(state): settings is not named")
            XCTAssertTrue(settingsButton.isHittable, "[\(language.code)] \(state): settings is not hittable")
            XCTAssertTrue(window.contains(frame), "[\(language.code)] \(state): settings runs off screen")
            XCTAssertLessThan(frame.midY, window.height / 4, "[\(language.code)] \(state): settings is not at the top")
            XCTAssertGreaterThanOrEqual(frame.height, Self.minimumTouchSize, "[\(language.code)] \(state): settings is too short to tap")
        }
    }

    private func openSettingsAndReturn(_ language: Language) {
        settingsButton.tap()
        XCTAssertTrue(app.buttons[language.information].waitForExistence(timeout: 10),
                      "[\(language.code)] settings never opened")
        UITestSupport.attachScreenshot("\(language.code)-settings", to: self)
        let back = app.buttons["chevron.left"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "[\(language.code)] settings has no back button")
        back.tap()
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), "[\(language.code)] back from settings never reached home")
    }

    /// The download and import cards stay reachable, and recent packs, when any, sit
    /// inside the left panel without overlapping the cards.
    private func assertHomeContentUncovered(_ language: Language) {
        let download = UITestSupport.revealHomeCard(.download, in: app)
        let importCard = UITestSupport.revealHomeCard(.import, in: app)
        XCTAssertTrue(download.isHittable, "[\(language.code)] the download card is covered")
        XCTAssertTrue(importCard.isHittable, "[\(language.code)] the import card is covered")

        let window = app.windows.firstMatch.frame
        for recent in app.buttons.matching(identifier: "main.recentPack").allElementsBoundByIndex {
            XCTAssertTrue(window.contains(recent.frame), "[\(language.code)] a recent pack runs off screen")
            XCTAssertFalse(recent.frame.intersects(download.frame), "[\(language.code)] a recent pack covers the download card")
            XCTAssertFalse(recent.frame.intersects(importCard.frame), "[\(language.code)] a recent pack covers the import card")
            XCTAssertFalse(recent.frame.intersects(settingsButton.frame), "[\(language.code)] a recent pack covers settings")
        }
    }

    private func walk(_ language: Language, largeText: Bool = false) throws {
        launch(language, largeText: largeText)
        UITestSupport.attachScreenshot("\(language.code)\(largeText ? "-large" : "")-home", to: self)
        assertSettingsEntry(language, "home")
        assertHomeContentUncovered(language)
        openSettingsAndReturn(language)

        let packTitles = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", " - "))
        guard packTitles.count > 0 else {
            XCTAssertEqual(app.buttons.matching(identifier: "main.recentPack").count, 0,
                           "[\(language.code)] recent packs shown for an empty library")
            throw XCTSkip("no pack in the library, so the selected-pack state was not walked")
        }
        packTitles.element(boundBy: 0).tap()
        sleep(1)
        UITestSupport.attachScreenshot("\(language.code)\(largeText ? "-large" : "")-pack-selected", to: self)
        assertSettingsEntry(language, "pack selected")
        openSettingsAndReturn(language)
    }

    /// A recent pack selects that pack, the same as tapping it in the list.
    @MainActor
    func testRecentPackShowsItsDetails() throws {
        launch(Self.english)
        let recent = app.buttons["main.recentPack"].firstMatch
        guard recent.waitForExistence(timeout: 5) else {
            throw XCTSkip("no pack has been played on this simulator, so there is no recent pack to tap")
        }
        XCTAssertTrue(recent.isHittable, "the recent pack is not hittable")
        recent.tap()
        XCTAssertTrue(app.buttons["trash"].waitForExistence(timeout: 5), "the pack's details never appeared")
        UITestSupport.attachScreenshot("en-recent-selected", to: self)
        assertSettingsEntry(Self.english, "recent pack selected")
    }

    @MainActor
    func testEnglish() throws {
        try walk(Self.english)
    }

    @MainActor
    func testKorean() throws {
        try walk(Self.korean)
    }

    @MainActor
    func testGerman() throws {
        try walk(Self.german)
    }

    @MainActor
    func testGermanLargeText() throws {
        try walk(Self.german, largeText: true)
    }
}
