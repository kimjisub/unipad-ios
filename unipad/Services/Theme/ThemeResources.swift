import SwiftUI

// MARK: - Theme Metadata

struct ThemeMetadata: Codable {
    let name: String
    let author: String
    var version: String = "1.0"
}

struct ThemeColors: Codable {
    var checkbox: String?
    var traceLog: String?
    var optionWindow: String?
    var optionWindowCheckbox: String?

    enum CodingKeys: String, CodingKey {
        case checkbox
        case traceLog = "trace_log"
        case optionWindow = "option_window"
        case optionWindowCheckbox = "option_window_checkbox"
    }
}

// MARK: - Protocol

protocol ThemeResourcesProtocol {
    var icon: PlatformImage? { get }
    var name: String { get }
    var author: String { get }
    var version: String { get }

    var playbg: PlatformImage? { get }
    var customLogo: PlatformImage? { get }
    var btn: PlatformImage? { get }
    var btnPressed: PlatformImage? { get }
    var chainled: PlatformImage? { get }
    var chain: PlatformImage? { get }
    var chainSelected: PlatformImage? { get }
    var chainGuide: PlatformImage? { get }
    var phantom: PlatformImage? { get }
    var phantomVariant: PlatformImage? { get }
    var isChainLed: Bool { get }

    var checkboxColor: Color { get }
    var traceLogColor: Color { get }
    var optionWindowColor: Color { get }
    var optionWindowCheckboxColor: Color { get }
}

// MARK: - Default Theme

struct DefaultThemeResources: ThemeResourcesProtocol {
    let icon: PlatformImage? = PlatformImage(named: "theme_ic")
    let name: String = String(localized: "theme")
    let author: String = "UniPad dev."
    let version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    let playbg: PlatformImage? = PlatformImage(named: "playbg")
    let customLogo: PlatformImage? = nil
    let btn: PlatformImage? = PlatformImage(named: "btn")
    let btnPressed: PlatformImage? = PlatformImage(named: "btn_pressed")
    let chainled: PlatformImage? = PlatformImage(named: "chainled")
    let chain: PlatformImage? = PlatformImage(named: "chain")
    let chainSelected: PlatformImage? = PlatformImage(named: "chain_selected")
    let chainGuide: PlatformImage? = PlatformImage(named: "chain_guide")
    let phantom: PlatformImage? = PlatformImage(named: "phantom")
    let phantomVariant: PlatformImage? = PlatformImage(named: "phantom_variant")
    let isChainLed: Bool = true

    let checkboxColor: Color = AppColors.checkbox
    let traceLogColor: Color = AppColors.traceLog
    let optionWindowColor: Color = AppColors.optionWindow
    let optionWindowCheckboxColor: Color = AppColors.optionWindowCheckbox
}

// MARK: - ZIP/Folder Theme

struct FolderThemeResources: ThemeResourcesProtocol {
    let icon: PlatformImage?
    let name: String
    let author: String
    let version: String

    let playbg: PlatformImage?
    let customLogo: PlatformImage?
    let btn: PlatformImage?
    let btnPressed: PlatformImage?
    let chainled: PlatformImage?
    let chain: PlatformImage?
    let chainSelected: PlatformImage?
    let chainGuide: PlatformImage?
    let phantom: PlatformImage?
    let phantomVariant: PlatformImage?
    let isChainLed: Bool

    let checkboxColor: Color
    let traceLogColor: Color
    let optionWindowColor: Color
    let optionWindowCheckboxColor: Color

