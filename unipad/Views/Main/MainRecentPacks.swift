import SwiftUI

/// Packs the user has played on this device, newest first. Only packs with a recorded
/// play and no load error qualify, so a library that was never played shows nothing.
enum MainRecentPacks {
    static let maxCount = 3

    static func select(from items: [UniPackItem], limit: Int = maxCount) -> [UniPackItem] {
        let played = items.compactMap { item -> (UniPackItem, Date)? in
            guard !item.unipack.criticalError, let lastOpenedAt = item.lastOpenedAt else { return nil }
            return (item, lastOpenedAt)
        }
        return played
            .sorted { $0.1 > $1.1 }
            .prefix(max(limit, 0))
            .map(\.0)
    }
}

struct MainRecentPacksSection: View {
    let items: [UniPackItem]
    var onSelect: (UniPackItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "MPP_lastPlayed"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColors.textPrimary)
                .accessibilityAddTraits(.isHeader)

            ForEach(items) { item in
                Button {
                    onSelect(item)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.textPrimary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.unipack.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                            Text(item.unipack.producerName)
                                .font(.system(size: 10))
                                .foregroundStyle(AppColors.textPrimary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppColors.darkSurfaceHigh)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("main.recentPack")
            }
        }
    }
}
