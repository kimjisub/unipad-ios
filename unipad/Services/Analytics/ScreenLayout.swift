import CoreGraphics

/// How the play screen's window sat on the display, in coarse buckets only: the exact size never
/// leaves the device. Names, values and bounds match the Android app's, so both report into the
/// same Analytics dimensions.
struct ScreenLayout: Equatable {
    enum Orientation: String {
        case landscape
        case portrait
    }

    /// The window's short side in points, at the same 600 and 840 bounds as Android's window size
    /// classes in dp.
    enum ShortSide: String {
        case compact = "lt_600dp"
        case medium = "600dp_839dp"
        case expanded = "840dp_plus"

        static func of(_ points: CGFloat) -> ShortSide {
            if points < 600 { return .compact }
            if points < 840 { return .medium }
            return .expanded
        }
    }

    /// Full screen, or sharing the display in split view, Slide Over or a resizable window.
    enum WindowMode: String {
        case fullScreen = "full_screen"
        case multiWindow = "multi_window"
    }

    let orientation: Orientation
    let shortSide: ShortSide
    let window: WindowMode

    /// A square window is portrait, as on Android. Returns nil while either size is undefined (0).
    /// The window fills the screen when it covers it in either orientation, so a rotation that has
    /// reached one but not yet the other still counts as full screen.
    init?(windowSize: CGSize, screenSize: CGSize) {
        guard windowSize.width > 0, windowSize.height > 0 else { return nil }
        let windowSides = (min(windowSize.width, windowSize.height), max(windowSize.width, windowSize.height))
        let screenSides = (min(screenSize.width, screenSize.height), max(screenSize.width, screenSize.height))
        orientation = windowSize.width > windowSize.height ? .landscape : .portrait
        shortSide = .of(windowSides.0)
        window = windowSides.0 >= screenSides.0 - 1 && windowSides.1 >= screenSides.1 - 1 ? .fullScreen : .multiWindow
    }

    var parameters: [String: String] {
        [
            UsageParam.orientation: orientation.rawValue,
            UsageParam.screenShortSide: shortSide.rawValue,
            UsageParam.windowMode: window.rawValue,
        ]
    }
}
