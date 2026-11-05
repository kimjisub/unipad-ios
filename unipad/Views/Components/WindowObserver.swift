#if os(iOS)
import SwiftUI
import UIKit

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
