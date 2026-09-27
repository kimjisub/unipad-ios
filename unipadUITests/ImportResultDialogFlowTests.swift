//
//  ImportResultDialogFlowTests.swift
//  unipadUITests
//
//  Imports Faded.zip through the file picker in Korean, English and German and
//  checks the import-complete card: its wording, its two buttons, that OK only
//  closes it without counting a play, that Play now opens the imported pack, and
//  that tapping outside closes it.
//
//  The file picker can only show files the simulator has, so copy the pack into
//  the simulator's On My iPhone folder first; the tests skip otherwise (see
//  FirstPackGuideTests for where that folder is).
//

import XCTest

final class ImportResultDialogFlowTests: XCTestCase {

    private struct Language {
        let code: String
        let locale: String
        let success: String
        let ok: String
        let playNow: String
        let playCount: String
    }

    private static let korean = Language(
        code: "ko", locale: "ko_KR", success: "불러오기 성공!", ok: "확인", playNow: "지금 연주", playCount: "플레이 횟수")
    private static let english = Language(
        code: "en", locale: "en_US", success: "Pack imported!", ok: "OK", playNow: "Play now", playCount: "Play Count")
    private static let german = Language(
        code: "de", locale: "de_DE", success: "Pack importiert!", ok: "OK", playNow: "Jetzt spielen", playCount: "Wiedergaben")

    private static let packFile = "Faded"
    private static let packTitle = "Alan Walker - Faded"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private var home: XCUIElement { app.buttons["gearshape"] }
    private var okButton: XCUIElement { app.buttons["main.importResult.ok"] }
    private var playNowButton: XCUIElement { app.buttons["main.importResult.playNow"] }
    private var dialogTitle: XCUIElement { app.staticTexts["main.importResult.title"] }
    private var playGrid: XCUIElement { app.descendants(matching: .any)["playPadGrid"] }

    private func launch(_ language: Language) {
        app = XCUIApplication()
        app.launchArguments += [
            "-UniPadFirebaseLocalOnly", "YES",
            "-AppleLanguages", "(\(language.code))",
            "-AppleLocale", language.locale,
        ]
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(home.waitForExistence(timeout: 30), "[\(language.code)] home never appeared")
    }

    private func shot(_ language: Language, _ name: String) {
        UITestSupport.attachScreenshot("\(language.code)-\(name)", to: self)
    }

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

    /// The home screen's total play count, read from the number on the same row as its label.
    private func playCount(_ language: Language) -> String? {
        let label = app.staticTexts[language.playCount].firstMatch
        guard label.waitForExistence(timeout: 5) else { return nil }
        let row = label.frame
        let values = app.staticTexts.allElementsBoundByIndex.filter {
            $0.frame.minX > row.maxX && abs($0.frame.midY - row.midY) < 4
        }
        return values.first?.label
    }

    private func importPack(_ language: Language) throws {
        UITestSupport.revealHomeCard(.import, in: app).tap()
        let pack = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", Self.packFile)).firstMatch
        if !pack.waitForExistence(timeout: 3) {
            tapFirst(["Browse", "둘러보기", "Durchsuchen"])
            tapFirst(["On My iPhone", "나의 iPhone", "Auf meinem iPhone"])
        }
        guard pack.waitForExistence(timeout: 10) else {
            add(XCTAttachment(string: app.debugDescription))
            throw XCTSkip("\(Self.packFile).zip is not in the simulator's On My iPhone folder")
        }
        pack.tap()
    }

    private func assertDialog(_ language: Language, _ name: String) {
        XCTAssertTrue(dialogTitle.waitForExistence(timeout: 60), "[\(language.code)] the card never appeared")
        XCTAssertEqual(dialogTitle.label, language.success)
        XCTAssertTrue(app.staticTexts[Self.packTitle].exists, "[\(language.code)] the card does not name the pack")
        XCTAssertEqual(okButton.label, language.ok)
        XCTAssertEqual(playNowButton.label, language.playNow)
        XCTAssertTrue(okButton.isHittable && playNowButton.isHittable, "[\(language.code)] a button is covered")

        let window = app.windows.firstMatch.frame
        let ok = okButton.frame, play = playNowButton.frame
        XCTAssertFalse(ok.intersects(play), "[\(language.code)] the buttons overlap")
        XCTAssertTrue(window.contains(ok) && window.contains(play), "[\(language.code)] a button is off screen")
        XCTAssertEqual(ok.midY, play.midY, accuracy: 1, "[\(language.code)] the buttons are not on one row")
        XCTAssertLessThan(ok.maxX, play.minX, "[\(language.code)] OK is not left of Play now")
        XCTAssertGreaterThan(play.width, ok.width, "[\(language.code)] Play now is not the wide button")

        let rawKeys = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'import'")).count
        XCTAssertEqual(rawKeys, 0, "[\(language.code)] a raw string key is shown")
        shot(language, "\(name)-card")
    }

    private func runFlow(_ language: Language) throws {
        launch(language)
        shot(language, "01-home")
        let before = playCount(language)

        try importPack(language)
        assertDialog(language, "02")
        okButton.tap()
        XCTAssertFalse(dialogTitle.waitForExistence(timeout: 2), "[\(language.code)] OK did not close the card")
        XCTAssertTrue(home.waitForExistence(timeout: 5), "[\(language.code)] OK did not return home")
        XCTAssertFalse(playGrid.exists, "[\(language.code)] OK opened the play screen")
        if let before {
            XCTAssertEqual(playCount(language), before, "[\(language.code)] OK counted a play")
        } else {
            add(XCTAttachment(string: "play count not found on home:\n\(app.debugDescription)"))
        }
        shot(language, "03-after-ok")

        try importPack(language)
        assertDialog(language, "04")
        playNowButton.tap()
        XCTAssertTrue(playGrid.waitForExistence(timeout: 30), "[\(language.code)] Play now did not open the pack")
        XCTAssertFalse(dialogTitle.exists, "[\(language.code)] the card stayed over the play screen")
        sleep(2)
        shot(language, "05-play")
    }

    @MainActor
    func testKorean() throws {
        try runFlow(Self.korean)
    }

    @MainActor
    func testEnglish() throws {
        try runFlow(Self.english)
    }

    @MainActor
    func testGerman() throws {
        try runFlow(Self.german)
    }

    @MainActor
    func testTappingOutsideCloses() throws {
        launch(Self.korean)
        try importPack(Self.korean)
        XCTAssertTrue(dialogTitle.waitForExistence(timeout: 60), "the card never appeared")
        // Window coordinates stay in portrait while the app is landscape-left, so this is the
        // middle of the left edge on screen; the bottom edge is the home indicator's and never
        // reaches the app.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
        UITestSupport.attachScreenshot("ko-06-after-outside-tap", to: self)
        XCTAssertFalse(dialogTitle.waitForExistence(timeout: 2), "tapping outside did not close the card")
        XCTAssertFalse(playGrid.exists, "tapping outside opened the play screen")
    }
}
