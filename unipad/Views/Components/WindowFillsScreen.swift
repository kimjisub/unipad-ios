import SwiftUI

extension EnvironmentValues {
    /// Whether this view's window covers the whole display. Stays false where that is unknown.
    @Entry var windowFillsScreen = false
}

extension View {
    /// Publishes `windowFillsScreen` to everything below this view, which has to be as large as
    /// its window so that any resize reaches it.
    @ViewBuilder
    func publishingWindowFillsScreen() -> some View {
        #if os(iOS)
        modifier(WindowFillsScreenPublisher())
        #else
        self
        #endif
    }
}

enum WindowFit {
    /// Half-point rounding, on either side.
    private static let tolerance: CGFloat = 1

    /// The window has to be the display's size, not just reach it: a window on a larger external
    /// display can outgrow the iPad's display and still have window controls. Either orientation
    /// counts, so a rotation that has reached one of the two sizes still fills the display.
    static func fillsDisplay(windowFrame: CGRect, displaySize: CGSize) -> Bool {
        guard windowFrame.origin == .zero else { return false }
        let window = sides(of: windowFrame.size)
        let display = sides(of: displaySize)
        return abs(window.short - display.short) <= tolerance && abs(window.long - display.long) <= tolerance
    }

    private static func sides(of size: CGSize) -> (short: CGFloat, long: CGFloat) {
        (min(size.width, size.height), max(size.width, size.height))
    }
}

#if os(iOS)
private struct WindowFillsScreenPublisher: ViewModifier {
    @State private var fillsScreen = false

    func body(content: Content) -> some View {
        content
            .environment(\.windowFillsScreen, fillsScreen)
            .background(
                WindowObserver { window in
                    // These callbacks can arrive while SwiftUI is updating the view that hosts this one.
                    DispatchQueue.main.async { fillsScreen = Self.fills(window) }
                }
            )
    }

    /// A resizable window sees its scene's screen at its own size (seen on iPadOS 27), so the
    /// whole display can only be read from `UIScreen.main`. A window that fills it also sits at
    /// the origin of the scene's screen, which keeps a resized window out even if a system
    /// reports the main screen at the window's size too.
    private static func fills(_ window: UIWindow) -> Bool {
        guard let scene = window.windowScene else { return false }
        let origin = window.convert(CGPoint.zero, to: scene.screen.coordinateSpace)
        return WindowFit.fillsDisplay(
            windowFrame: CGRect(origin: origin, size: window.bounds.size),
            displaySize: UIScreen.main.bounds.size
        )
    }
}
#endif
