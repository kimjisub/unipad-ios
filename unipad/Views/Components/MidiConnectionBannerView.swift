import SwiftUI

struct MidiConnectionBannerView: View {
    let message: String
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "pianokeys.inverse")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(String(localized: "midi_open_panel"), action: onOpen)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.blue)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 24, height: 24)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.88))
        .clipShape(Capsule())
        .padding(.horizontal, 20)
    }
}
