//
//  FirstPackGuideTests.swift
//  unipadUITests
//
//  Walks an isolated empty library from the guide to a playing pack:
//  the guide in English, Korean, Spanish and German, its link opening the
//  browser, importing a generated archive through the file picker, the guide going away,
//  and the Play label in each language.
//
//  The shared fixture creates the archive in Documents for the system picker.
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

    private let token = UUID().uuidString

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private var home: XCUIElement { app.buttons["gearshape"] }
    private var guideLink: XCUIElement { app.buttons["main.guide.getStarted"] }
    private var packTitles: XCUIElementQuery {
        app.scrollViews["main.packList"].staticTexts.matching(identifier: "Downloaded Fixture")
    }

    private func launch(_ language: Language) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments += UITestSupport.launchArguments(language: language.code, locale: language.locale,
                                                              library: "empty", token: token, file: true)
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
        let label = app.buttons[language.play].firstMatch
        guard label.waitForExistence(timeout: 5) else { return nil }
        return label
    }

    private func requireEmptyLibrary() throws {
        launch(Self.english)
        XCTAssertTrue(text(Self.english.title).waitForExistence(timeout: 10), "the test must prepare an empty library")
        XCTAssertEqual(packTitles.count, 0)
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

    private func importPackThroughPicker(_ language: Language, success: String) throws {
        launch(language)
        UITestSupport.revealHomeCard(.import, in: app).tap()
        try UITestSupport.selectPreparedArchive(token: token, in: app)

        let done = text(success)
        XCTAssertTrue(done.waitForExistence(timeout: 60), "[\(language.code)] \"\(success)\" never appeared")
        shot(language, "05-import-done")
        app.buttons["main.importResult.ok"].tap()

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

    /// Slow accessibility discovery must not consume the frame-settling deadline.
    @MainActor
    func testPickerSettlingGetsItsOwnDeadlineAfterLateArrival() {
        let arrivesAt = Date().addingTimeInterval(1.8)
        let frame = CGRect(x: 740, y: 28, width: 37, height: 36)
        XCTAssertTrue(UITestSupport.waitForSettledFrame(timeout: 2,
            waitForArrival: { _ in
                Thread.sleep(until: arrivesAt)
                return true
            },
            frame: { Date() >= arrivesAt ? frame : nil }),
            "a control arriving near its deadline still needs two stable frame samples")
    }

    /// The picker can remember Recents instead of opening a directory.
    @MainActor
    func testPreparedArchiveCanBeSelectedFromRecentItems() throws {
        launch(Self.korean)
        UITestSupport.revealHomeCard(.import, in: app).tap()
        let recents = app.tabBars.buttons
            .matching(NSPredicate(format: "label IN %@", ["Recents", "최근 항목"]))
            .firstMatch
        XCTAssertTrue(recents.waitForExistence(timeout: 20))
        recents.tap()
        shot(Self.korean, "picker-recents")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "picker-recents-tree"
        tree.lifetime = .keepAlways
        add(tree)
        try UITestSupport.selectPreparedArchive(token: token, in: app)
        XCTAssertTrue(text("불러오기 성공!").waitForExistence(timeout: 60))
        app.buttons["main.importResult.ok"].tap()
        XCTAssertTrue(packTitles.element(boundBy: 0).waitForExistence(timeout: 10))
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
