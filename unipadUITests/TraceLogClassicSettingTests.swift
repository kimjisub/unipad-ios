//
//  TraceLogClassicSettingTests.swift
//  unipadUITests
//
//  Settings > Play has a switch that shows the tap order as numbers on the pads
//  (stored under `TraceLogClassic`). Its old name did not say that, so people
//  asked for a feature that was already there. These tests require the row to
//  say what it does in each language, keep its value across launches, and put
//  numbers on the pads once the play screen's Trace Log switch is on. The
//  numbers are drawn on a canvas that accessibility cannot read, so the play
//  screen is attached as a screenshot to be looked at.
//

import XCTest

final class TraceLogClassicSettingTests: XCTestCase {

    private struct Language {
        let code: String
        let locale: String
        /// `trace_log_classic` and `trace_log_classic_desc` in that language's Localizable.strings.
        let title: String
        let description: String
    }

    private static let korean = Language(
        code: "ko", locale: "ko_KR",
        title: "패드에 누른 순서 숫자 표시",
        description: "연주 중 순서 기록을 켜면 선과 점 대신 각 패드에 누른 순서를 숫자로 표시합니다"
    )
    private static let english = Language(
        code: "en", locale: "en_US",
        title: "Show tap order numbers on pads",
        description: "While Trace Log is on in play, show the tap order as numbers on each pad instead of lines and dots"
    )
    /// French has the longest description of all languages.
    private static let french = Language(
        code: "fr", locale: "fr_FR",
        title: "Numéros d'ordre sur les pads",
        description: "Quand le Journal de suivi est activé pendant le jeu, affiche l'ordre des appuis sous forme de chiffres sur chaque pad au lieu de lignes et de points"
    )

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ language: Language, extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments += UITestSupport.launchArguments(language: language.code, locale: language.locale)
        app.launchArguments += extraArguments
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30), "[\(language.code)] home never appeared")
    }

    private func openSettingsRow(_ language: Language) -> XCUIElement {
        app.buttons["gearshape"].tap()
        let title = app.staticTexts[language.title]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "[\(language.code)] settings has no \"\(language.title)\"")
        // Subscript lookup rejects identifiers longer than 128 characters, and the French description is longer.
        let description = app.staticTexts.matching(NSPredicate(format: "label == %@", language.description)).firstMatch
        XCTAssertTrue(description.exists, "[\(language.code)] settings has no description")
        return title
    }

    /// The row's switch has no label of its own; it is the one on the title's line.
    private func rowSwitch(beside title: XCUIElement) -> XCUIElement? {
        app.switches.allElementsBoundByIndex.first { $0.frame.minY <= title.frame.maxY && $0.frame.maxY >= title.frame.minY }
    }

    private func isOn(_ toggle: XCUIElement) -> Bool { (toggle.value as? String) == "1" }

    /// The play option panel is taller than the screen; Trace Log sits in its lower TOOLS section.
    private func scrollIntoView(_ element: XCUIElement) {
        let panel = app.scrollViews.firstMatch
        let inView = { panel.frame.contains(element.frame) }
        for _ in 0..<6 where !inView() {
            if element.frame.midY < panel.frame.midY { panel.swipeDown(velocity: .slow) } else { panel.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(inView(), "\(element.label) never scrolled into view")
    }

    @MainActor
    func testRowSaysItShowsTapOrderNumbers() throws {
        for language in [Self.korean, Self.english, Self.french] {
            launch(language)
            _ = openSettingsRow(language)
            UITestSupport.attachScreenshot("\(language.code)-settings-play", to: self)
            app.terminate()
        }
    }

    @MainActor
    func testValueIsKeptAcrossLaunches() throws {
        launch(Self.english)
        var toggle = try XCTUnwrap(rowSwitch(beside: openSettingsRow(Self.english)), "no switch on the row")
        let original = isOn(toggle)
        toggle.tap()
        XCTAssertNotEqual(isOn(toggle), original, "switch did not change")
        app.terminate()

        launch(Self.english)
        toggle = try XCTUnwrap(rowSwitch(beside: openSettingsRow(Self.english)), "no switch on the row")
        XCTAssertNotEqual(isOn(toggle), original, "value was not kept across launches")
        toggle.tap()
        XCTAssertEqual(isOn(toggle), original, "switch did not change back")
    }

    /// `-TraceLogClassic YES` sets the value for this launch only, without touching what is stored.
    @MainActor
    func testNumbersAppearOnPadsWithTraceLogOn() throws {
        launch(Self.english, extraArguments: ["-TraceLogClassic", "YES"])
        let packTitles = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", " - "))
        guard packTitles.count > 0 else { throw XCTSkip("no pack in the library") }
        let title = packTitles.element(boundBy: 0)
        title.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() } else { title.tap() }

        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "pad grid never appeared")
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "menu button never appeared")
        menu.tap()
        let traceLog = app.switches["Trace Log"].firstMatch
        XCTAssertTrue(traceLog.waitForExistence(timeout: 5), "no Trace Log option in the menu")
        scrollIntoView(traceLog)
        if !isOn(traceLog) { traceLog.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertTrue(isOn(traceLog), "Trace Log did not switch on")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "option panel never closed")

        // Same order as the Android check: pad (2,2) gets "1 4", (2,5) "2", (3,3) "3".
        for (row, col) in [(2, 2), (2, 5), (3, 3), (2, 2)] {
            grid.coordinate(withNormalizedOffset: CGVector(dx: (CGFloat(col) + 0.5) / 8, dy: (CGFloat(row) + 0.5) / 8)).tap()
        }
        sleep(1)
        UITestSupport.attachScreenshot("play-tap-order-numbers", to: self)
    }
}
