//
//  AppLanguageTests.swift
//  unipadUITests
//
//  The app shows the device's language when it has a translation for it. The
//  English strings used to sit at the top of the app bundle, where iOS reads
//  them before any language folder, so a Korean device saw English everywhere.
//  Each test launches in one language, requires Settings to use that language's
//  own words, and walks the main screens with controls found by icon or
//  identifier, attaching a shot of each so wrapping and clipping can be read.
//

import XCTest

final class AppLanguageTests: XCTestCase {

    private struct Language {
        let code: String
        let locale: String
        /// `settings_info` and `settings_theme` in that language's Localizable.strings.
        let information: String
        let theme: String
    }

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private var home: XCUIElement { app.buttons["gearshape"] }
    private var backButton: XCUIElement { UITestSupport.backButton(in: app) }

    private func shot(_ language: Language, _ name: String) {
        UITestSupport.attachScreenshot("\(language.code)-\(name)", to: self)
    }

    private func back(_ language: Language, from screen: String) {
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "[\(language.code)] no back on \(screen)")
        UITestSupport.tapBack(in: app)
        XCTAssertTrue(home.waitForExistence(timeout: 10), "[\(language.code)] back from \(screen) never reached home")
    }

    private func walk(in language: Language) throws {
        app = XCUIApplication()
        app.launchArguments += UITestSupport.launchArguments(language: language.code, locale: language.locale)
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(home.waitForExistence(timeout: 30), "[\(language.code)] home never appeared")
        shot(language, "01-home")

        home.tap()
        let information = app.buttons[language.information]
        XCTAssertTrue(information.waitForExistence(timeout: 10),
                      "[\(language.code)] settings does not say \"\(language.information)\"")
        XCTAssertFalse(app.buttons["Information"].exists, "[\(language.code)] settings is still in English")
        shot(language, "02-settings")
        app.buttons[language.theme].tap()
        XCTAssertTrue(app.staticTexts[language.theme].firstMatch.waitForExistence(timeout: 10),
                      "[\(language.code)] theme never opened")
        shot(language, "03-theme")
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        UITestSupport.tapBack(in: app)
        XCTAssertTrue(information.waitForExistence(timeout: 10), "[\(language.code)] back from theme never reached settings")
        back(language, from: "settings")

        UITestSupport.revealHomeCard(.download, in: app).tap()
        _ = app.staticTexts.element(boundBy: 1).waitForExistence(timeout: 15)
        shot(language, "04-store")
        back(language, from: "store")

        // The file picker is system UI; its cancel button is in the simulator's language.
        UITestSupport.revealHomeCard(.import, in: app).tap()
        let cancel = app.buttons
            .matching(NSPredicate(format: "label IN %@", ["Cancel", "취소", "Cancelar", "Abbrechen"]))
            .firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "[\(language.code)] the file picker never opened")
        shot(language, "05-import")
        cancel.tap()
        XCTAssertTrue(home.waitForExistence(timeout: 10), "[\(language.code)] closing the file picker never reached home")

        // Selecting a pack reveals a play button in the flag at the row's leading
        // edge. Its text is in the language under test, so it is found by where it
        // sits: the button just before the row's title on the same line.
        let packTitles = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", " - "))
        guard packTitles.count > 0 else {
            throw XCTSkip("no pack in the library, so pack selection and play were not walked")
        }
        let title = packTitles.element(boundBy: 0)
        title.tap()
        sleep(1)
        shot(language, "06-pack-selected")
        // The detail panel repeats the title, so every copy of it is tried.
        let titleFrames = packTitles.allElementsBoundByIndex.map(\.frame)
        let play = app.buttons.allElementsBoundByIndex.first { button in
            let f = button.frame
            return titleFrames.contains { row in
                f.maxX <= row.minX && row.minX - f.maxX < 80 && f.minY < row.maxY && f.maxY > row.minY
            }
        }
        guard let play else {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "\(language.code)-06-tree"
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("[\(language.code)] no play button beside the selected pack")
            return
        }
        play.tap()
        XCTAssertTrue(app.otherElements["playPadGrid"].waitForExistence(timeout: 30), "[\(language.code)] the pack never opened")
        sleep(2)
        shot(language, "07-play")
    }

    @MainActor
    func testKorean() throws {
        try walk(in: Language(code: "ko", locale: "ko_KR", information: "정보", theme: "테마"))
    }

    @MainActor
    func testSpanish() throws {
        try walk(in: Language(code: "es", locale: "es_ES", information: "Información", theme: "Tema"))
    }

    @MainActor
    func testGerman() throws {
        try walk(in: Language(code: "de", locale: "de_DE", information: "Informationen", theme: "Design"))
    }
}
