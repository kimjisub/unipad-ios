import SwiftUI

struct MainTotalPanel: View {
    let openCount: Int
    let unipackCount: Int?
    let unipackCapacity: String?
    let themeName: String?
    let updateAvailable: Bool
    var onSettingsClick: () -> Void
    var onUpdateClick: () -> Void

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

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
                StatRow(label: String(localized: "MPT_playCount"), value: "\(openCount)")
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

            Spacer()

            // Bottom row: update + settings
            HStack {
                if updateAvailable {
                    Text(String(localized: "update_available"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColors.blue)
                        .onTapGesture(perform: onUpdateClick)
                }
                Spacer()
                Button(action: onSettingsClick) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20))
                        .foregroundStyle(AppColors.textPrimary)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppColors.darkSurface)
        )
    }
}

private struct StatRow: View {
    let label: String
    let value: String

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
        }
    }
}
