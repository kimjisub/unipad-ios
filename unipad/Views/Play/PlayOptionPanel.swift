import SwiftUI

struct PlayOptionPanel: View {
    let vm: PlayViewModel
    let theme: ThemeResourcesProtocol
    let onQuit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer().frame(height: 8)
                unipackInfo
                Spacer().frame(height: 16)

                performanceSection
                Spacer().frame(height: 16)

                displaySection
                Spacer().frame(height: 16)

                toolsSection

                Spacer()

                quitButton
            }
            .padding(.vertical, 24)
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.optionWindowColor.opacity(0.94))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(String(localized: "menu"))
                .font(.system(size: 22))
                .foregroundStyle(.white)
            Spacer()
            Button(action: onQuit) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 24))
                    .foregroundStyle(Color(hex: 0xFF6B6B))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    // MARK: - UniPack Info

    @ViewBuilder
    private var unipackInfo: some View {
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
    }

    // MARK: - Sections

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("PERFORMANCE")
            OptionSwitch(state: vm.scbFeedbackLight, label: String(localized: "feedbackLight"), tintColor: Color(hex: 0xE8A44A))
            OptionSwitch(state: vm.scbLed, label: String(localized: "led"), tintColor: Color(hex: 0xE8A44A))

            if vm.scbAutoPlay.visible && !vm.scbAutoPlay.locked {
                optionModeButton(label: String(localized: "autoPlay"), mode: .autoPlay, accentColor: Color(hex: 0xE8A44A))
                optionModeButton(label: String(localized: "guidePlay"), mode: .guidePlay, accentColor: Color(red: 0.31, green: 0.76, blue: 0.97))
                optionModeButton(label: String(localized: "stepPractice"), mode: .stepPractice, accentColor: Color(red: 0.4, green: 0.73, blue: 0.42))
            }

            if vm.autoPlayControlVisible {
                optionTransportControls
            }
        }
    }

    private var optionTransportControls: some View {
        VStack(spacing: 8) {
            ProgressView(
                value: vm.autoPlayProgressMax > 0
                    ? Double(vm.autoPlayProgress) / Double(vm.autoPlayProgressMax)
                    : 0
            )
            .tint(Color(hex: 0xE8A44A))
            .background(Color.white.opacity(0.15))

            HStack(spacing: 16) {
                Button { vm.autoPlayPrev() } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }

                Button {
                    if vm.isAutoPlayPlaying { vm.autoPlayPause() }
                    else { vm.autoPlayResume() }
                } label: {
                    Image(systemName: vm.isAutoPlayPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                }

                Button { vm.autoPlayNext() } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func optionModeButton(label: String, mode: PlayMode, accentColor: Color) -> some View {
        let isActive = vm.playMode == mode
        return Button {
            vm.switchPlayMode(mode)
            vm.toggleOptionWindow(false)
        } label: {
            HStack {
                Text(label)
                    .font(.system(size: 14, weight: isActive ? .bold : .regular))
                    .foregroundStyle(isActive ? accentColor : .white)
                Spacer()
                Image(systemName: isActive ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(isActive ? accentColor : .white.opacity(0.5))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("DISPLAY")
            OptionSwitch(state: vm.scbHideUI, label: String(localized: "hideUI"), tintColor: Color(hex: 0xE8A44A))
            OptionSwitch(state: vm.scbWatermark, label: String(localized: "watermark"), tintColor: Color(hex: 0xE8A44A))
            OptionSwitch(state: vm.scbProLightMode, label: String(localized: "proLightMode"), tintColor: Color(hex: 0xE8A44A))
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("TOOLS")
            OptionSwitch(state: vm.scbTraceLog, label: String(localized: "traceLog"), tintColor: Color(hex: 0xE8A44A)) {
                vm.traceLogInit()
            }
            OptionSwitch(state: vm.scbRecord, label: String(localized: "record"), tintColor: Color(hex: 0xE8A44A))
            autoMappingButton
        }
    }

    @ViewBuilder
    private var autoMappingButton: some View {
        if vm.autoMappingActive {
            VStack(spacing: 6) {
                HStack {
                    Text(String(localized: "autoMapping"))
                        .font(.system(size: 14))
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
                .tint(Color(hex: 0xE8A44A))
                .background(Color.white.opacity(0.15))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        } else {
            Button {
                vm.autoMapping()
            } label: {
                HStack {
                    Text(String(localized: "autoMapping"))
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }
        }
    }

    private var quitButton: some View {
        Button(action: onQuit) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 20))
                Text(String(localized: "quit"))
                    .font(.system(size: 15))
            }
            .foregroundStyle(Color(hex: 0xFF6B6B))
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
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

// MARK: - OptionSwitch

private struct OptionSwitch: View {
    let state: PlayViewModel.CheckBoxState
    let label: String
    var tintColor: Color = Color(hex: 0xE8A44A)
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
        )
    }
}