    init(themeDir: URL, fullLoad: Bool = false) throws {
        guard let themeJsonURL = Self.findFile(in: themeDir, stem: "theme", ext: "json") else {
            throw ThemeLoadError.metadataNotFound
        }

        let jsonData = try Data(contentsOf: themeJsonURL)
        let decoder = JSONDecoder()
        let metadata = try decoder.decode(ThemeMetadata.self, from: jsonData)
        let defaults = DefaultThemeResources()

        let colors: ThemeColors? = if let colorsJsonURL = Self.findFile(in: themeDir, stem: "colors", ext: "json"),
            let colorsData = try? Data(contentsOf: colorsJsonURL) {
            try? decoder.decode(ThemeColors.self, from: colorsData)
        } else {
            nil
        }

        self.name = metadata.name
        self.author = metadata.author
        self.version = metadata.version

        icon = Self.loadPng(from: themeDir, name: "theme_ic") ?? defaults.icon

        if fullLoad {
            playbg = Self.loadPng(from: themeDir, name: "playbg") ?? defaults.playbg
            customLogo = Self.loadPng(from: themeDir, name: "custom_logo")
            btn = Self.loadPng(from: themeDir, name: "btn") ?? defaults.btn
            btnPressed = Self.loadAnyPng(from: themeDir, names: ["btn_", "btn_pressed", "btn-pressed"]) ?? defaults.btnPressed

            let chainledImage = Self.loadPng(from: themeDir, name: "chainled")
            if chainledImage != nil {
                chainled = chainledImage
                isChainLed = true
                chain = nil
                chainSelected = nil
                chainGuide = nil
            } else {
                chainled = nil
                isChainLed = false
                chain = Self.loadPng(from: themeDir, name: "chain") ?? defaults.chain
                chainSelected = Self.loadAnyPng(from: themeDir, names: ["chain_", "chain_selected"]) ?? defaults.chainSelected
                chainGuide = Self.loadAnyPng(from: themeDir, names: ["chain__", "chain_guide"]) ?? defaults.chainGuide
            }

            phantom = Self.loadPng(from: themeDir, name: "phantom") ?? defaults.phantom
            phantomVariant = Self.loadAnyPng(from: themeDir, names: ["phantom_", "phantom_variant"])

            checkboxColor = Self.parseColor(colors?.checkbox) ?? defaults.checkboxColor
            traceLogColor = Self.parseColor(colors?.traceLog) ?? defaults.traceLogColor
            optionWindowColor = Self.parseColor(colors?.optionWindow) ?? defaults.optionWindowColor
            optionWindowCheckboxColor = Self.parseColor(colors?.optionWindowCheckbox) ?? defaults.optionWindowCheckboxColor
        } else {
            playbg = nil
            customLogo = nil
            btn = nil
            btnPressed = nil
            chainled = nil
            chain = nil
            chainSelected = nil
            chainGuide = nil
            phantom = nil
            phantomVariant = nil
            isChainLed = true
            checkboxColor = AppColors.checkbox
            traceLogColor = AppColors.traceLog
            optionWindowColor = AppColors.optionWindow
            optionWindowCheckboxColor = AppColors.optionWindowCheckbox
        }
    }

    private static func loadPng(from dir: URL, name: String) -> PlatformImage? {
        guard let fileURL = findFile(in: dir, stem: name, ext: "png"),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return PlatformImage(data: data)
    }

    private static func loadAnyPng(from dir: URL, names: [String]) -> PlatformImage? {
        for name in names {
            if let image = loadPng(from: dir, name: name) {
                return image
            }
        }
        return nil
    }

    private static func findFile(in dir: URL, stem: String, ext: String) -> URL? {
        let fm = FileManager.default
        let expected = "\(stem).\(ext)".lowercased()
        if let direct = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for url in direct where url.lastPathComponent.lowercased() == expected {
                return url
            }
            for subdir in direct {
                let isDir = (try? subdir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                if let nested = try? fm.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil).first(where: {
                    $0.lastPathComponent.lowercased() == expected
                }) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func parseColor(_ hex: String?) -> Color? {
        guard let hex else { return nil }
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        switch cleaned.count {
        case 6:
            guard let value = UInt32(cleaned, radix: 16) else { return nil }
            return Color(
                red: Double((value >> 16) & 0xFF) / 255.0,
                green: Double((value >> 8) & 0xFF) / 255.0,
                blue: Double(value & 0xFF) / 255.0
            )
        case 8:
            guard let value = UInt32(cleaned, radix: 16) else { return nil }
            return Color(
                red: Double((value >> 16) & 0xFF) / 255.0,
                green: Double((value >> 8) & 0xFF) / 255.0,
                blue: Double(value & 0xFF) / 255.0,
                opacity: Double((value >> 24) & 0xFF) / 255.0
            )
        default:
            return nil
        }
    }
}

// MARK: - Error

enum ThemeLoadError: LocalizedError {
    case metadataNotFound

    var errorDescription: String? {
        switch self {
        case .metadataNotFound: "theme.json not found in theme directory"
        }
    }
}
