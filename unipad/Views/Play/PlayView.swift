import SwiftUI

struct PlayView: View {
    let packPath: String
    @Environment(AppRouter.self) private var router
    @State private var vm = PlayViewModel()
    @AppStorage(PreferenceManager.Keys.traceLogClassic) private var traceLogClassic = false

    private var theme: ThemeResourcesProtocol { ThemeManager.shared.activeResources }

    private let chromeStripWidth: CGFloat = 56

    var body: some View {
        ZStack {
            playContent
            optionWindowOverlay
            loadingOverlay
            errorOverlay
        }
        .background {
            Color.black.ignoresSafeArea()
        }
        .platformNavigationBarHidden(true)
        #if canImport(UIKit)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #endif
        .alert(String(localized: "warning"), isPresented: Binding(
            get: { vm.unipackWarning != nil },
            set: { if !$0 { vm.unipackWarning = nil } }
        )) {
            Button(String(localized: "accept"), role: .cancel) {
                vm.unipackWarning = nil
            }
        } message: {
            Text(vm.unipackWarning ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast = vm.toastMessage {
                Text(toast)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.75))
                    .clipShape(Capsule())
                    .padding(.bottom, 40)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .onAppear {
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            withAnimation { vm.toastMessage = nil }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.toastMessage)
        .onKeyPress(.escape) {
            handleBackAction()
            return .handled
        }
        .onChange(of: vm.quitRequested) { _, quit in
            if quit { router.pop() }
        }
        .onAppear {
            ThemeManager.shared.reloadActiveTheme()
            if let themeError = ThemeManager.shared.lastLoadError {
                vm.toastMessage = themeError
                ThemeManager.shared.lastLoadError = nil
            }
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
        }
        .task {
            do {
                try await vm.loadUnipack(path: packPath)
            } catch {
                vm.onLoadFailed(error)
            }
        }
        .onDisappear {
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
            vm.cleanup()
        }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            vm.onPause()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            vm.onResume()
        }
        #endif
    }

    // MARK: - Background

    /// The theme image centred on the pads, so the body it paints in the middle sits under them.
    /// The pads keep to the safe area, which ends above the home indicator, so this centre is a
    /// little above the screen's and the image grows just enough to still cover the screen.
    /// It is drawn from the same layout while the pack loads, so it holds still when the pads appear.
    private func themeBody(_ playbg: PlatformImage, layout: PlayLayout, in geometry: GeometryProxy) -> some View {
        let insets = geometry.safeAreaInsets
        let size = PlayLayout.coverSize(
            of: playbg.size,
            centredOn: CGPoint(x: layout.padCenterX + insets.leading, y: layout.padCenterY + insets.top),
            in: CGSize(width: geometry.size.width + insets.leading + insets.trailing, height: geometry.size.height + insets.top + insets.bottom)
        )
        return Image(platformImage: playbg)
            .resizable()
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .accessibilityIdentifier("playBackground")
            .position(x: layout.padCenterX, y: layout.padCenterY)
    }

    // MARK: - Play Content

    private var playContent: some View {
        // The reader keeps to the safe area, so the pads, menu and logo stay clear of the notch
        // and the home indicator.
        GeometryReader { geometry in
            let showAllSides = vm.scbProLightMode.checked
            let layout = playLayout(for: vm.unipack, in: geometry)

            if let playbg = theme.playbg {
                themeBody(playbg, layout: layout, in: geometry)
            }
            if vm.startReady, let unipack = vm.unipack {
                let padLeft = layout.padCenterX - layout.gridWidth / 2
                playContentGrid(unipack: unipack, layout: layout, centerX: layout.padCenterX, centerY: layout.padCenterY, padLeft: padLeft, showAllSides: showAllSides)
                playContentRightColumn(layout: layout, padLeft: padLeft, viewWidth: geometry.size.width, viewHeight: geometry.size.height, centerY: geometry.size.height / 2)
            }
        }
    }

