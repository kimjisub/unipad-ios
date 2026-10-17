import XCTest

/// The play screen's option panel names its sections in the app's language.
/// Install Fixtures/PlaybackStop in Documents/UniPack before running: the panel only
/// shows its play mode section for a pack with autoplay, which that fixture has.
final class PlayOptionSectionTitleTests: XCTestCase {

    private struct Language {
        let code: String
        let locale: String
        /// The `play_section_*` strings in that language's Localizable.strings, as the panel
        /// shows them (upper-cased).
        let titles: [String]
        /// `unipack_play`: the button on a selected pack that opens it.
        let play: String
    }

    private static let languages = [
        Language(code: "ko", locale: "ko_KR", titles: ["연주 모드", "효과", "화면", "도구"], play: "재생"),
        Language(code: "en", locale: "en_US", titles: ["PLAY MODE", "PERFORMANCE", "DISPLAY", "TOOLS"], play: "Play"),
    ]

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSectionTitlesFollowAppLanguage() {
        for language in Self.languages {
            app = XCUIApplication()
            app.launchArguments += UITestSupport.launchArguments(language: language.code, locale: language.locale)
            app.launch()
            UITestSupport.dismissSystemAlerts()
            openOptionPanel(language)
            UITestSupport.attachScreenshot("\(language.code)-option-panel-top", to: self)

            for title in language.titles {
                XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5),
                              "[\(language.code)] option panel has no \"\(title)\" section")
            }
            let tools = app.staticTexts[language.titles[3]]
            XCTAssertTrue(UITestSupport.scrollIntoView(tools, in: app.scrollViews.firstMatch, app: app),
                          "[\(language.code)] \"\(language.titles[3])\" never scrolled into view")
            UITestSupport.attachScreenshot("\(language.code)-option-panel-bottom", to: self)
            app.terminate()
        }
    }

    @MainActor
    private func openOptionPanel(_ language: Language) {
        UITestSupport.openPlaybackStopFixture(in: app, playButtonTitle: language.play)
        app.buttons["line.3.horizontal"].tap()
        XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 5),
                      "[\(language.code)] option panel never opened")
    }
}
