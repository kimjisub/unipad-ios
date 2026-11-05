import SwiftUI

/// The top of a screen that hides the navigation bar: the back chevron, the title, and any
/// actions at the far end. Beside the window controls of a narrow window even the smallest
/// title size leaves long words cut off, so the title moves to a row of its own under the
/// chevron, where the whole panel width is free. Everywhere else it sits beside the chevron.
struct ScreenHeader<Actions: View>: View {
    let title: String
    let titleLineLimit: Int
    let onBack: () -> Void
    @ViewBuilder let actions: () -> Actions

    @State private var titleHasOwnRow = false

    init(
        _ title: String,
        titleLineLimit: Int = 1,
        onBack: @escaping () -> Void,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.titleLineLimit = titleLineLimit
        self.onBack = onBack
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ScreenHeaderBackButton(action: onBack)

                if !titleHasOwnRow {
                    titleText
                }

                Spacer(minLength: 0)

                actions()
            }
            .avoidingWindowControls()

            if titleHasOwnRow {
                titleText
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .reportingNarrowHeader { titleHasOwnRow = $0 }
        .padding(.bottom, 24)
    }

    private var titleText: some View {
        Text(title)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(AppColors.textPrimary)
            .lineLimit(titleLineLimit)
            .minimumScaleFactor(0.5)
    }
}

extension ScreenHeader where Actions == EmptyView {
    init(_ title: String, titleLineLimit: Int = 1, onBack: @escaping () -> Void) {
        self.init(title, titleLineLimit: titleLineLimit, onBack: onBack) { EmptyView() }
    }
}

private extension View {
    /// Tells `action` whether the window controls leave too little of this header's width for
    /// a title beside the chevron. A phone or a window as wide as the screen never gets there.
    @ViewBuilder
    func reportingNarrowHeader(_ action: @escaping (Bool) -> Void) -> some View {
        // Below this much width beside the controls, a long title would shrink past reading.
        let narrowWidth: CGFloat = 120
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width - proxy.containerCornerInsets.topLeading.width < narrowWidth
            } action: { isNarrow in
                action(isNarrow)
            }
        } else {
            self
        }
    }
}
