#if os(iOS)
import SwiftUI
import UIKit

/// Reports the `ScreenLayout` of the window this view sits in whenever it is shown, rotated or
/// resized. It measures the app's window against its screen, not the device, so split view, Slide
/// Over and resizable windows on iPad count as sharing the display.
struct WindowLayoutReader: UIViewRepresentable {
    let onChange: (ScreenLayout?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    /// A resize of the window resizes this view too, which lays it out again.
    final class ReaderView: UIView {
        var onChange: ((ScreenLayout?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        private func report() {
            guard let window, let screen = window.windowScene?.screen else { return }
            onChange?(ScreenLayout(windowSize: window.bounds.size, screenSize: screen.bounds.size))
        }
    }
}
#endif
