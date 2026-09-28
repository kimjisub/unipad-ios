//
//  FirstPackGuideTests.swift
//  unipadUITests
//
//  Walks a fresh install from the empty-library guide to a playing pack:
//  the guide in English, Korean, Spanish and German, its link opening the
//  browser, importing Faded.zip through the file picker, the guide going away,
//  and the Play label in each language.
//
//  The file picker can only show files the simulator has, so copy the pack into
//  the simulator's On My iPhone folder first; the import step skips otherwise.
//  That folder is the `File Provider Storage` inside the app group whose
//  metadata names `group.com.apple.FileProvider.LocalStorage`, under
//  ~/Library/Developer/CoreSimulator/Devices/<udid>/data/Containers/Shared/AppGroup/.
//  Uninstall the app first so the library starts empty.
//

import XCTest

final class FirstPackGuideTests: XCTestCase {

    private struct Language {
        let code: String
        let locale: String
        let title: String
        let noLaunchpad: String
        let link: String
        let play: String
    }

    private static let english = Language(
        code: "en", locale: "en_US", title: "Play your first UniPack",
        noLaunchpad: "No Launchpad? Just tap the pads on screen.", link: "Getting started guide", play: "Play")
    private static let korean = Language(
        code: "ko", locale: "ko_KR", title: "첫 유니팩을 연주해 보세요",
        noLaunchpad: "런치패드가 없어도 화면의 패드를 눌러 연주할 수 있어요.", link: "시작 안내 보기", play: "재생")
    private static let spanish = Language(
        code: "es", locale: "es_ES", title: "Toca tu primer UniPack",
        noLaunchpad: "¿No tienes Launchpad? Toca los pads en la pantalla.", link: "Guía de inicio", play: "Reproducir")
    /// German has no translation for these strings, so it shows the English text.
    private static let german = Language(
        code: "de", locale: "de_DE", title: english.title,
        noLaunchpad: english.noLaunchpad, link: english.link, play: english.play)
    private static let all = [english, korean, spanish, german]

