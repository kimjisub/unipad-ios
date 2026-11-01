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

#if os(iOS)
private struct WindowFillsScreenPublisher: ViewModifier {
    @State private var fillsScreen = false

    func body(content: Content) -> some View {
        content
            .environment(\.windowFillsScreen, fillsScreen)
            .background(
                WindowObserver { window in
                    let fills = Self.fills(window)
                    guard fills != fillsScreen else { return }
                    // These callbacks can arrive while SwiftUI is updating the view that hosts this one.
                    DispatchQueue.main.async { fillsScreen = fills }
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
        let layout = ScreenLayout(windowSize: window.bounds.size, screenSize: UIScreen.main.bounds.size)
        return origin == .zero && layout?.window == .fullScreen
    }
}
#endif
