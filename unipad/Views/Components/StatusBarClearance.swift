import SwiftUI

extension View {
    /// Keeps this screen below the status bar, which takes every touch inside its band.
    ///
    /// iPadOS normally reserves that band in the top safe area. With an iPad held upright, the
    /// full-size window of this landscape-only app gets a top safe area shorter than the band
    /// (10pt under a 32pt bar on iPadOS 27), so a control laid out by the safe area alone can
    /// sit where touches never reach the app.
    @ViewBuilder
    func clearingStatusBar() -> some View {
        #if os(iOS)
        modifier(StatusBarClearance())
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct StatusBarClearance: ViewModifier {
    @State private var overlap: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.top, overlap)
            .background(StatusBarOverlapReader { overlap = $0 })
    }
}

/// Reports how far the status bar reaches below the top safe area of this view's window.
private struct StatusBarOverlapReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

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

    final class ReaderView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private var reported: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        private func report() {
            guard let window, let statusBar = window.windowScene?.statusBarManager else { return }
            let overlap = max(0, statusBar.statusBarFrame.maxY - window.safeAreaInsets.top)
            guard overlap != reported else { return }
            reported = overlap
            // These callbacks can arrive while SwiftUI is updating the view that hosts this one.
            DispatchQueue.main.async { [onChange] in onChange?(overlap) }
        }
    }
}
#endif
