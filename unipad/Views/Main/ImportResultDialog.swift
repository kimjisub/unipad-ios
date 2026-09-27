import SwiftUI

/// The card shown after a UniPack import: status, pack summary and its buttons.
///
/// The caller draws the dimmed backdrop and closes the card when it is tapped; this view
/// only places the card inside the space it is given. The middle scrolls when it is taller
/// than the room left, so the buttons always stay on screen.
struct ImportResultDialog: View {
    let result: ImportResult
    let onDismiss: () -> Void
    let onPlayNow: (UniPack) -> Void
    /// Where the strings come from; tests pass a single language's `.lproj` bundle.
    var bundle: Bundle = .main

    static let maxWidth: CGFloat = 480
    static let screenMargin: CGFloat = 24
    static let verticalMargin: CGFloat = 16

    static func cardWidth(in available: CGSize) -> CGFloat {
        min(maxWidth, available.width - screenMargin * 2)
    }

    static func cardMaxHeight(in available: CGSize) -> CGFloat {
        available.height - verticalMargin * 2
    }

    var body: some View {
        GeometryReader { proxy in
            card
                .frame(width: Self.cardWidth(in: proxy.size))
                .frame(maxHeight: Self.cardMaxHeight(in: proxy.size))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var card: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
            }
            footer
        }
        .background(AppColors.darkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppColors.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 16, y: 12)
        .accessibilityAddTraits(.isModal)
    }

    private func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            status
            switch result {
            case .success(let unipack):
                packSummary(unipack)
            case .warning(let message), .error(let message):
                messageBox(message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding([.horizontal, .top], 20)
    }

    private var status: some View {
        let (icon, color, key): (String, Color, String) = switch result {
        case .success: ("checkmark.circle.fill", AppColors.green, "importComplete")
        case .warning: ("exclamationmark.triangle.fill", AppColors.orange, "warning")
        case .error: ("xmark.circle.fill", AppColors.red, "importFailed")
        }
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .accessibilityHidden(true)
            Text(text(key))
                .font(.system(size: 13, weight: .semibold))
                .accessibilityIdentifier("main.importResult.title")
                .accessibilityAddTraits(.isHeader)
        }
        .foregroundStyle(color)
    }

    @ViewBuilder
    private func packSummary(_ unipack: UniPack) -> some View {
        Text(unipack.title)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(AppColors.white)
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
            .accessibilityIdentifier("main.importResult.packTitle")

        if !unipack.producerName.isEmpty {
            Text(unipack.producerName)
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 2)
        }

        FlowLayout(spacing: 6) {
            ForEach(chips(for: unipack)) { chip in
                ImportInfoChip(chip: chip)
            }
        }
        .padding(.top, 14)
    }

    private func chips(for unipack: UniPack) -> [ImportInfoChip.Model] {
        let padSize = "\(unipack.buttonX) × \(unipack.buttonY)"
        let chain = "\(text("MPP_chain")) \(unipack.chain)"
        var chips: [ImportInfoChip.Model] = [
            .init(icon: "square.grid.3x3.fill", text: padSize, spokenText: "\(text("MPP_padSize")) \(padSize)"),
            .init(icon: "link", text: chain, spokenText: chain),
        ]
        if unipack.keyLedExist {
            chips.append(.init(icon: "lightbulb", text: text("led"), spokenText: text("led")))
        }
        if unipack.autoPlayExist {
            chips.append(.init(icon: "music.note", text: text("autoPlay"), spokenText: text("autoPlay")))
        }
        let bytes = unipack.getByteSize()
        if bytes > 0 {
            let size = String(format: "%.2f MB", Double(bytes) / 1_048_576.0)
            chips.append(.init(icon: "internaldrive", text: size, spokenText: size))
        }
        return chips
    }

    private func messageBox(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundStyle(AppColors.textPrimary)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AppColors.background1)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.top, 12)
    }

    // MARK: - Buttons

    private var footer: some View {
        Group {
            if let unipack = result.playablePack {
                let play = ImportResultPrimaryButton(title: text("import_play_now")) { onPlayNow(unipack) }
                // Side by side when Play now fits on one line; otherwise Play now on top.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        okButton(fillsWidth: false)
                        play
                    }
                    VStack(spacing: 10) {
                        play
                        okButton(fillsWidth: true)
                    }
                }
            } else {
                okButton(fillsWidth: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 20)
    }

    private func okButton(fillsWidth: Bool) -> some View {
        ImportResultSecondaryButton(title: text("import_result_ok"), fillsWidth: fillsWidth, action: onDismiss)
    }
}

struct ImportResultSecondaryButton: View {
    let title: String
    let fillsWidth: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 20)
                .frame(minWidth: 96, maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
                .background(AppColors.darkSurfaceHigh)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("main.importResult.ok")
    }
}

struct ImportResultPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(AppColors.background1)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(AppColors.orange)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("main.importResult.playNow")
    }
}

/// A small pill with an icon and a short fact about the imported pack.
struct ImportInfoChip: View {
    struct Model: Identifiable {
        let icon: String
        let text: String
        /// What VoiceOver reads, e.g. "Pad Size 8 × 8" for the "8 × 8" chip.
        let spokenText: String
        var id: String { icon }
    }

    let chip: Model

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: chip.icon)
                .font(.system(size: 11))
                .foregroundStyle(AppColors.textSecondary)
            Text(chip.text)
                .font(.system(size: 12))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 24)
        .background(AppColors.darkSurfaceHigh)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chip.spokenText)
    }
}

/// Lays children out left to right and wraps to a new line when the next one does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
