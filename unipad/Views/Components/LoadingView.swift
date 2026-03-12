import SwiftUI

struct LoadingView: View {
    var phase: String = ""
    var progress: Double = 0
    var detail: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(String(localized: "loading"))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            Spacer().frame(height: 16)

            ProgressView(value: progress, total: 1.0)
                .tint(Color(hex: 0x4FC3F7))
                .background(Color(hex: 0x333333))
                .frame(maxWidth: .infinity, maxHeight: 6)

            Spacer().frame(height: 12)

            if !phase.isEmpty {
                Text(detail ?? phase)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xCCCCCC))
            }
        }
        .padding(24)
        .frame(width: 280)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
