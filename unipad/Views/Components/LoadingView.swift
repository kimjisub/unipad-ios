import SwiftUI

struct LoadingView: View {
    var phase: String = ""
    var progress: Double = 0
    var detail: String?

    var body: some View {
        VStack(spacing: 16) {
            Text(String(localized: "loading"))
                .font(.headline)
                .foregroundStyle(.white)

            ProgressView(value: progress, total: 1.0)
                .tint(AppColors.skyblue)
                .frame(maxWidth: .infinity)

            if !phase.isEmpty {
                Text(detail ?? phase)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textPrimary)
            }
        }
        .padding(24)
        .frame(width: 280)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
