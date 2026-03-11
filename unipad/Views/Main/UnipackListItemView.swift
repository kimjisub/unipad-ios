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
    var onTap: () -> Void
    var onPlay: () -> Void

    private let itemHeight: CGFloat = 60
    private static let animationDuration: Double = 0.5

    var body: some View {
        ZStack(alignment: .leading) {
            // Flag area
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(flagColor)
                    .frame(width: isSelected ? 105 : 10, height: itemHeight)
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
                                    HStack(spacing: 4) {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 14))
                                        Text("Play")
                                            .font(.system(size: 13))
                                    }
                                    .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                    .animation(.easeInOut(duration: Self.animationDuration), value: isSelected)

                Spacer()
            }

            // Content area
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: isSelected ? 105 : 10)
                    .animation(.easeInOut(duration: Self.animationDuration), value: isSelected)

                HStack(spacing: 0) {
                    if isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 12))
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
                        IndicatorLabel(text: "LED", isOn: hasLed)
                        IndicatorLabel(text: "AUTOPLAY", isOn: hasAutoPlay)
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
    }
}

private struct IndicatorLabel: View {
    let text: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 2) {
            Text("\(text) ")
                .font(.system(size: 9))
            Text("●")
                .font(.system(size: 6))
        }
        .foregroundStyle(isOn ? AppColors.green : AppColors.pink)
    }
}