    /// Lays out `unipack`'s pads, or an 8x8 pack's until the pack has been read.
    private func playLayout(for unipack: UniPack?, in geometry: GeometryProxy) -> PlayLayout {
        // Android shows the bottom row whenever the pack has more than 8 chains; here
        // chains 9-16 were unreachable on screen without Pro Light Mode.
        let showBottomRow = vm.scbProLightMode.checked || (unipack?.chain ?? 0) > PlayViewModel.chainIndexOffset
        return PlayLayout(viewSize: geometry.size, buttonX: unipack?.buttonX ?? 8, buttonY: unipack?.buttonY ?? 8, showAllSides: showBottomRow, reservedWidth: chromeStripWidth, safeAreaInsets: geometry.safeAreaInsets)
    }

    @ViewBuilder
    private func playContentGrid(unipack: UniPack, layout: PlayLayout, centerX: CGFloat, centerY: CGFloat, padLeft: CGFloat, showAllSides: Bool) -> some View {
        let visibleChains = visibleChainIndices(chainCount: unipack.chain, proLightModeEnabled: vm.scbProLightMode.checked)
        let padTop = centerY - layout.gridHeight / 2

        let top = topIndices
        let right = rightIndices
        let bottom = bottomIndices
        let left = leftIndices

        if showAllSides {
            ChainBarView(
                axis: .horizontal,
                chainIndices: top,
                chainColors: vm.chainColors,
                chainItems: vm.chainItems,
                visibleChainIndices: visibleChains,
                cellSize: layout.cellSize,
                theme: theme,
                onChainTap: { vm.selectChain($0) }
            )
            .frame(width: layout.gridWidth, height: layout.chainHeight)
            .position(x: centerX, y: padTop - layout.chainHeight / 2)
        }

        ChainBarView(
            axis: .vertical,
            chainIndices: left,
            chainColors: vm.chainColors,
            chainItems: vm.chainItems,
            visibleChainIndices: visibleChains,
            cellSize: layout.cellSize,
            theme: theme,
            onChainTap: { vm.selectChain($0) }
        )
        .frame(width: layout.chainWidth, height: layout.gridHeight)
        .position(x: padLeft - layout.chainWidth / 2, y: centerY)

        PadGridView(
            columns: unipack.buttonY,
            rows: unipack.buttonX,
            isSquareButton: unipack.squareButton,
            padColors: vm.padColors,
            padLedColors: vm.padLedColors,
            padItems: vm.padItems,
            btnImage: theme.btn,
            btnPressedImage: theme.btnPressed,
            phantomImage: theme.phantom,
            phantomVariantImage: theme.phantomVariant,
            padGuideTargets: vm.padGuideTargets,
            traceLogSequence: vm.scbTraceLog.checked && vm.chain.value >= 0 && vm.chain.value < vm.traceLogSequence.count ? vm.traceLogSequence[vm.chain.value] : nil,
            traceLogColor: theme.traceLogColor,
            traceLogClassic: traceLogClassic,
            onPadTouch: { (x: Int, y: Int, isDown: Bool) in vm.padTouch(x: x, y: y, isDown: isDown) }
        )
        .frame(width: layout.gridWidth, height: layout.gridHeight)
        .accessibilityIdentifier("playPadGrid")
        .position(x: centerX, y: centerY)

        ChainBarView(
            axis: .vertical,
            chainIndices: right,
            chainColors: vm.chainColors,
            chainItems: vm.chainItems,
            visibleChainIndices: visibleChains,
            cellSize: layout.cellSize,
            theme: theme,
            onChainTap: { vm.selectChain($0) }
        )
        .frame(width: layout.chainWidth, height: layout.gridHeight)
        .position(x: padLeft + layout.gridWidth + layout.chainWidth / 2, y: centerY)

        if showAllSides || unipack.chain > PlayViewModel.chainIndexOffset {
            ChainBarView(
                axis: .horizontal,
                chainIndices: bottom,
                chainColors: vm.chainColors,
                chainItems: vm.chainItems,
                visibleChainIndices: visibleChains,
                cellSize: layout.cellSize,
                theme: theme,
                onChainTap: { vm.selectChain($0) }
            )
            .frame(width: layout.gridWidth, height: layout.chainHeight)
            .position(x: centerX, y: padTop + layout.gridHeight + layout.chainHeight / 2)
        }
    }

