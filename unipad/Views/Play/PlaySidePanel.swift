import SwiftUI

struct PlaySidePanel: View {
    let vm: PlayViewModel
    let checkboxColor: Color

    var body: some View {
        VStack(spacing: 0) {
            performanceSection

            Spacer()

            toolsSection
        }
    }

    // MARK: - Sections

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            PlayCheckBox(state: vm.scbFeedbackLight, label: String(localized: "feedbackLight"), checkboxColor: checkboxColor)
            PlayCheckBox(state: vm.scbLed, label: String(localized: "led"), checkboxColor: checkboxColor)
            PlayCheckBox(state: vm.scbAutoPlay, label: String(localized: "autoPlay"), checkboxColor: checkboxColor)

            if vm.autoPlayControlVisible {
                autoPlayControls
            }

            if vm.scbAutoPlay.visible && !vm.scbAutoPlay.locked && !vm.autoPlayControlVisible {
                practiceModeButton
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

    private var autoPlayControls: some View {
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
                    if vm.isAutoPlayPlaying { vm.autoPlayStop() }
                    else { vm.autoPlayPlay() }
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
                    .font(.system(size: 14))
                Text(String(localized: "practiceMode"))
                    .font(.system(size: 13))
            }
            .foregroundStyle(checkboxColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .scaleEffect(0.75, anchor: .topLeading)
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
