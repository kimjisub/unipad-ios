import Foundation

/// The public guide for making a theme, on unipad.io.
///
/// The site has Korean and English pages and remembers the last language it was asked
/// for in a cookie, so the link always names a language: Korean when UniPad runs in
/// Korean, English otherwise. That keeps the guide in the app's language even after the
/// user changes it, and when UniPad alone is set to a language other than the device's.
enum ThemeGuideLink {
    static let englishURL = URL(string: "https://unipad.io/en/docs/theme")!
    static let koreanURL = URL(string: "https://unipad.io/ko/docs/theme")!

    static func url(appLanguages: [String] = Bundle.main.preferredLocalizations) -> URL {
        guard let language = appLanguages.first else { return englishURL }
        return Locale(identifier: language).language.languageCode == .korean ? koreanURL : englishURL
    }
}
