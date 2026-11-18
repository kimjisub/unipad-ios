import SwiftUI
import Testing
import UIKit
@testable import unipad

@MainActor
struct PlayOptionThemeTests {
    private func theme(colors: String?) throws -> FolderThemeResources {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(##"{"name":"Options","author":"Tester"}"##.utf8)
            .write(to: directory.appending(path: "theme.json"))
        if let colors {
            try Data(colors.utf8).write(to: directory.appending(path: "colors.json"))
        }
        return try FolderThemeResources(themeDir: directory, fullLoad: true)
    }

    private func accent(colors: String?) throws -> Color {
        PlayOptionPanel(vm: PlayViewModel(), theme: try theme(colors: colors), onQuit: {}).accentColor
    }

    @Test func defaultThemeKeepsOrange() {
        let panel = PlayOptionPanel(vm: PlayViewModel(), theme: DefaultThemeResources(), onQuit: {})
        #expect(panel.accentColor == AppColors.playAccent)
    }

    @Test(arguments: [nil, "{}", ##"{"checkbox":"#00B8D4"}"##,
                      ##"{"option_window_checkbox":"invalid"}"##,
                      ##"{"option_window":"#FFFFFF"}"##] as [String?])
    func themeWithoutValidOptionAccentKeepsOrange(colors: String?) throws {
        #expect(try accent(colors: colors) == AppColors.playAccent)
    }

    @Test func explicitReadableAccentReachesPanel() throws {
        #expect(try accent(colors: ##"{"option_window_checkbox":"#00B8D4"}"##) == Color(hex: 0x00B8D4))
    }

    @Test func explicitLegacyGrayIsStillAnOverride() throws {
        #expect(try accent(colors: ##"{"option_window_checkbox":"#414F66"}"##) != AppColors.playAccent)
    }

    @Test func missingAccentKeepsModeIdentityAndTextColors() throws {
        let colors = PlayOptionColors(theme: try theme(colors: "{}"))
        #expect(!colors.usesThemeAccent)
        #expect(colors.text == AppColors.playAccent)
        #expect(colors.icon == AppColors.playAccent.opacity(0.7))
        #expect(colors.selectionText == .black)
    }

    @Test(arguments: [(0x161E2B, "#161E2B"), (0xFFFFFF, "#FFFFFF"),
                      (0x99AABB, "#99AABB"), (0x161E2B, "#20161E2B")])
    func lowContrastAccentsReadOnBothPanelBackdrops(background: Int, accent: String) throws {
        let json = String(format: "{\"option_window\":\"#%06X\",\"option_window_checkbox\":\"%@\"}", background, accent)
        let colors = PlayOptionColors(theme: try theme(colors: json))
        let panel = rgb(Color(hex: UInt32(background)))
        for playBackground in [0.0, 1.0] {
            let backdrop = panel.prefix(3).map { $0 * 0.94 + playBackground * 0.5 * 0.06 }
            #expect(contrast(colors.accent, on: backdrop) >= 3)
            #expect(contrast(colors.text, on: backdrop) >= 4.5)
            #expect(contrast(colors.icon, on: backdrop) >= 3)
            let fill = rgb(colors.accent)
            let selected = zip(fill.prefix(3), backdrop).map { $0 * fill[3] + $1 * (1 - fill[3]) }
            #expect(contrast(colors.selectionText, on: selected) >= 4.5)
        }
    }

    @Test func transparentPanelStillProducesAVisibleAccent() throws {
        let colors = PlayOptionColors(theme: try theme(colors:
            ##"{"option_window":"#00161E2B","option_window_checkbox":"#00161E2B"}"##))
        #expect(rgb(colors.accent)[3] == 1)
        #expect(colors.text == .black || colors.text == .white)
    }

    private func rgb(_ color: Color) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b), Double(a)]
    }

    /// Independent measurement of the final drawn colors, including alpha.
    private func contrast(_ color: Color, on background: [Double]) -> Double {
        let components = rgb(color)
        let drawn = zip(components.prefix(3), background).map { $0 * components[3] + $1 * (1 - components[3]) }
        func luminance(_ channels: [Double]) -> Double {
            let linear = channels.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let first = luminance(drawn), second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
