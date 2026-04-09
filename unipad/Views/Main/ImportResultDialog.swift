import SwiftUI

struct ImportResultDialog: View {
    let result: ImportResult
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            switch result {
            case .success(let unipack):
                successContent(unipack)
            case .warning(let message):
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.orange)
            case .error(let message):
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.red)
            }
        }
        .padding(16)
        .background(AppColors.darkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func successContent(_ unipack: UniPack) -> some View {
        // Title + Producer
        VStack(spacing: 2) {
            MarqueeText(
                text: unipack.title,
                font: .system(size: 18, weight: .bold),
                color: AppColors.textPrimary,
                fontSize: 18
            )

            if !unipack.producerName.isEmpty {
                MarqueeText(
                    text: unipack.producerName,
                    font: .system(size: 13),
                    color: AppColors.textSecondary
                )
            }
        }

        // 2x2 Property Grid
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                ImportPropertyBlock(
                    icon: "square.grid.3x3",
                    title: String(localized: "MPP_padSize"),
                    value: "\(unipack.buttonX) × \(unipack.buttonY)"
                )
                ImportPropertyBlock(
                    icon: "link",
                    title: String(localized: "MPP_chain"),
                    value: "\(unipack.chain)"
                )
            }
            HStack(spacing: 2) {
                ImportPropertyBlock(
                    icon: "lightbulb",
                    title: String(localized: "led"),
                    value: unipack.keyLedExist ? "ON" : "OFF"
                )
                ImportPropertyBlock(
                    icon: "music.note",
                    title: String(localized: "autoPlay"),
                    value: unipack.autoPlayExist ? "ON" : "OFF"
                )
            }
        }

        // File size
        let bytes = unipack.getByteSize()
        if bytes > 0 {
            HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.textSecondary)
                Text(String(format: "%.2f MB", Double(bytes) / 1_048_576.0))
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textSecondary)
                Spacer()
            }
        }
    }
}

private struct ImportPropertyBlock: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(AppColors.textSecondary)
                Text(value)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(AppColors.darkSurfaceHigh)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
