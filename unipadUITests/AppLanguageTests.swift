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
        /// `settings_info`, `settings_theme` and `unipack_play` in that language's Localizable.strings.
        let information: String
        let theme: String
        let play: String
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

        UITestSupport.revealHomeCard(.import, in: app).tap()
        let cancel = UITestSupport.settledFilePickerCancelButton(in: app, timeout: 20)
        shot(language, "05-import")
        guard let cancel else {
            XCTFail("[\(language.code)] the file picker never settled full screen with its cancel button")
            return
        }
        cancel.tap()
        // Home stays in the tree under the picker, so only a hittable home means the picker closed.
        XCTAssertTrue(UITestSupport.waitUntilHittable(home, timeout: 10),
                      "[\(language.code)] closing the file picker never reached home")

        // Selecting a pack reveals a play button, labelled in the language under
        // test, in the flag at the row's leading edge. Buttons come and go while
        // the picker leaves and home settles, so both taps wait for their target
        // to be hittable instead of reading the button list at a fixed moment.
        let packTitles = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", " - "))
        guard packTitles.count > 0 else {
            throw XCTSkip("no pack in the library, so pack selection and play were not walked")
        }
        let title = packTitles.element(boundBy: 0)
        XCTAssertTrue(UITestSupport.waitUntilHittable(title, timeout: 10), "[\(language.code)] the pack row never settled on screen")
        title.tap()
        let play = app.buttons[language.play].firstMatch
        let playReady = UITestSupport.waitUntilHittable(play, timeout: 10)
        shot(language, "06-pack-selected")
        guard playReady else {
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
        try walk(in: Language(code: "ko", locale: "ko_KR", information: "정보", theme: "테마", play: "재생"))
    }

    @MainActor
    func testSpanish() throws {
        try walk(in: Language(code: "es", locale: "es_ES", information: "Información", theme: "Tema", play: "Reproducir"))
    }

    @MainActor
    func testGerman() throws {
        try walk(in: Language(code: "de", locale: "de_DE", information: "Informationen", theme: "Design", play: "Play"))
    }
}
