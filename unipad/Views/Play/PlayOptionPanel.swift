import SwiftUI

struct PlayOptionPanel: View {
    let vm: PlayViewModel
    let theme: ThemeResourcesProtocol
    let onQuit: () -> Void

    @State private var infoExpanded: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer().frame(height: 8)

                // Collapsible UniPack info (reduces viewport pressure so primary controls stay near top)
                unipackInfoCollapsible

                Spacer().frame(height: 16)

                // PLAY MODE is the most frequently changed setting mid-session → promoted to top
                if vm.scbAutoPlay.visible && !vm.scbAutoPlay.locked {
                    sectionTitle(String(localized: "Play Mode"))
                    playModeSegmented
                    if let unipack = vm.unipack, unipack.autoPlayExist {
                        // Auto Mapping is conceptually tied to AutoPlay — lifted out of Tools
                        autoMappingRow
                    }
                    Spacer().frame(height: 16)
                }

                performanceSection
                Spacer().frame(height: 16)

                displaySection
                Spacer().frame(height: 16)

                toolsSection

                Spacer().frame(minHeight: 16)
                // Footer Quit removed — header is the single Quit entry point.
            }
            .padding(.vertical, 24)
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.optionWindowColor.opacity(0.94))
        // Drag-to-dismiss: swipe right on the panel closes the option window
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.width > 60 && abs(value.translation.height) < 80 {
                        vm.toggleOptionWindow(false)
                    }
                }
        )
    }

    // MARK: - Header (single Quit entry point)

    private var header: some View {
        HStack {
            Text(String(localized: "menu"))
                .font(.system(size: 22))
                .foregroundStyle(.white)
            Spacer()
            Button(action: onQuit) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 24))
                    .foregroundStyle(AppColors.playDanger)
            }
            .accessibilityLabel(Text(String(localized: "quit")))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    // MARK: - UniPack Info (collapsible)

    @ViewBuilder
    private var unipackInfoCollapsible: some View {
        if let unipack = vm.unipack {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { infoExpanded.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(unipack.title.isEmpty ? "Untitled" : unipack.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: infoExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }

                    if infoExpanded {
                        if !unipack.producerName.isEmpty {
                            Text(unipack.producerName)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                        }
                        Text("\(unipack.buttonX)×\(unipack.buttonY)  ·  \(unipack.chain) chain")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Play Mode Segmented (radio semantics made visible)

    private var playModeSegmented: some View {
        HStack(spacing: 2) {
            segmentedButton(label: String(localized: "autoPlay"), mode: .autoPlay, color: AppColors.playModeAutoPlay)
            segmentedButton(label: String(localized: "guidePlay"), mode: .guidePlay, color: AppColors.playModeGuidePlay)
            segmentedButton(label: String(localized: "stepPractice"), mode: .stepPractice, color: AppColors.playModeStepPractice)
        }
        .padding(3)
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 24)
    }

    private func segmentedButton(label: String, mode: PlayMode, color: Color) -> some View {
        let isActive = vm.playMode == mode
        return Button {
            vm.switchPlayMode(mode)
            vm.toggleOptionWindow(false)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: isActive ? .bold : .regular))
                .foregroundStyle(isActive ? Color.black : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isActive ? color : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // MARK: - AutoMapping (moved into AutoPlay context)

    @ViewBuilder
    private var autoMappingRow: some View {
        if vm.autoMappingActive {
            VStack(spacing: 6) {
                HStack {
                    Text(String(localized: "autoMapping"))
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(vm.autoMappingProgress) / \(vm.autoMappingMax)")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                ProgressView(
                    value: vm.autoMappingMax > 0
                        ? Double(vm.autoMappingProgress) / Double(vm.autoMappingMax)
                        : 0
                )
                .tint(AppColors.playAccent)
                .background(Color.white.opacity(0.15))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        } else {
            Button { vm.autoMapping() } label: {
                HStack {
                    Text(String(localized: "autoMapping"))
                        .font(.system(size: 13))
                        .foregroundStyle(AppColors.playAccent)
                    Spacer()
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 14))
                        .foregroundStyle(AppColors.playAccent.opacity(0.7))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Sections

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("PERFORMANCE")
            OptionSwitch(state: vm.scbFeedbackLight, label: String(localized: "feedbackLight"), tintColor: AppColors.playAccent)
            OptionSwitch(state: vm.scbLed, label: String(localized: "led"), tintColor: AppColors.playAccent)
            // NOTE: AutoPlay transport controls intentionally removed — the chrome column
            // on the right side is now the single source of truth for Prev/Play/Next + progress.
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("DISPLAY")
            OptionSwitch(state: vm.scbHideUI, label: String(localized: "hideUI"), tintColor: AppColors.playAccent)
            OptionSwitch(state: vm.scbWatermark, label: String(localized: "watermark"), tintColor: AppColors.playAccent)
            OptionSwitch(state: vm.scbProLightMode, label: String(localized: "proLightMode"), tintColor: AppColors.playAccent)
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("TOOLS")
            OptionSwitch(state: vm.scbTraceLog, label: String(localized: "traceLog"), tintColor: AppColors.playAccent) {
                vm.traceLogInit()
            }
            OptionSwitch(state: vm.scbRecord, label: String(localized: "record"), tintColor: AppColors.playAccent)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        // 0.65 alpha (was 0.4) — improves WCAG contrast for section labels
        Text(title.uppercased())
            .font(.system(size: 11))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.65))
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
    }
}

// MARK: - OptionSwitch

private struct OptionSwitch: View {
    let state: PlayViewModel.CheckBoxState
    let label: String
    var tintColor: Color = AppColors.playAccent
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        if !state.visible { return AnyView(EmptyView()) }
        return AnyView(
            HStack {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                Spacer()
                Toggle(label, isOn: Binding(
                    get: { state.checked },
                    set: { state.setChecked($0) }
                ))
                .tint(tintColor)
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
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(label))
        )
    }
}
