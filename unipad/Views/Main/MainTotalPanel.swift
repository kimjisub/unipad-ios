import SwiftUI

struct MainTotalPanel: View {
    let openCount: Int
    let unipackCount: Int?
    let unipackCapacity: String?
    let themeName: String?
    let updateAvailable: Bool
    let recentPacks: [UniPackItem]
    var onRecentPackClick: (UniPackItem) -> Void
    var onUpdateClick: () -> Void

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Short screens drop recent packs one at a time rather than clipping the stats.
    var body: some View {
        ViewThatFits(in: .vertical) {
            ForEach((0...recentPacks.count).reversed(), id: \.self) { shown in
                content(recentPacks: Array(recentPacks.prefix(shown)))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppColors.darkSurface)
        )
    }

    private func content(recentPacks: [UniPackItem]) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // Logo + version
            VStack(spacing: 8) {
                Image("UniPadIconTextIntro")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 48)

                Text(versionString)
                    .font(.system(size: 10))
                    .foregroundStyle(AppColors.textPrimary)
            }

            Spacer().frame(height: 12)

            // Stats
            VStack(spacing: 8) {
                StatRow(label: String(localized: "MPT_playCount"), value: "\(openCount)", valueIdentifier: "main.total.playCount")
                StatRow(label: String(localized: "MTP_count"), value: unipackCount.map(String.init) ?? "-")
                StatRow(
                    label: String(localized: "MTP_size"),
                    value: unipackCapacity.map { "\($0) MB" } ?? "-"
                )
                if let themeName {
                    StatRow(label: String(localized: "MPT_theme"), value: themeName)
                }
            }
            .padding(12)
            .background(AppColors.darkSurfaceHigh)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Spacer(minLength: 12)

            if !recentPacks.isEmpty {
                MainRecentPacksSection(items: recentPacks, onSelect: onRecentPackClick)
            }

            if updateAvailable {
                HStack {
                    Text(String(localized: "update_available"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColors.blue)
                        .onTapGesture(perform: onUpdateClick)
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    var valueIdentifier: String?

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .accessibilityIdentifier(valueIdentifier ?? "")
        }
    }
}
