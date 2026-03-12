import SwiftUI

@Observable
final class ThemeViewModel {

    enum ThemeType {
        case builtin
        case zip
    }

    struct ThemeItem: Identifiable {
        let id: String
        var name: String
        var author: String
        var version: String?
        var type: ThemeType
        var isDeletable: Bool
        var icon: PlatformImage?
    }

    var themes: [ThemeItem] = []
    var selectedIndex = 0
    var appliedIndex = 0
    var importResultMessage: String?

    private let preferenceManager = PreferenceManager.shared
    private let themeManager = ThemeManager.shared

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

    init() {
        loadThemes()
    }

    func loadThemes() {
        var items: [ThemeItem] = [
            ThemeItem(
                id: "default",
                name: String(localized: "theme"),
                author: "UniPad dev.",
                type: .builtin,
                isDeletable: false,
                icon: nil
            )
        ]

        // Bundled asset themes
        let themeBundleURL = Bundle.main.url(forResource: "BundledThemes", withExtension: "bundle")
        let themeBundle = themeBundleURL.flatMap { Bundle(url: $0) }
        for themeName in ThemeManager.bundledThemeNames() {
            let themeId = "\(ThemeManager.bundledThemePrefix)\(themeName)"
            if let themeDir = themeBundle?.url(forResource: themeName, withExtension: nil),
               let resources = try? FolderThemeResources(themeDir: themeDir, fullLoad: false) {
                items.append(ThemeItem(
                    id: themeId,
                    name: resources.name,
                    author: resources.author,
                    version: resources.version,
                    type: .builtin,
                    isDeletable: false,
                    icon: resources.icon
                ))
            }
        }

        // User-imported ZIP themes
        let fm = FileManager.default
        let themesDir = Self.themesDirectory
        if let contents = try? fm.contentsOfDirectory(at: themesDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for themeURL in contents {
                let isDir = (try? themeURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    let folderId = themeURL.lastPathComponent
                    guard let resources = try? FolderThemeResources(themeDir: themeURL, fullLoad: false) else {
                        continue
                    }
                    items.append(ThemeItem(
                        id: folderId,
                        name: resources.name,
                        author: resources.author,
                        version: resources.version,
                        type: .zip,
                        isDeletable: true,
                        icon: resources.icon
                    ))
                }
            }
        }

        themes = items

        let savedTheme = preferenceManager.selectedTheme
        if let idx = themes.firstIndex(where: { $0.id == savedTheme }) {
            appliedIndex = idx
            selectedIndex = idx
        } else {
            appliedIndex = 0
            selectedIndex = 0
        }
    }

    var selectedThemeResources: ThemeResourcesProtocol? {
        guard selectedIndex < themes.count else { return nil }
        let id = themes[selectedIndex].id
        return themeManager.loadTheme(id: id, fullLoad: true)
    }

    func applyTheme(at index: Int) {
        guard index < themes.count else { return }
        appliedIndex = index
        themeManager.applyTheme(id: themes[index].id)
    }

    func importTheme(from url: URL) {
        let fm = FileManager.default
        let themesDir = Self.themesDirectory
        let sourceName = FileManagerExtensions.filterFilename(url.deletingPathExtension().lastPathComponent)
        let destDir = FileManagerExtensions.makeNextPath(dir: themesDir, name: sourceName, extension: "")

        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            if url.pathExtension.lowercased() == "zip" {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                try fm.unzipItem(at: url, to: destDir)
                FileManagerExtensions.removeDoubleFolder(at: destDir)
                try normalizeThemeResources(at: destDir)
                _ = try FolderThemeResources(themeDir: destDir, fullLoad: false)
            } else {
                try? fm.removeItem(at: destDir)
                importResultMessage = "\(String(localized: "theme_import_invalid"))"
                return
            }

            loadThemes()
            importResultMessage = String(localized: "theme_import_success")
        } catch {
            try? fm.removeItem(at: destDir)
            importResultMessage = "\(String(localized: "theme_import_failed"))\n\(error.localizedDescription)"
        }
    }

    private func normalizeThemeResources(at dir: URL) throws {
        let fm = FileManager.default

        func fileURL(named name: String) -> URL {
            dir.appendingPathComponent(name)
        }

        func allFilesRecursive(in root: URL) -> [URL] {
            guard let en = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            var result: [URL] = []
            for case let url as URL in en {
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                if isFile { result.append(url) }
            }
            return result
        }

        func copyAlias(_ aliases: [String], to canonical: String) {
            let target = fileURL(named: canonical)
            if fm.fileExists(atPath: target.path) { return }
            let allFiles = allFilesRecursive(in: dir)
            let aliasSet = Set(aliases.map { $0.lowercased() })
            guard let source = allFiles.first(where: { aliasSet.contains($0.lastPathComponent.lowercased()) }) else { return }
            try? fm.copyItem(at: source, to: target)
        }

        copyAlias(["theme.json"], to: "theme.json")
        copyAlias(["colors.json"], to: "colors.json")
        copyAlias(["theme_ic.png", "theme_ic.webp"], to: "theme_ic.png")
        copyAlias(["playbg.png", "play_bg.png"], to: "playbg.png")
        copyAlias(["custom_logo.png", "customlogo.png"], to: "custom_logo.png")
        copyAlias(["btn.png"], to: "btn.png")
        copyAlias(["btn_.png", "btn_pressed.png", "btn-pressed.png"], to: "btn_.png")
        copyAlias(["chainled.png"], to: "chainled.png")
        copyAlias(["chain.png"], to: "chain.png")
        copyAlias(["chain_.png", "chain_selected.png"], to: "chain_.png")
        copyAlias(["chain__.png", "chain_guide.png"], to: "chain__.png")
        copyAlias(["phantom.png"], to: "phantom.png")
        copyAlias(["phantom_.png", "phantom_variant.png"], to: "phantom_.png")
    }

    func deleteTheme(_ item: ThemeItem) {
        guard item.isDeletable else { return }
        let themePath = Self.themesDirectory.appendingPathComponent(item.id)
        try? FileManager.default.removeItem(at: themePath)

        if themeManager.activeThemeId == item.id {
            themeManager.applyTheme(id: "default")
        }

        loadThemes()
    }
}
