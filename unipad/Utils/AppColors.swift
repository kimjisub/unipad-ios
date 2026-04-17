import SwiftUI

enum AppColors {
    // MARK: - Backgrounds (from Android color.xml & Compose theme)

    /// Main background - Android background1
    static let background1 = Color(hex: 0x161E2B)

    /// Secondary background - Android background2
    static let background2 = Color(hex: 0x414F66)

    /// Dark surface - Android Compose DarkSurface
    static let darkSurface = Color(hex: 0x1E2736)

    /// Dark surface high - Android Compose DarkSurfaceHigh
    static let darkSurfaceHigh = Color(hex: 0x283446)

    // MARK: - Text Colors

    /// Primary text - Android gray1
    static let textPrimary = Color(hex: 0xA6B4C9)

    /// Secondary text - Android gray2
    static let textSecondary = Color(hex: 0x808A99)

    /// Title text - Android title
    static let title = Color(hex: 0x767D89)

    /// Subtitle text - Android subtitle
    static let subtitle = Color(hex: 0xA1A6AE)

    // MARK: - Logo Colors

    /// Logo orange - Android ic_launcher quadrant
    static let logoOrange = Color(hex: 0xFF8F00)

    /// Logo cyan - Android ic_launcher quadrant
    static let logoCyan = Color(hex: 0x00B8D4)

    // MARK: - Accent Colors

    /// Blue accent - Android blue
    static let blue = Color(hex: 0x4283E6)

    /// Sky blue - Android skyblue
    static let skyblue = Color(hex: 0x00BCDA)

    /// Green - Android green
    static let green = Color(hex: 0x66BB6A)

    /// Orange - Android orange
    static let orange = Color(hex: 0xFFA726)

    /// Red - Android red
    static let red = Color(hex: 0xFF6B4E)

    /// Pink - Android pink
    static let pink = Color(hex: 0xFFA5A5)

    // MARK: - UI Element Colors

    static let white = Color(hex: 0xFFFFFF)

    /// Checkbox color - Android checkbox
    static let checkbox = Color(hex: 0xA6B4C9)

    /// Trace log background - Android trace_log
    static let traceLog = Color(hex: 0x161E2B)

    /// Option window background - Android option_window
    static let optionWindow = Color(hex: 0x161E2B)

    /// Option window checkbox - Android option_window_checkbox
    static let optionWindowCheckbox = Color(hex: 0x414F66)

    // MARK: - Derived / Layout Colors

    /// Navigation sidebar selected item
    static let navItemSelected = Color(hex: 0x1E2E44)

    /// Card divider - matches Android surfaceVariant (Background2)
    static let divider = Color(hex: 0x414F66)

    // MARK: - Play Screen Chrome Tokens
    // UI chrome tokens for the Play screen option panel + chrome column. Kept here so the
    // Play view layer does not ship with inline hex literals (CLAUDE.md guidance).

    /// Play screen accent (progress, active states).
    static let playAccent = Color(hex: 0xE8A44A)

    /// Destructive action tint (Quit icon).
    static let playDanger = Color(hex: 0xFF6B6B)

    /// Play mode identity colors for the segmented control.
    static let playModeAutoPlay = Color(hex: 0xE8A44A)
    static let playModeGuidePlay = Color(hex: 0x4FC3F7)
    static let playModeStepPractice = Color(hex: 0x66BB6A)
}
