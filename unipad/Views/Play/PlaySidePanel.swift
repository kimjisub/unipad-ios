import SwiftUI

struct PlaySidePanel: View {
    let vm: PlayViewModel
    let checkboxColor: Color
    var compactLayout: Bool = false

    var body: some View {
        VStack(spacing: compactLayout ? 12 : 0) {
            performanceSection

            if !compactLayout {
                Spacer()
            }

            toolsSection
        }
    }

    // MARK: - Sections

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            PlayCheckBox(state: vm.scbFeedbackLight, label: String(localized: "feedbackLight"), checkboxColor: checkboxColor)
            PlayCheckBox(state: vm.scbLed, label: String(localized: "led"), checkboxColor: checkboxColor)

            if vm.scbAutoPlay.visible && !vm.scbAutoPlay.locked {
                playModeSelector
            }

            if vm.autoPlayControlVisible {
                transportControls
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            PlayCheckBox(state: vm.scbTraceLog, label: String(localized: "traceLog"), checkboxColor: checkboxColor)
            PlayCheckBox(state: vm.scbRecord, label: String(localized: "record"), checkboxColor: checkboxColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - AutoPlay Controls

    private var playModeSelector: some View {
        VStack(spacing: 2) {
            playModeButton(label: String(localized: "autoPlay"), mode: .autoPlay, accentColor: checkboxColor)
            playModeButton(label: String(localized: "guidePlay"), mode: .guidePlay, accentColor: Color(red: 0.31, green: 0.76, blue: 0.97))
            playModeButton(label: String(localized: "stepPractice"), mode: .stepPractice, accentColor: Color(red: 0.4, green: 0.73, blue: 0.42))
        }
        .padding(.top, 4)
    }

    private func playModeButton(label: String, mode: PlayMode, accentColor: Color) -> some View {
        let isActive = vm.playMode == mode
        return Button { vm.switchPlayMode(mode) } label: {
            HStack(spacing: 4) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12))
                Text(label)
                    .font(.system(size: 11, weight: isActive ? .bold : .regular))
            }
            .foregroundStyle(isActive ? accentColor : .white.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accentColor.opacity(isActive ? 0.2 : 0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var transportControls: some View {
        VStack(spacing: 2) {
            ProgressView(
                value: vm.autoPlayProgressMax > 0
                    ? Double(vm.autoPlayProgress) / Double(vm.autoPlayProgressMax)
                    : 0
            )
            .tint(checkboxColor)
            .background(Color.white.opacity(0.15))
            .frame(width: 120, height: 3)

            HStack(spacing: 2) {
                Button { vm.autoPlayPrev() } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)

                Button {
                    if vm.isAutoPlayPlaying { vm.autoPlayPause() }
                    else { vm.autoPlayResume() }
                } label: {
                    Image(systemName: vm.isAutoPlayPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                }
                .frame(width: 36, height: 36)

                Button { vm.autoPlayNext() } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - PlayCheckBox

struct PlayCheckBox: View {
    let state: PlayViewModel.CheckBoxState
    let label: String
    var checkboxColor: Color = AppColors.checkbox

    var body: some View {
        if !state.visible { return AnyView(EmptyView()) }
        return AnyView(
            HStack(spacing: 6) {
                Circle()
                    .fill(state.checked ? checkboxColor : checkboxColor.opacity(0.25))
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(state.checked ? Color.white : Color.white.opacity(0.5))
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
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
