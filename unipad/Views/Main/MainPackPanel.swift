import SwiftUI

struct MainPackPanel: View {
    let item: UniPackItem
    var onBookmarkToggle: () -> Void
    var onDelete: () -> Void
    var onYouTube: () -> Void
    var onWebsite: (() -> Void)?

    private var unipack: UniPack { item.unipack }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "-" }
        return Self.dateFormatter.string(from: date)
    }

    private var fileSizeString: String {
        let bytes = unipack.getByteSize()
        guard bytes > 0 else { return "" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white)

            VStack(alignment: .leading, spacing: 0) {
                // Header: bookmark + delete
                HStack {
                    Button(action: onBookmarkToggle) {
                        Image(systemName: item.isBookmarked ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 16))
                            .foregroundStyle(Color(hex: 0x555555))
                    }
                    .frame(width: 40, height: 40)

                    Spacer()

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 16))
                            .foregroundStyle(Color(hex: 0x555555))
                    }
                    .frame(width: 40, height: 40)
                }

                // Title
                MarqueeText(
                    text: unipack.title,
                    font: .system(size: 16),
                    color: Color(hex: 0x1A1A1A),
                    fontSize: 16
                )

                // Producer + action buttons
                HStack {
                    MarqueeText(
                        text: unipack.producerName,
                        font: .system(size: 12),
                        color: Color(hex: 0x666666)
                    )

                    Spacer()

                    Button(action: onYouTube) {
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(Color(hex: 0x555555))
                    }
                    .frame(width: 32, height: 32)

                    if let onWebsite, unipack.website != nil {
                        Button(action: onWebsite) {
                            Image(systemName: "globe")
                                .foregroundStyle(Color(hex: 0x555555))
                        }
                        .frame(width: 32, height: 32)
                    }
                }

                Spacer().frame(height: 8)

                // Stats: play count + dates
                HStack(alignment: .center) {
                    VStack {
                        Text(String(localized: "MPP_playCount"))
                            .font(.system(size: 10))
                            .foregroundStyle(Color(hex: 0x888888))
                        Text("\(item.openCount)")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color(hex: 0x1A1A1A))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        DateRow(
                            label: String(localized: "MPP_downloadedDate"),
                            value: formatDate(item.createdAt)
                        )
                        DateRow(
                            label: String(localized: "MPP_lastPlayed"),
                            value: formatDate(item.lastOpenedAt)
                        )
                    }
                }

                Spacer().frame(height: 8)

                // 2x2 property grid
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        PropertyBlock(
                            icon: "square.grid.3x3",
                            title: String(localized: "MPP_padSize"),
                            value: "\(unipack.buttonX) × \(unipack.buttonY)"
                        )
                        PropertyBlock(
                            icon: "link",
                            title: String(localized: "MPP_chain"),
                            value: "\(unipack.chain)"
                        )
                    }
                    HStack(spacing: 2) {
                        PropertyBlock(
                            icon: "music.note",
                            title: String(localized: "MPP_soundFiles"),
                            value: unipack.detailLoaded ? "\(unipack.soundCount)" : String(localized: "measuring")
                        )
                        PropertyBlock(
                            icon: "lightbulb",
                            title: String(localized: "MPP_ledEvents"),
                            value: unipack.detailLoaded ? "\(unipack.ledTableCount)" : String(localized: "measuring")
                        )
                    }
                }

                Spacer()

                // File size
                if !fileSizeString.isEmpty {
                    HStack {
                        Spacer()
                        Text(fileSizeString)
                            .font(.system(size: 10))
                            .foregroundStyle(Color(hex: 0x888888))
                    }
                }
            }
            .padding(16)
        }
    }
}

private struct DateRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color(hex: 0x888888))
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(Color(hex: 0x333333))
        }
    }
}

private struct PropertyBlock: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Color(hex: 0x888888))
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: 0x888888))
                Text(value)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(hex: 0x1A1A1A))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(hex: 0xF2F2F2))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
