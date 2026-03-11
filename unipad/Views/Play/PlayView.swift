import SwiftUI

struct PlayView: View {
    let packPath: String
    @Environment(AppRouter.self) private var router
    @State private var vm = PlayViewModel()

    private var theme: ThemeResourcesProtocol { ThemeManager.shared.activeResources }

    var body: some View {
        ZStack {
            // Background
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

            if vm.startReady, let unipack = vm.unipack {
                ZStack {
                    Color.clear
                        .ignoresSafeArea()

                    GeometryReader { geometry in
                        let contentPadding: CGFloat = 8
                        let chainColumns = 2
                        let totalWidth = max(geometry.size.width - contentPadding * 2, 0)
                        let totalHeight = max(geometry.size.height - contentPadding * 2, 0)
                        let cellSize = min(
                            totalHeight / CGFloat(max(unipack.buttonX, 1)),
                            totalWidth / CGFloat(max(unipack.buttonY + chainColumns, 1))
                        )
                        let gridWidth = cellSize * CGFloat(unipack.buttonY)
                        let gridHeight = cellSize * CGFloat(unipack.buttonX)
                        let chainWidth = cellSize

                        let padX = (totalWidth - gridWidth) / 2
                        let padY = (totalHeight - gridHeight) / 2
                        let leftChainX = padX - chainWidth
                        let rightChainX = padX + gridWidth

                        ZStack(alignment: .topLeading) {
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
                                renderVersion: vm.padRenderVersion,
                                padGuideTargets: vm.padGuideTargets,
                                traceLogTexts: vm.scbTraceLog.checked ? { x, y in vm.traceLogText(x: x, y: y) } : nil,
                                onPadTouch: { x, y, isDown in vm.padTouch(x: x, y: y, isDown: isDown) }
                            )
                            .frame(width: gridWidth, height: gridHeight)
                            .offset(x: padX, y: padY)

                            ChainColumnView(
                                chainIndices: leftChainIndices,
                                chainColors: vm.chainColors,
                                chainItems: vm.chainItems,
                                visibleChainIndices: visibleChainIndices(
                                    chainCount: unipack.chain,
                                    proLightModeEnabled: vm.proLightModeEnabled
                                ),
                                cellSize: cellSize,
                                theme: theme,
                                onChainTap: { vm.selectChain($0) }
                            )
                            .frame(width: chainWidth, height: gridHeight)
                            .offset(x: leftChainX, y: padY)

                            ChainColumnView(
                                chainIndices: rightChainIndices,
                                chainColors: vm.chainColors,
                                chainItems: vm.chainItems,
                                visibleChainIndices: visibleChainIndices(
                                    chainCount: unipack.chain,
                                    proLightModeEnabled: vm.proLightModeEnabled
                                ),
                                cellSize: cellSize,
                                theme: theme,
                                onChainTap: { vm.selectChain($0) }
                            )
                            .frame(width: chainWidth, height: gridHeight)
                            .offset(x: rightChainX, y: padY)
                        }
                        .padding(contentPadding)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if !vm.scbHideUI.checked {
                        HStack {
                            sideCheckPanel
                                .frame(width: 164)
                                .padding(.leading, 10)
                                .padding(.vertical, 24)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .zIndex(30)
                    }

                    // Menu button (bottom-right)
                    if !vm.isOptionWindowVisible {
                        VStack {
                            Spacer()
                            HStack {
                                if vm.scbHideUI.checked {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            vm.scbHideUI.forceSetChecked(false)
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "sidebar.left")
                                                .font(.system(size: 15, weight: .bold))
                                            Text("UI")
                                                .font(.system(size: 13, weight: .bold))
                                        }
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .frame(height: 42)
                                        .background(.black.opacity(0.7))
                                        .overlay {
                                            Capsule().stroke(.white.opacity(0.18), lineWidth: 1)
                                        }
                                        .clipShape(Capsule())
                                    }
                                    .padding(10)
                                }
                                Spacer()
                                if !vm.scbHideUI.checked {
                                    Button {
                                        vm.toggleOptionWindow(true)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "line.3.horizontal")
                                                .font(.system(size: 15, weight: .bold))
                                            Text(String(localized: "menu"))
                                                .font(.system(size: 13, weight: .bold))
                                        }
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 14)
                                        .frame(height: 42)
                                        .background(.black.opacity(0.7))
                                        .overlay {
                                            Capsule().stroke(.white.opacity(0.18), lineWidth: 1)
                                        }
                                        .clipShape(Capsule())
                                    }
                                    .padding(10)
                                }
                            }
                        }
                        .zIndex(20)
                    }

                    // Option panel overlay
                    if vm.isOptionWindowVisible {
                        Color.black.opacity(0.5)
                            .ignoresSafeArea()
                            .onTapGesture {
                                vm.toggleOptionWindow(false)
                            }

                        HStack {
                            Spacer()
                            optionPanel
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .transition(.move(edge: .trailing))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }


            // Loading overlay
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

            // Error overlay
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
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
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
    }

    // MARK: - Back Action (matches Android BackHandler)

    private func handleBackAction() {
        withAnimation(.easeInOut(duration: 0.2)) {
            vm.toggleOptionWindow(!vm.isOptionWindowVisible)
        }
    }

    // MARK: - Chain Indices

    /// Right column: circle indices 8-15 (chains 0-7)
    private var rightChainIndices: [Int] {
        Array(PlayViewModel.chainIndexOffset..<(PlayViewModel.chainIndexOffset + PlayViewModel.topBarCount))
    }

    /// Left column: circle indices 24-31 (chains 16-23), reversed so 31 is at top
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

    // MARK: - Side Check Panel

    private var sideCheckPanel: some View {
        VStack {
            // Hide panel button
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        vm.scbHideUI.forceSetChecked(true)
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 4)

            // Performance controls
            VStack(alignment: .leading, spacing: 2) {
                Text("PERFORMANCE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.bottom, 4)
                PlayCheckBox(state: vm.scbFeedbackLight, label: String(localized: "feedbackLight"), checkboxColor: theme.checkboxColor)
                PlayCheckBox(state: vm.scbLed, label: String(localized: "led"), checkboxColor: theme.checkboxColor)
                PlayCheckBox(state: vm.scbAutoPlay, label: String(localized: "autoPlay"), checkboxColor: theme.checkboxColor)

                if vm.autoPlayControlVisible {
                    autoPlayControls
                }

                if vm.scbAutoPlay.visible && !vm.scbAutoPlay.locked && !vm.autoPlayControlVisible {
                    practiceModeButton
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.58))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Spacer()

            // Tool controls
            VStack(alignment: .leading, spacing: 2) {
                Text("TOOLS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.bottom, 4)
                PlayCheckBox(state: vm.scbTraceLog, label: String(localized: "traceLog"), checkboxColor: theme.checkboxColor)
                PlayCheckBox(state: vm.scbRecord, label: String(localized: "record"), checkboxColor: theme.checkboxColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.58))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - AutoPlay Controls

    private var autoPlayControls: some View {
        VStack(spacing: 2) {
            ProgressView(
                value: vm.autoPlayProgressMax > 0
                    ? Double(vm.autoPlayProgress) / Double(vm.autoPlayProgressMax)
                    : 0
            )
            .tint(.white)
            .frame(width: 120)

            HStack(spacing: 2) {
                Button { vm.autoPlayPrev() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)

                Button {
                    if vm.isAutoPlayPlaying { vm.autoPlayStop() }
                    else { vm.autoPlayPlay() }
                } label: {
                    Image(systemName: vm.isAutoPlayPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                }
                .frame(width: 36, height: 36)

                Button { vm.autoPlayNext() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
            }

            Button { vm.togglePracticeMode() } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(vm.isPracticeMode ? AppColors.green : .white.opacity(0.6))
                        .frame(width: 6, height: 6)
                    Text(vm.isPracticeMode ? String(localized: "practiceMode") : String(localized: "autoPlay"))
                        .font(.system(size: 10))
                        .foregroundStyle(vm.isPracticeMode ? AppColors.green : .white.opacity(0.6))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.top, 4)
    }

    private var practiceModeButton: some View {
        Button { vm.practiceStart() } label: {
            HStack(spacing: 4) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                Text(String(localized: "practiceMode"))
                    .font(.system(size: 11))
            }
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .scaleEffect(0.75, anchor: .topLeading)
    }

    // MARK: - Option Panel

    private var optionPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Title
                HStack {
                    Text(String(localized: "menu"))
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        router.pop()
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 16))
                            .foregroundStyle(Color(hex: 0xFF6B6B))
                    }
                    Button {
                        vm.toggleOptionWindow(false)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)

                Spacer().frame(height: 8)

                // UniPack info
                if let unipack = vm.unipack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(unipack.title.isEmpty ? "Untitled" : unipack.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if !unipack.producerName.isEmpty {
                            Text(unipack.producerName)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.4))
                                .lineLimit(1)
                        }

                        Spacer().frame(height: 8)

                        Text("\(unipack.buttonX)×\(unipack.buttonY)  ·  \(unipack.chain) chain")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)
                }

                Spacer().frame(height: 16)

                // Performance section
                sectionTitle("PERFORMANCE")
                OptionSwitch(state: vm.scbFeedbackLight, label: String(localized: "feedbackLight"))
                OptionSwitch(state: vm.scbLed, label: String(localized: "led"))
                OptionSwitch(state: vm.scbAutoPlay, label: String(localized: "autoPlay"))

                if vm.scbAutoPlay.visible && !vm.scbAutoPlay.locked {
                    Button {
                        vm.practiceStart()
                        vm.toggleOptionWindow(false)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.circle")
                                .font(.system(size: 14))
                            Text(String(localized: "practiceMode"))
                                .font(.system(size: 13))
                        }
                        .foregroundStyle(vm.isPracticeMode ? AppColors.blue : AppColors.textPrimary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                    }
                }

                Spacer().frame(height: 16)

                // Display section
                sectionTitle("DISPLAY")
                OptionSwitch(state: vm.scbHideUI, label: String(localized: "hideUI"))
                OptionSwitch(state: vm.scbWatermark, label: String(localized: "watermark"))
                OptionSwitch(state: vm.scbProLightMode, label: String(localized: "proLightMode"))

                Spacer().frame(height: 16)

                // Tools section
                sectionTitle("TOOLS")
                OptionSwitch(state: vm.scbTraceLog, label: String(localized: "traceLog")) {
                    vm.traceLogInit()
                }
                OptionSwitch(state: vm.scbRecord, label: String(localized: "record"))

                Spacer()

                // Quit button
                Button {
                    router.pop()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                        Text(String(localized: "quit"))
                            .font(.system(size: 15))
                    }
                    .foregroundStyle(Color(hex: 0xFF6B6B))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
            .padding(.vertical, 24)
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.optionWindowColor.opacity(0.94))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.4))
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
    }
}

