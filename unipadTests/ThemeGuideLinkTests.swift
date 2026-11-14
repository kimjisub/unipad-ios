import Foundation
import Testing
@testable import unipad

struct ThemeGuideLinkTests {
    @Test(arguments: ["ko", "ko-KR", "ko_KR"])
    func koreanAppOpensKoreanGuide(language: String) {
        #expect(ThemeGuideLink.url(appLanguages: [language, "en"]) == URL(string: "https://unipad.io/ko/docs/theme")!)
    }

    @Test(arguments: [["en"], ["ja", "ko"], ["zh-Hans"], []])
    func otherAppLanguagesLeaveTheChoiceToTheSite(languages: [String]) {
        #expect(ThemeGuideLink.url(appLanguages: languages) == URL(string: "https://unipad.io/docs/theme")!)
    }
}
