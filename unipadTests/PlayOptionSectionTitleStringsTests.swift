import Foundation
import Testing

/// The play screen's option panel groups its switches under section titles. The titles
/// use the same words as the Android app, so people moving between the two find the
/// same names in their own language.
struct PlayOptionSectionTitleStringsTests {

    private static let keys = [
        "play_section_play_mode",
        "play_section_performance",
        "play_section_display",
        "play_section_tools",
    ]

    @Test(arguments: [
        ("en", ["Play Mode", "Performance", "Display", "Tools"]),
        ("ko", ["연주 모드", "효과", "화면", "도구"]),
        ("de", ["Spielmodus", "Effekte", "Anzeige", "Werkzeuge"]),
        ("zh-Hans", ["演奏模式", "效果", "显示", "工具"]),
    ])
    func sectionTitlesMatchTheAndroidApp(localization: String, expected: [String]) throws {
        let table = try #require(LocalizationBundleTests.strings(for: localization))
        #expect(Self.keys.map { table[$0] } == expected)
    }

    /// The performance section sits right under the play mode section, so its title
    /// must not read as a repeat of the one above it.
    @Test func performanceTitleDoesNotRepeatPlayModeTitle() throws {
        for localization in Bundle.main.localizations where localization != "Base" {
            let table = try #require(LocalizationBundleTests.strings(for: localization))
            let playMode = try #require(table["play_section_play_mode"], "\(localization) has no play mode title")
            let performance = try #require(table["play_section_performance"], "\(localization) has no performance title")
            #expect(!playMode.localizedCaseInsensitiveContains(performance),
                    "\(localization): \"\(performance)\" repeats \"\(playMode)\"")
        }
    }
}
