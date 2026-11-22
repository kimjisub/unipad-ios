import SwiftUI

/// The back chevron of a screen that hides the navigation bar, where it is the only way out.
/// Its tappable area is grown to at least 44pt around the glyph while the negative padding
/// keeps the layout exactly where the glyph is. Beside the window controls of a resized
/// window the controls take the part of that area that lies over them, not the glyph.
struct ScreenHeaderBackButton: View {
    private static let hitOutset: CGFloat = 16

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .foregroundStyle(AppColors.textPrimary)
                .padding(Self.hitOutset)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .padding(-Self.hitOutset)
        .padding(.trailing, 4)
    }
}

extension View {
    /// Keeps a header drawn at the top of a screen clear of the window controls iPadOS 26
    /// puts in a resized window's top leading corner, where a touch would reach them
    /// instead of the header. A window that fills the screen has no such controls and stays put,
    /// though on an upright iPad it reports the same corner as a resized one.
    @ViewBuilder
    func avoidingWindowControls() -> some View {
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            modifier(WindowControlsAvoidance())
        } else {
            self
        }
    }

    /// Moves a column that starts in a screen's top leading corner down below the window
    /// controls of a resized window, for content that would wrap or overflow if narrowed beside
    /// them. Apply it to a view whose top leading corner stays put, such as a whole column.
    @ViewBuilder
    func belowWindowControls() -> some View {
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            modifier(WindowControlsClearanceBelow())
        } else {
            self
        }
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private enum WindowControlsCorner {
    /// A window without controls reports its rounded corner, a few points wide, unless it stands
    /// upright; only the controls reach this.
    static let smallestControlsWidth: CGFloat = 20
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private struct WindowControlsClearanceBelow: ViewModifier {
    @Environment(\.windowFillsScreen) private var windowFillsScreen
    @State private var corner = CGSize.zero

    func body(content: Content) -> some View {
        content
            .padding(.top, !windowFillsScreen && corner.width >= WindowControlsCorner.smallestControlsWidth ? corner.height : 0)
            // Measured outside the padding, whose corner does not move with it.
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.containerCornerInsets.topLeading
            } action: { size in
                corner = size
            }
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private struct WindowControlsAvoidance: ViewModifier {
    /// The controls take touches past the corner the system reports for them.
    private static let touchMargin: CGFloat = 8

    @Environment(\.windowFillsScreen) private var windowFillsScreen
    @State private var cornerWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.leading, !windowFillsScreen && cornerWidth >= WindowControlsCorner.smallestControlsWidth ? Self.touchMargin : 0)
            .containerCornerOffset(windowFillsScreen ? [] : .leading, sizeToFit: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.containerCornerInsets.topLeading.width
            } action: { width in
                cornerWidth = width
            }
    }
}
