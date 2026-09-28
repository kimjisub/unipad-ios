import Foundation
import Testing

/// The Settings row for `PreferenceManager.Keys.traceLogClassic` has to say what it
/// does: people looked for a way to see tap order as numbers and did not find it
/// under its old name. The numbers only appear while the play screen's Trace Log
/// switch is on, so the description names that switch in each language's own words.
struct TraceLogClassicStringsTests {

    private static let maxTitleLength = 40

    private static func strings(for localization: String) -> [String: String]? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("\(localization).lproj")
            .appendingPathComponent("Localizable.strings")
        return NSDictionary(contentsOf: url) as? [String: String]
    }

    private static var localizations: [String] {
        Bundle.main.localizations.filter { $0 != "Base" }
    }

    @Test func descriptionNamesThePlayScreenTraceLogSwitch() throws {
        for localization in Self.localizations {
            let table = try #require(Self.strings(for: localization), "no strings for \(localization)")
            let switchName = try #require(table["traceLog"], "\(localization) has no traceLog")
            let description = try #require(table["trace_log_classic_desc"], "\(localization) has no description")
            #expect(description.localizedCaseInsensitiveContains(switchName),
                    "\(localization) description does not mention \"\(switchName)\": \(description)")
        }
    }

    @Test func titleStaysShortEnoughForOneSettingsRow() throws {
        for localization in Self.localizations {
            let title = try #require(Self.strings(for: localization)?["trace_log_classic"], "\(localization) has no title")
            #expect(title.count <= Self.maxTitleLength, "\(localization) title is \(title.count) characters: \(title)")
        }
    }

    @Test func titleSaysItShowsNumbers() throws {
        let english = try #require(Self.strings(for: "en")?["trace_log_classic"])
        let korean = try #require(Self.strings(for: "ko")?["trace_log_classic"])
        #expect(english.localizedCaseInsensitiveContains("number"))
        #expect(korean.contains("숫자"))
    }

    @Test func translatedLanguagesDoNotShowTheEnglishTitle() throws {
        let english = try #require(Self.strings(for: "en")?["trace_log_classic"])
        for localization in Self.localizations where localization != "en" {
            #expect(Self.strings(for: localization)?["trace_log_classic"] != english,
                    "\(localization) still shows the English title")
        }
    }
}
