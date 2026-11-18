import SwiftUI
import UIKit

/// Only explicit theme accents replace the existing orange and mode identity colors.
struct PlayOptionColors {
    let accent: Color
    let text: Color
    let icon: Color
    let selectionText: Color
    let usesThemeAccent: Bool

    init(theme: ThemeResourcesProtocol) {
        guard let custom = theme.optionWindowCheckboxColor else {
            accent = AppColors.playAccent
            text = AppColors.playAccent
            icon = AppColors.playAccent.opacity(0.7)
            selectionText = .black
            usesThemeAccent = false
            return
        }
        usesThemeAccent = true
        // Match the panel's 0.94 opacity over the half-black scrim, on either extreme
        // of a theme's play background. Include a colors.json color's own alpha.
        let panel = RGBA(theme.optionWindowColor.opacity(0.94))
        let backdrops = [RGBA.black, RGBA.white].map {
            panel.over(RGBA.black.withAlpha(0.5).over($0))
        }
        let fill = Self.readable(custom, on: backdrops, minimum: 3)
        accent = fill
        text = Self.readable(custom, on: backdrops, minimum: 4.5)
        icon = Self.readable(custom.opacity(0.7), on: backdrops, minimum: 3)
        let selectionBackdrops = backdrops.map { RGBA(fill).over($0) }
        let blackContrast = selectionBackdrops.map { RGBA.black.contrast(with: $0) }.min() ?? 1
        let whiteContrast = selectionBackdrops.map { RGBA.white.contrast(with: $0) }.min() ?? 1
        selectionText = blackContrast >= whiteContrast ? .black : .white
    }

    private static func readable(_ original: Color, on backgrounds: [RGBA], minimum: Double) -> Color {
        func worst(_ candidate: RGBA) -> Double {
            backgrounds.map { candidate.over($0).contrast(with: $0) }.min() ?? 1
        }
        let color = RGBA(original)
        guard worst(color) < minimum else { return original }
        let target = worst(.black) >= worst(.white) ? RGBA.black : .white
        let drawn = color.over(backgrounds[0])
        // As on Android, move towards black or white only as far as needed.
        for step in 1...50 {
            let amount = Double(step) / 50
            let candidate = RGBA(red: drawn.red + (target.red - drawn.red) * amount,
                                 green: drawn.green + (target.green - drawn.green) * amount,
                                 blue: drawn.blue + (target.blue - drawn.blue) * amount)
            if worst(candidate) >= minimum { return candidate.color }
        }
        // Extremely translucent or middle-gray panels may have no color meeting
        // the requested ratio on both backdrops; keep the stronger extreme.
        return target.color
    }

    private struct RGBA {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        static let black = RGBA(red: 0, green: 0, blue: 0)
        static let white = RGBA(red: 1, green: 1, blue: 1)

        init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        init(_ color: Color) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            self.init(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
        }

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

        func withAlpha(_ alpha: Double) -> RGBA {
            RGBA(red: red, green: green, blue: blue, alpha: alpha)
        }

        /// The backdrop is opaque after compositing the scrim over black or white.
        func over(_ background: RGBA) -> RGBA {
            RGBA(red: red * alpha + background.red * (1 - alpha),
                 green: green * alpha + background.green * (1 - alpha),
                 blue: blue * alpha + background.blue * (1 - alpha))
        }

        private var luminance: Double {
            func linear(_ channel: Double) -> Double {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return linear(red) * 0.2126 + linear(green) * 0.7152 + linear(blue) * 0.0722
        }

        func contrast(with other: RGBA) -> Double {
            (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
        }
    }
}
