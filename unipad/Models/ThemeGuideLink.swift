import Foundation

/// The public guide for making a theme, on unipad.io.
///
/// The site picks Korean or English from the browser's language, which follows the
/// device. Someone may set UniPad alone to Korean in Settings, so a Korean app opens
/// the Korean page directly; any other app language leaves the choice to the site.
enum ThemeGuideLink {
    static let defaultURL = URL(string: "https://unipad.io/docs/theme")!
    static let koreanURL = URL(string: "https://unipad.io/ko/docs/theme")!

    static func url(appLanguages: [String] = Bundle.main.preferredLocalizations) -> URL {
        guard let language = appLanguages.first else { return defaultURL }
        return Locale(identifier: language).language.languageCode == .korean ? koreanURL : defaultURL
    }
}