// MARK: - Play CheckBox

private struct PlayCheckBox: View {
    let state: PlayViewModel.CheckBoxState
    let label: String
    var checkboxColor: Color = AppColors.checkbox

    var body: some View {
        if !state.visible { return AnyView(EmptyView()) }
        return AnyView(
            HStack(spacing: 6) {
                Circle()
                    .fill(state.checked ? checkboxColor : checkboxColor.opacity(0.25))
                    .frame(width: 10, height: 10)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(state.checked ? Color.white : Color.white.opacity(0.5))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { state.toggleChecked() }
            .onLongPressGesture(minimumDuration: 0.45) {
                state.onLongPress?()
            }
            .disabled(state.locked)
            .opacity(state.locked ? PlayViewModel.lockedAlpha : 1)
        )
    }
}

// MARK: - Option Switch

private struct OptionSwitch: View {
    let state: PlayViewModel.CheckBoxState
    let label: String
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        if !state.visible { return AnyView(EmptyView()) }
        return AnyView(
            HStack {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { state.checked },
                    set: { state.setChecked($0) }
                ))
                .tint(AppColors.orange)
                .labelsHidden()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .disabled(state.locked)
            .opacity(state.locked ? PlayViewModel.lockedAlpha : 1)
            .contentShape(Rectangle())
            .onLongPressGesture {
                onLongPress?()
            }
        )
    }
}
