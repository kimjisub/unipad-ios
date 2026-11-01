#if os(iOS)
import SwiftUI
import UIKit

/// Reports the `ScreenLayout` of the window this view sits in whenever it is shown, rotated or
/// resized. It measures the app's window against its screen, not the device.
///
/// The app requires full screen (`UIRequiresFullScreen`), so iPadOS 18 and earlier never share the
/// display with it. Newer iPadOS windowing still lets a person resize its window, but then reports
/// the screen at the window's size too (seen on iPadOS 27), so such a window counts as full screen;
/// its orientation and short side still follow the window.
struct WindowLayoutReader: View {
    let onChange: (ScreenLayout?) -> Void

    var body: some View {
        WindowObserver { window in
            guard let screen = window.windowScene?.screen else { return }
            onChange(ScreenLayout(windowSize: window.bounds.size, screenSize: screen.bounds.size))
        }
    }
}

/// Calls `onChange` with this view's window whenever the view is shown, rotated or resized.
struct WindowObserver: UIViewRepresentable {
    let onChange: (UIWindow) -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    /// A resize of the window resizes this view too, which lays it out again.
    final class ObserverView: UIView {
        var onChange: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        private func report() {
            guard let window else { return }
            onChange?(window)
        }
    }
}
#endif