    @ViewBuilder
    private func playContentRightColumn(layout: PlayLayout, padLeft: CGFloat, viewWidth: CGFloat, viewHeight: CGFloat, centerY: CGFloat) -> some View {
        // "Hide UI" (optionViewVisible) was written by the view model and read nowhere; it hides
        // the logo and the chrome column, as Android and web do.
        if vm.optionViewVisible, let customLogo = theme.customLogo {
            let maxLogoWidth: CGFloat = max(0, min(90, viewWidth - padLeft - layout.gridWidth - layout.chainWidth - chromeStripWidth - 16))
            Image(platformImage: customLogo)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: maxLogoWidth, height: 40)
                .position(x: viewWidth - chromeStripWidth - maxLogoWidth / 2 - 8, y: 28)
                .accessibilityIdentifier("playLogo")
        }

        if !vm.isOptionWindowVisible && vm.optionViewVisible {
            chromeColumn
                .position(x: viewWidth - chromeStripWidth / 2, y: centerY)
        }
    }

    // MARK: - Chrome Column (Right-side unified chrome: Menu + Transport + Progress)

    private var chromeColumn: some View {
        let showTransport = vm.autoPlayControlVisible
        let progress: Double = vm.autoPlayProgressMax > 0
            ? Double(vm.autoPlayProgress) / Double(vm.autoPlayProgressMax)
            : 0

        return VStack(spacing: 6) {
            Button {
                vm.toggleOptionWindow(true)
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }

            if showTransport {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 24, height: 2)
                    .padding(.vertical, 6)

                Button { vm.autoPlayPrev() } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }

                Button {
                    if vm.isAutoPlayPlaying { vm.autoPlayPause() }
                    else { vm.autoPlayResume() }
                } label: {
                    Image(systemName: vm.isAutoPlayPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }

                Button { vm.autoPlayNext() } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }

                // Vertical progress (fills top -> bottom)
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 3, height: 72)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.checkboxColor)
                        .frame(width: 3, height: 72 * max(0, min(1, progress)))
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .animation(.easeInOut(duration: 0.2), value: showTransport)
    }

    // MARK: - Menu & Option Overlays

    @ViewBuilder
    private var optionWindowOverlay: some View {
        if vm.isOptionWindowVisible {
            optionOverlay
        }
    }

    private var optionOverlay: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeIn(duration: 0.2)),
                    removal: .opacity.animation(.easeOut(duration: 0.3))
                ))
                .onTapGesture {
                    vm.toggleOptionWindow(false)
                }
            PlayOptionPanel(
                vm: vm,
                theme: theme,
                onQuit: { router.pop() }
            )
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).animation(.easeOut(duration: 0.3)),
                removal: .move(edge: .trailing).animation(.easeIn(duration: 0.25))
            ))
        }
    }

    // MARK: - Loading / Error Overlays

    @ViewBuilder
    private var loadingOverlay: some View {
        if vm.unipackLoading || vm.soundLoadingActive {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                LoadingView(
                    phase: loadingPhaseLabel,
                    progress: loadingProgress,
                    detail: loadingDetail
                )
            }
        }
    }

    @ViewBuilder
    private var errorOverlay: some View {
        if let error = vm.unipackLoadError {
            ZStack {
                Color.black.opacity(0.7).ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button {
                        router.pop()
                    } label: {
                        Text(String(localized: "quit"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(Color(hex: 0xFF6B6B))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    // MARK: - Back Action

    private func handleBackAction() {
        vm.toggleOptionWindow(!vm.isOptionWindowVisible)
    }

    // MARK: - Chain Indices (상→우→하→좌, 0-31)

    private var topIndices: [Int] { Array(0..<8) }
    private var rightIndices: [Int] { Array(8..<16) }
    private var bottomIndices: [Int] { Array((16...23).reversed()) }
    private var leftIndices: [Int] { Array((24...31).reversed()) }

    private func visibleChainIndices(chainCount: Int, proLightModeEnabled: Bool) -> Set<Int> {
        if proLightModeEnabled {
            return Set(0..<PlayViewModel.circleArraySize)
        }
        guard chainCount > 1 else { return [] }
        let available = Set((0..<chainCount).map { $0 + PlayViewModel.chainIndexOffset })
        return Set((rightIndices + bottomIndices + leftIndices).filter { available.contains($0) })
    }

    // MARK: - Loading Helpers

    private var loadingPhaseLabel: String {
        if vm.soundLoadingActive {
            return String(localized: "loading_phase_audio")
        }
        switch vm.loadingPhase {
        case "info": return String(localized: "loading_phase_info")
        case "keySound": return String(localized: "loading_phase_keysound")
        case "keyLed": return String(localized: "loading_phase_keyled")
        case "autoPlay": return String(localized: "loading_phase_autoplay")
        default: return String(localized: "loading")
        }
    }

    private var loadingProgress: Double {
        if vm.soundLoadingActive {
            return vm.soundLoadingMax > 0
                ? Double(vm.soundLoadingProgress) / Double(vm.soundLoadingMax)
                : 0
        }
        return vm.loadingPhaseTotal > 0
            ? Double(vm.loadingPhaseIndex) / Double(vm.loadingPhaseTotal)
            : 0
    }

    private var loadingDetail: String? {
        if vm.soundLoadingActive {
            return "\(loadingPhaseLabel) (\(vm.soundLoadingProgress)/\(vm.soundLoadingMax))"
        }
        return nil
    }
}

// MARK: - Layout Calculation

struct PlayLayout {
    let cellSize: CGFloat
    let gridWidth: CGFloat
    let gridHeight: CGFloat
    let chainWidth: CGFloat
    let chainHeight: CGFloat
    /// The pad grid sits on the screen's centre line, like Android, and in the middle of the safe
    /// area's height, clear of the home indicator. It moves left only as far as needed to keep the
    /// right chain column clear of the trailing strip reserved for the menu. Both are in
    /// `viewSize`'s coordinates, the safe area, which the screen overhangs by `safeAreaInsets`.
    let padCenterX: CGFloat
    let padCenterY: CGFloat

    init(viewSize: CGSize, buttonX: Int, buttonY: Int, showAllSides: Bool = false, reservedWidth: CGFloat = 0, safeAreaInsets: EdgeInsets = EdgeInsets()) {
        let chainColumns = 2
        let chainRows = showAllSides ? 2 : 0
        let totalWidth = max(viewSize.width - reservedWidth, 0)
        let totalHeight = max(viewSize.height, 0)

        cellSize = min(
            totalHeight / CGFloat(max(buttonX + chainRows, 1)),
            totalWidth / CGFloat(max(buttonY + chainColumns, 1))
        )
        gridWidth = cellSize * CGFloat(buttonY)
        gridHeight = cellSize * CGFloat(buttonX)
        chainWidth = cellSize
        chainHeight = cellSize
        let screenCenterX = (viewSize.width + safeAreaInsets.trailing - safeAreaInsets.leading) / 2
        padCenterX = min(screenCenterX, viewSize.width - reservedWidth - chainWidth - gridWidth / 2)
        padCenterY = viewSize.height / 2
    }

    /// The size at which an image of `imageSize`, centred on `center`, covers all of `screenSize`
    /// without being stretched.
    static func coverSize(of imageSize: CGSize, centredOn center: CGPoint, in screenSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return screenSize }
        let halfWidth = max(center.x, screenSize.width - center.x)
        let halfHeight = max(center.y, screenSize.height - center.y)
        let scale = max(halfWidth * 2 / imageSize.width, halfHeight * 2 / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}