    private static let packFile = "Faded"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private var home: XCUIElement { app.buttons["gearshape"] }
    private var guideLink: XCUIElement { app.buttons["main.guide.getStarted"] }
    private var packTitles: XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", " - "))
    }

    private func launch(_ language: Language) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments += UITestSupport.launchArguments(language: language.code, locale: language.locale)
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(home.waitForExistence(timeout: 30), "[\(language.code)] home never appeared")
    }

    private func shot(_ language: Language, _ name: String) {
        UITestSupport.attachScreenshot("\(language.code)-\(name)", to: self)
    }

    private func text(_ label: String) -> XCUIElement {
        app.staticTexts[label].firstMatch
    }

    private func assertGuide(_ language: Language) {
        XCTAssertTrue(text(language.title).waitForExistence(timeout: 10), "[\(language.code)] no guide title")
        XCTAssertTrue(text(language.noLaunchpad).exists, "[\(language.code)] no on-screen pads line")
        XCTAssertTrue(guideLink.exists, "[\(language.code)] no guide link")
        XCTAssertTrue(guideLink.label.contains(language.link), "[\(language.code)] link reads \"\(guideLink.label)\"")
        XCTAssertTrue(app.buttons[UITestSupport.HomeCard.download.rawValue].exists, "[\(language.code)] download card is gone")
        XCTAssertTrue(app.buttons[UITestSupport.HomeCard.import.rawValue].exists, "[\(language.code)] import card is gone")
        XCTAssertFalse(app.staticTexts["main_empty_title"].exists, "[\(language.code)] shows the raw key")
    }

    /// Selects the first pack and returns the Play control that appears beside it.
    private func selectPackAndFindPlay(_ language: Language) -> XCUIElement? {
        let title = packTitles.element(boundBy: 0)
        guard title.waitForExistence(timeout: 10) else { return nil }
        title.tap()
        let label = app.staticTexts[language.play].firstMatch
        guard label.waitForExistence(timeout: 5) else { return nil }
        return label
    }

    private func requireEmptyLibrary() throws {
        launch(Self.english)
        if !text(Self.english.title).waitForExistence(timeout: 10) && packTitles.count > 0 {
            throw XCTSkip("the library is not empty; uninstall the app before this test")
        }
    }

    // MARK: - Steps

    private func checkGuideInEveryLanguage() {
        for language in Self.all {
            launch(language)
            assertGuide(language)
            shot(language, "01-empty-guide")
        }
    }

    private func checkLinkOpensBrowser() {
        launch(Self.english)
        XCTAssertTrue(guideLink.waitForExistence(timeout: 10))
        guideLink.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20), "the guide link did not open Safari")
        sleep(3)
        UITestSupport.attachScreenshot("en-02-guide-link-safari", to: self)
        let address = safari.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS[c] 'unipad.io' OR label CONTAINS[c] 'unipad.io'"))
            .firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10), "Safari does not show unipad.io")
        app.activate()
        XCTAssertTrue(home.waitForExistence(timeout: 10), "coming back from Safari never reached home")
        XCTAssertTrue(text(Self.english.title).exists, "the guide went away after coming back from Safari")
    }

    /// Opens a picker row, trying each label in turn, because the picker follows the app language.
    @discardableResult
    private func tapFirst(_ labels: [String], timeout: TimeInterval = 3) -> Bool {
        let predicate = NSPredicate(format: "label IN %@", labels)
        for query in [app.buttons, app.cells, app.staticTexts] {
            let element = query.matching(predicate).firstMatch
            if element.waitForExistence(timeout: timeout) && element.isHittable {
                element.tap()
                return true
            }
        }
        return false
    }

    private func importPackThroughPicker(_ language: Language, success: String) throws {
        launch(language)
        UITestSupport.revealHomeCard(.import, in: app).tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "취소"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "[\(language.code)] the file picker never opened")
        shot(language, "03-picker")

        let pack = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", Self.packFile)).firstMatch
        if !pack.waitForExistence(timeout: 3) {
            tapFirst(["Browse", "둘러보기"])
            tapFirst(["On My iPhone", "나의 iPhone"])
        }
        guard pack.waitForExistence(timeout: 10) else {
            shot(language, "03-picker-no-pack")
            add(XCTAttachment(string: app.debugDescription))
            cancel.tap()
            throw XCTSkip("\(Self.packFile).zip is not in the simulator's On My iPhone folder")
        }
        shot(language, "04-picker-pack")
        pack.tap()

        let done = text(success)
        XCTAssertTrue(done.waitForExistence(timeout: 60), "[\(language.code)] \"\(success)\" never appeared")
        shot(language, "05-import-done")
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Accept", "확인"])).firstMatch.tap()

        XCTAssertTrue(packTitles.element(boundBy: 0).waitForExistence(timeout: 10), "[\(language.code)] the pack is not listed")
        XCTAssertFalse(text(language.title).exists, "[\(language.code)] the guide is still shown with a pack")
        XCTAssertFalse(guideLink.exists, "[\(language.code)] the guide link is still shown with a pack")
        XCTAssertTrue(UITestSupport.revealHomeCard(.import, in: app).exists, "[\(language.code)] the cards went away")
        shot(language, "06-guide-gone")
    }

    private func checkPlay(_ language: Language, opens: Bool) {
        launch(language)
        guard let play = selectPackAndFindPlay(language) else {
            shot(language, "07-no-play")
            XCTFail("[\(language.code)] no \"\(language.play)\" beside the selected pack")
            return
        }
        shot(language, "07-pack-selected")
        guard opens else { return }
        play.tap()
        XCTAssertTrue(app.otherElements["playPadGrid"].waitForExistence(timeout: 30), "[\(language.code)] the pack never opened")
        sleep(2)
        shot(language, "08-play")
    }

    @MainActor
    func testFromEmptyGuideToPlayingAPack() throws {
        try requireEmptyLibrary()
        checkGuideInEveryLanguage()
        checkLinkOpensBrowser()
        try importPackThroughPicker(Self.korean, success: "불러오기 성공!")
        checkPlay(Self.korean, opens: true)
        checkPlay(Self.english, opens: true)
        checkPlay(Self.spanish, opens: false)
        checkPlay(Self.german, opens: false)
    }
}
