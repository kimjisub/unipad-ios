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

    private init() {
        reloadActiveTheme()
    }

    func reloadActiveTheme() {
        let themeId = preferenceManager.selectedTheme
        activeThemeId = themeId
        activeResources = loadTheme(id: themeId, fullLoad: true)
    }

    func applyTheme(id: String) {
        preferenceManager.selectedTheme = id
        activeThemeId = id
        activeResources = loadTheme(id: id, fullLoad: true)
    }

    func loadTheme(id: String, fullLoad: Bool = false) -> ThemeResourcesProtocol {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        if id == "default" || id == bundleId {
            logger.info("loadTheme: using default theme (id=\(id))")
            return DefaultThemeResources()
        }

        let themesDir = Self.themesDirectory
        let themeDir = themesDir.appendingPathComponent(id)

        do {
            let theme = try FolderThemeResources(themeDir: themeDir, fullLoad: fullLoad)
            logger.info("loadTheme: loaded folder theme '\(id)' successfully")
            return theme
        } catch {
            logger.warning("Failed to load theme '\(id)': \(error.localizedDescription). Falling back to default.")
            return DefaultThemeResources()
        }
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
