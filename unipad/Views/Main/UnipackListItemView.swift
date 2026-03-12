import SwiftUI

struct UnipackListItemView: View {
    let title: String
    let subtitle: String
    let hasLed: Bool
    let hasAutoPlay: Bool
    let isBookmarked: Bool
    let isSelected: Bool
    let flagColor: Color
    var flagText: String?
    var flagExpandedWidth: CGFloat = 105
    var indicatorFontSize: CGFloat = 9
    var onTap: () -> Void
    var onPlay: () -> Void

    private let itemHeight: CGFloat = 60
    private static let animationDuration: Double = 0.5

    var body: some View {
        ZStack(alignment: .leading) {
            // Flag area
            HStack(spacing: 0) {
                UnevenRoundedRectangle(
                    topLeadingRadius: 5,
                    bottomLeadingRadius: 5,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0
                )
                    .fill(flagColor)
                    .frame(width: isSelected ? flagExpandedWidth : 10, height: itemHeight)
                    .overlay {
                        if isSelected {
                            if let flagText, !flagText.isEmpty {
                                Text(flagText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .padding(.horizontal, 4)
                            } else {
                                Button(action: onPlay) {
                                    HStack(spacing: 0) {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 24))
                                        Text("Play")
                                            .font(.system(size: 13))
                                    }
                                    .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                Spacer()
            }

            // Content area
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: isSelected ? flagExpandedWidth : 10)

                HStack(spacing: 0) {
                    if isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(AppColors.green)
                            .padding(.leading, 4)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 14))
                            .foregroundStyle(AppColors.title)
                            .lineLimit(1)

                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.subtitle)
                            .lineLimit(1)
                    }
                    .padding(.leading, isBookmarked ? 4 : 15)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 1) {
                        IndicatorLabel(text: "LED", isOn: hasLed, fontSize: indicatorFontSize)
                        IndicatorLabel(text: "AUTOPLAY", isOn: hasAutoPlay, fontSize: indicatorFontSize)
                    }
                    .padding(.trailing, 15)
                }
                .frame(height: itemHeight)
                .background(Color.white)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 5,
                        topTrailingRadius: 5
                    )
                )
            }
        }
        .frame(height: itemHeight)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .animation(.easeInOut(duration: Self.animationDuration), value: isSelected)
        .animation(.easeInOut(duration: Self.animationDuration), value: flagColor)
    }
}

private struct IndicatorLabel: View {
    let text: String
    let isOn: Bool
    var fontSize: CGFloat = 9

    var body: some View {
        Text("\(text) ●")
            .font(.system(size: fontSize))
            .foregroundStyle(isOn ? AppColors.green : AppColors.pink)
    }
}
