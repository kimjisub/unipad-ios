import SwiftUI

struct ChainColumnView: View {
    let chainIndices: [Int]
    let chainColors: [Color]
    let chainItems: [ChannelManager.Item?]
    let visibleChainIndices: Set<Int>
    let cellSize: CGFloat
    let theme: ThemeResourcesProtocol
    let onChainTap: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                ForEach(chainIndices, id: \.self) { index in
                    if visibleChainIndices.contains(index) {
                        ChainButtonView(
                            color: index < chainColors.count ? chainColors[index] : .clear,
                            chainItem: index < chainItems.count ? chainItems[index] : nil,
                            theme: theme,
                            onTap: { onChainTap(index - PlayViewModel.chainIndexOffset) }
                        )
                        .frame(width: cellSize, height: cellSize)
                    } else {
                        Color.clear
                            .frame(width: cellSize, height: cellSize)
                    }
                }
            }
            .frame(width: cellSize, height: cellSize * CGFloat(chainIndices.count), alignment: .center)
            Spacer(minLength: 0)
        }
    }
}

private struct ChainButtonView: View {
    let color: Color
    let chainItem: ChannelManager.Item?
    let theme: ThemeResourcesProtocol
    let onTap: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                // Background (btn image in chainLed mode)
                if theme.isChainLed, let btn = theme.btn {
                    Image(platformImage: btn)
                        .resizable()
                        .frame(width: size - 2, height: size - 2)
                }

                // LED color overlay (chainLed mode only)
                if theme.isChainLed, color != .clear {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.7))
                        .frame(width: size - 2, height: size - 2)
                }

                // Phantom overlay (chainled image)
                if theme.isChainLed, let chainled = theme.chainled {
                    Image(platformImage: chainled)
                        .resizable()
                        .frame(width: size - 2, height: size - 2)
                } else if !theme.isChainLed, let chainImage = chainImageForDrawableMode() {
                    Image(platformImage: chainImage)
                        .resizable()
                        .frame(width: size - 2, height: size - 2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    private func chainImageForDrawableMode() -> PlatformImage? {
        guard let item = chainItem else { return theme.chain }
        switch item.channel {
        case .guide:
            return theme.chainGuide ?? theme.chain
        case .chain:
            return theme.chainSelected ?? theme.chain
        default:
            return theme.chain
        }
    }
}
