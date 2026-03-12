import SwiftUI

struct PlayView: View {
    let packPath: String
    @Environment(AppRouter.self) private var router
    @State private var vm = PlayViewModel()

    private var theme: ThemeResourcesProtocol { ThemeManager.shared.activeResources }

    var body: some View {
        ZStack {
            playContent
            optionWindowOverlay
            loadingOverlay
            errorOverlay
        }
        .background {
            background.ignoresSafeArea()
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
                vm.unipackLoadError = error.localizedDescription
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

    @ViewBuilder
    private var background: some View {
        if let playbg = theme.playbg {
            Image(platformImage: playbg)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }

        if let customLogo = theme.customLogo {
            VStack {
                HStack {
                    Spacer()
                    Image(platformImage: customLogo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 90)
                        .padding(.top, 16)
                        .padding(.trailing, 16)
                }
                Spacer()
            }
        }
    }

    // MARK: - Play Content

    @ViewBuilder
    private var playContent: some View {
        if vm.startReady, let unipack = vm.unipack {
            GeometryReader { geometry in
                let w = geometry.size.width
                let h = geometry.size.height
                let layout = PlayLayout(viewSize: CGSize(width: w, height: h), buttonX: unipack.buttonX, buttonY: unipack.buttonY)
                let centerX = w / 2
                let centerY = h / 2
                let padLeft = centerX - layout.gridWidth / 2

                playContentGrid(unipack: unipack, layout: layout, centerX: centerX, centerY: centerY, padLeft: padLeft)
                playContentSidePanel(layout: layout, centerY: centerY, padLeft: padLeft, viewHeight: h)
                playContentRightColumn(layout: layout, padLeft: padLeft, viewWidth: w, viewHeight: h)
            }
        }
    }

    @ViewBuilder
    private func playContentGrid(unipack: UniPack, layout: PlayLayout, centerX: CGFloat, centerY: CGFloat, padLeft: CGFloat) -> some View {
        let visibleChains = visibleChainIndices(chainCount: unipack.chain, proLightModeEnabled: vm.scbProLightMode.checked)

        ChainColumnView(
            chainIndices: leftChainIndices,
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
            traceLogTexts: vm.scbTraceLog.checked ? { x, y in vm.traceLogText(x: x, y: y) } : nil,
            traceLogColor: theme.traceLogColor,
            onPadTouch: { (x: Int, y: Int, isDown: Bool) in vm.padTouch(x: x, y: y, isDown: isDown) }
        )
        .frame(width: layout.gridWidth, height: layout.gridHeight)
        .position(x: centerX, y: centerY)

        ChainColumnView(
            chainIndices: rightChainIndices,
            chainColors: vm.chainColors,
            chainItems: vm.chainItems,
            visibleChainIndices: visibleChains,
            cellSize: layout.cellSize,
            theme: theme,
            onChainTap: { vm.selectChain($0) }
        )
        .frame(width: layout.chainWidth, height: layout.gridHeight)
        .position(x: padLeft + layout.gridWidth + layout.chainWidth / 2, y: centerY)
    }

    @ViewBuilder
    private func playContentSidePanel(layout: PlayLayout, centerY: CGFloat, padLeft: CGFloat, viewHeight: CGFloat) -> some View {
        Group {
            if layout.sidePanelWidth > 60 {
                PlaySidePanel(vm: vm, checkboxColor: theme.checkboxColor)
                    .frame(width: layout.sidePanelWidth, height: layout.gridHeight)
                    .position(
                        x: layout.sidePanelWidth / 2,
                        y: centerY
                    )
            }
        }
    }

    @ViewBuilder
    private func playContentRightColumn(layout: PlayLayout, padLeft: CGFloat, viewWidth: CGFloat, viewHeight: CGFloat) -> some View {
        if let customLogo = theme.customLogo {
            let maxLogoWidth: CGFloat = min(90, viewWidth - padLeft - layout.gridWidth - layout.chainWidth - 16)
            Image(platformImage: customLogo)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: maxLogoWidth, height: 40)
                .position(x: viewWidth - maxLogoWidth / 2 - 8, y: 28)
        }

        if vm.optionViewVisible && !vm.isOptionWindowVisible {
            menuButton
                .position(x: viewWidth - 30, y: viewHeight - 28)
        }
    }

    // MARK: - Menu & Option Overlays

    @ViewBuilder
    private var optionWindowOverlay: some View {
        if vm.isOptionWindowVisible {
            optionOverlay
        }
    }

    // MARK: - UI Elements

    private var menuButton: some View {
        Button {
            vm.toggleOptionWindow(true)
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
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

    // MARK: - Chain Indices

    private var rightChainIndices: [Int] {
        Array(PlayViewModel.chainIndexOffset..<(PlayViewModel.chainIndexOffset + PlayViewModel.topBarCount))
    }

    private var leftChainIndices: [Int] {
        Array((24...31).reversed())
    }

    private func visibleChainIndices(chainCount: Int, proLightModeEnabled: Bool) -> Set<Int> {
        if proLightModeEnabled {
            return Set(leftChainIndices + rightChainIndices)
        }
        guard chainCount > 1 else { return [] }
        let available = Set((0..<chainCount).map { $0 + PlayViewModel.chainIndexOffset })
        return Set(leftChainIndices.filter { available.contains($0) } + rightChainIndices.filter { available.contains($0) })
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

private struct PlayLayout {
    let cellSize: CGFloat
    let gridWidth: CGFloat
    let gridHeight: CGFloat
    let chainWidth: CGFloat
    let sidePanelWidth: CGFloat

    init(viewSize: CGSize, buttonX: Int, buttonY: Int) {
        let chainColumns = 2
        let totalWidth = max(viewSize.width, 0)
        let totalHeight = max(viewSize.height, 0)

        cellSize = min(
            totalHeight / CGFloat(max(buttonX, 1)),
            totalWidth / CGFloat(max(buttonY + chainColumns, 1))
        )
        gridWidth = cellSize * CGFloat(buttonY)
        gridHeight = cellSize * CGFloat(buttonX)
        chainWidth = cellSize

        let horizontalPadding = (totalWidth - gridWidth - chainWidth * 2) / 2
        sidePanelWidth = min(164, max(horizontalPadding - 16, 0))
    }
}
