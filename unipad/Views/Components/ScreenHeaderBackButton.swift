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
    /// instead of the header. A full landscape window stays put; a full window on an upright
    /// iPad reports the same corner as a resized one, so its header moves too.
    @ViewBuilder
    func avoidingWindowControls() -> some View {
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            modifier(WindowControlsAvoidance())
        } else {
            self
        }
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private struct WindowControlsAvoidance: ViewModifier {
    /// The controls take touches past the corner the system reports for them.
    private static let touchMargin: CGFloat = 8
    /// A full window reports its rounded corner, a few points wide; only the controls reach this.
    private static let smallestControlsWidth: CGFloat = 20

    @State private var cornerWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.leading, cornerWidth >= Self.smallestControlsWidth ? Self.touchMargin : 0)
            .containerCornerOffset(.leading, sizeToFit: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.containerCornerInsets.topLeading.width
            } action: { width in
                cornerWidth = width
            }
    }
}
