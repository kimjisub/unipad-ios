import SwiftUI

/// Shown when bookmarks and play counts are on a temporary in-memory store, so an empty
/// bookmark list is not mistaken for data the user lost or for changes that are being kept.
struct TemporaryStoreNoticeView: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.orange)

            Text(String(localized: "temporary_store_notice"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColors.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel(String(localized: "temporary_store_notice_dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppColors.darkSurfaceHigh)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(AppColors.orange.opacity(0.6), lineWidth: 1)
        )
        .frame(maxWidth: 560)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
    }
}
