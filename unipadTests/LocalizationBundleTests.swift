import Foundation
import Testing

/// How the app bundle carries its strings, read from the built app these tests run in.
///
/// iOS reads a `Localizable.strings` at the top of the bundle before any `.lproj`
/// folder, so the English file must live in `en.lproj`. iOS also does not fall
/// back to English one key at a time: a key missing from the chosen language's
/// table shows up as the raw key. Every language table therefore carries every
/// English key, with the English text where there is no translation yet.
struct LocalizationBundleTests {

    private static let table = "Localizable"

    /// Read from the language folder itself: `Bundle.url(forResource:localization:)`
    /// returns the top-level file for every language when there is one.
    static func strings(for localization: String) -> [String: String]? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("\(localization).lproj")
            .appendingPathComponent("\(table).strings")
        return NSDictionary(contentsOf: url) as? [String: String]
    }

    private static var translations: [String] {
        Bundle.main.localizations.filter { $0 != "Base" && $0 != "en" }
    }

    @Test func englishStringsAreNotAtTheTopOfTheBundle() {
        let topLevel = Bundle.main.bundleURL.appendingPathComponent("\(Self.table).strings")
        #expect(!FileManager.default.fileExists(atPath: topLevel.path))
        #expect(Self.strings(for: "en")?.isEmpty == false)
    }

    @Test func languagesAreBundled() {
        #expect(Self.translations.count >= 17)
        #expect(Self.translations.contains("ko"))
        #expect(Self.translations.contains("es"))
    }

    @Test func koreanDevicePicksKoreanStrings() throws {
        let chosen = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: ["ko-KR"])
        #expect(chosen.first == "ko")
        let ko = try #require(Self.strings(for: "ko"))
        #expect(ko["settings_info"] == "정보")
    }

    @Test func everyLanguageHasEveryEnglishKey() throws {
        let english = try #require(Self.strings(for: "en"))
        for localization in Self.translations {
            let table = try #require(Self.strings(for: localization), "no \(Self.table).strings for \(localization)")
            let missing = Set(english.keys).subtracting(table.keys).sorted()
            #expect(missing.isEmpty, "\(localization) would show these keys as raw names: \(missing)")
            let empty = table.filter { $0.value.isEmpty && english[$0.key]?.isEmpty == false }.keys.sorted()
            #expect(empty.isEmpty, "\(localization) has empty values: \(empty)")
        }
    }
}
