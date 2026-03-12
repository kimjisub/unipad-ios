import SwiftUI
import os.log

@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    private let logger = Logger(subsystem: "com.kimjisub.unipad", category: "ThemeManager")
    private let preferenceManager = PreferenceManager.shared

    private(set) var activeResources: ThemeResourcesProtocol = DefaultThemeResources()
    private(set) var activeThemeId: String = "default"
    var lastLoadError: String?

    private init() {
        reloadActiveTheme()
    }

    func reloadActiveTheme() {
        let themeId = preferenceManager.selectedTheme
        activeThemeId = themeId
        lastLoadError = nil
        activeResources = loadTheme(id: themeId, fullLoad: true)
    }

    func applyTheme(id: String) {
        preferenceManager.selectedTheme = id
        activeThemeId = id
        activeResources = loadTheme(id: id, fullLoad: true)
    }

    static let bundledThemePrefix = "bundled://"

    func loadTheme(id: String, fullLoad: Bool = false) -> ThemeResourcesProtocol {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        if id == "default" || id == bundleId {
            logger.info("loadTheme: using default theme (id=\(id))")
            return DefaultThemeResources()
        }

        if id.hasPrefix(Self.bundledThemePrefix) {
            let themeName = String(id.dropFirst(Self.bundledThemePrefix.count))
            guard let bundleURL = Bundle.main.url(forResource: "BundledThemes", withExtension: "bundle"),
                  let themeDir = Bundle(url: bundleURL)?.url(forResource: themeName, withExtension: nil) else {
                logger.warning("Bundled theme '\(themeName)' not found in app bundle. Falling back to default.")
                return DefaultThemeResources()
            }
            do {
                let theme = try FolderThemeResources(themeDir: themeDir, fullLoad: fullLoad)
                logger.info("loadTheme: loaded bundled theme '\(themeName)' successfully")
                return theme
            } catch {
                logger.warning("Failed to load bundled theme '\(themeName)': \(error.localizedDescription). Falling back to default.")
                lastLoadError = "\(String(localized: "skinErr"))\n\(themeName)"
                return DefaultThemeResources()
            }
        }

        let themesDir = Self.themesDirectory
        let themeDir = themesDir.appendingPathComponent(id)

        do {
            let theme = try FolderThemeResources(themeDir: themeDir, fullLoad: fullLoad)
            logger.info("loadTheme: loaded folder theme '\(id)' successfully")
            return theme
        } catch {
            logger.warning("Failed to load theme '\(id)': \(error.localizedDescription). Falling back to default.")
            lastLoadError = "\(String(localized: "skinErr"))\n\(id)"
            preferenceManager.selectedTheme = Bundle.main.bundleIdentifier ?? "com.kimjisub.unipad"
            return DefaultThemeResources()
        }
    }

    static func bundledThemeNames() -> [String] {
        guard let bundleURL = Bundle.main.url(forResource: "BundledThemes", withExtension: "bundle"),
              let themeBundle = Bundle(url: bundleURL) else {
            return []
        }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: themeBundle.bundleURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return contents.compactMap { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir ? url.lastPathComponent : nil
        }.sorted()
    }

    private static var themesDirectory: URL {
        let docs = WorkspaceManager.documentsDirectory
        let upper = docs.appendingPathComponent("Themes", isDirectory: true)
        let lower = docs.appendingPathComponent("themes", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: upper.path) { return upper }
        if fm.fileExists(atPath: lower.path) { return lower }
        WorkspaceManager.ensureDirectoryExists(at: upper)
        return upper
    }
}
