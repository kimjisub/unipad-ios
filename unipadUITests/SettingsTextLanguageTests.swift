//
//  SettingsTextLanguageTests.swift
//  unipadUITests
//
//  Every line Settings draws comes from Localizable.strings, including the
//  MIDI status, the push identifier hint and the storage count, which used to
//  be English literals on every device. Each test launches in one language,
//  requires those lines in that language and that no English literal is left,
//  and attaches a shot of both categories.
//

import XCTest

final class SettingsTextLanguageTests: XCTestCase {

    private struct Language {
        let code: String
        let locale: String
        let information: String
        let storage: String
        let notConnected: String
        let tapToCopy: String
        /// `settings_unipack_count` with the number left out, so any count matches.
        let unipackCountFragment: String
    }

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func check(_ language: Language) {
        app = XCUIApplication()
        app.launchArguments += UITestSupport.launchArguments(language: language.code, locale: language.locale)
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30), "[\(language.code)] home never appeared")
        app.buttons["gearshape"].tap()
        XCTAssertTrue(app.buttons[language.information].waitForExistence(timeout: 10),
                      "[\(language.code)] settings never opened")

        XCTAssertTrue(app.staticTexts[language.notConnected].waitForExistence(timeout: 5),
                      "[\(language.code)] MIDI status is not \"\(language.notConnected)\"")
        let tapToCopy = app.staticTexts[language.tapToCopy]
        for _ in 0..<4 where !tapToCopy.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(tapToCopy.exists, "[\(language.code)] push identifier hint is not \"\(language.tapToCopy)\"")
        UITestSupport.attachScreenshot("\(language.code)-settings-info", to: self)
        if language.code != "en" {
            XCTAssertFalse(app.staticTexts["Not connected"].exists, "[\(language.code)] MIDI status is still English")
            XCTAssertFalse(app.staticTexts["Tap to copy"].exists, "[\(language.code)] push identifier hint is still English")
        }

        app.buttons[language.storage].tap()
        let count = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", language.unipackCountFragment)).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10),
                      "[\(language.code)] storage count does not contain \"\(language.unipackCountFragment)\"")
        UITestSupport.attachScreenshot("\(language.code)-settings-storage", to: self)
    }

    @MainActor
    func testEnglish() {
        check(Language(code: "en", locale: "en_US", information: "Information", storage: "Storage",
                       notConnected: "Not connected", tapToCopy: "Tap to copy", unipackCountFragment: " UniPacks"))
    }

    @MainActor
    func testKorean() {
        check(Language(code: "ko", locale: "ko_KR", information: "정보", storage: "저장소",
                       notConnected: "연결 안 됨", tapToCopy: "탭해서 복사", unipackCountFragment: "개의 유니팩"))
    }

    @MainActor
    func testGerman() {
        check(Language(code: "de", locale: "de_DE", information: "Informationen", storage: "Speicher",
                       notConnected: "Nicht verbunden", tapToCopy: "Tippen zum Kopieren", unipackCountFragment: " UniPacks"))
    }
}
