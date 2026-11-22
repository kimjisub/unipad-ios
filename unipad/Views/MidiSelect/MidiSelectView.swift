import SwiftUI

enum DeviceIcon {
    case asset(String)
    case system(String)
}

struct MidiSelectView: View {
    @Environment(AppRouter.self) private var router
    @ObservedObject private var midiManager = MidiManager.shared
    @State private var selection = MidiSelectState()
    @AccessibilityFocusState private var helpButtonFocused: Bool
    /// Advanced when the quiet period after a connection ends, so the status can say so.
    @State private var now = Date()

    private var selectedIndex: Int { selection.selectedIndex }
    private var remainingSeconds: Int? { selection.remainingSeconds }
    private var status: MidiConnectionStatus { MidiConnectionStatus(midiManager.connectionReport, now: now) }
    @State private var midiListener = MidiSelectListener()

    private let midiDevices: [MidiDevice] = [
        MidiDevice(id: 0, name: String(localized: "midi_lp_s"), icon: .asset("midi_lp_s"), makeDriver: { LaunchpadSDriver() }),
        MidiDevice(id: 1, name: String(localized: "midi_lp_mk2"), icon: .asset("midi_lp_mk2"), makeDriver: { LaunchpadMK2Driver() }),
        MidiDevice(id: 2, name: String(localized: "midi_lp_pro"), icon: .asset("midi_lp_pro"), makeDriver: { LaunchpadProDriver() }),
        MidiDevice(id: 3, name: String(localized: "midi_lp_x"), icon: .asset("midi_lp_x"), makeDriver: { LaunchpadXDriver() }),
        MidiDevice(id: 4, name: String(localized: "midi_lp_mini_mk3"), icon: .asset("midi_lp_mini_mk3"), makeDriver: { LaunchpadMiniMK3Driver() }),
        MidiDevice(id: 5, name: String(localized: "midi_lp_mk3"), icon: .asset("midi_lp_mk3"), makeDriver: { LaunchpadProMK3Driver() }),
        MidiDevice(id: 6, name: String(localized: "midi_midi_fighter"), icon: .asset("midi_midifighter"), makeDriver: { MidiFighterDriver() }),
        MidiDevice(id: 7, name: String(localized: "midi_matrix"), icon: .asset("midi_matrix"), makeDriver: { MatrixDriver() }),
        MidiDevice(id: 8, name: String(localized: "midi_master_keyboard"), icon: .system("pianokeys"), makeDriver: { MasterKeyboardDriver() }),
        // Appended last: launchpadConnectMethod persists the position in this array, so
        // inserting in the middle would shift every existing user's saved selection.
        MidiDevice(id: 9, name: String(localized: "midi_lp_pro_cfw"), icon: .asset("midi_lp_pro"), makeDriver: { LaunchpadProCFWDriver() }),
        MidiDevice(id: 10, name: String(localized: "midi_lp_core_cfw"), icon: .asset("midi_lp_pro"), makeDriver: { LaunchpadCoreCFWDriver() }),
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                HStack(spacing: 0) {
                    leftPanel
                        .frame(width: geometry.size.width * 0.35)
                    deviceGrid
                        .frame(width: geometry.size.width * 0.65)
                }
                .disabled(selection.isHelpPresented)
                .accessibilityHidden(selection.isHelpPresented)

                if selection.isHelpPresented {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                    MidiConnectionHelpView(
                        statusTitle: status.title,
                        modelName: midiDevices.first(where: { $0.id == selectedIndex })?.name ?? "",
                        modelSource: status.isConnected ? selection.modelSource : nil,
                        firstQuestion: status.firstHelpQuestion(customFirmware: midiManager.connectionReport.customFirmware)
                    ) {
                        selection.isHelpPresented = false
                        // Restore focus after the selection controls are visible
                        // in the accessibility tree again.
                        DispatchQueue.main.async {
                            helpButtonFocused = true
                        }
                    }
#if DEBUG || UNIPAD_RELEASE_TESTS
                    .onAppear { ReleaseTestSupport.soundLoadGate?.connectionHelpAppeared() }
#endif
                }
            }
        }
        .background(AppColors.background1)
        .platformNavigationBarHidden(true)
        .onAppear {
            if !selection.hasStartedAutorun {
                if MidiManager.shared.isConnected {
                    showModel(of: MidiManager.shared.driver)
                } else {
                    selection.restoreModel(min(max(PreferenceManager.shared.launchpadConnectMethod, 0), midiDevices.count - 1))
                }
            }
            bindMidiListener()
            startAutorunTimer()
        }
        .onChange(of: status) { _, newStatus in
            selection.statusChanged(to: newStatus)
            if let announcement = newStatus.announcement {
                AccessibilityNotification.Announcement(announcement).post()
            }
        }
        .task(id: midiManager.connectionReport) {
            now = Date()
            guard case .waiting(_, longWait: false) = status,
                  let connectedAt = midiManager.connectionReport.connectedAt else { return }
            let remaining = MidiConnectionStatus.quietPeriod - now.timeIntervalSince(connectedAt)
            try? await Task.sleep(for: .seconds(max(remaining, 0)))
            if !Task.isCancelled { now = Date() }
        }
        .onDisappear {
            cancelAutorun()
            if MidiManager.shared.listener === midiListener {
                MidiManager.shared.listener = nil
            }
        }
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    statusBox
                        .accessibilitySortPriority(3)
                    devicePreview
                        .accessibilitySortPriority(1)
                }
            }
            .frame(maxHeight: .infinity)

            VStack(spacing: 8) {
                Button {
                    helpButtonFocused = false
                    selection.openHelp()
                } label: {
                    Text(MidiHelpText.text("midi_help_title"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppColors.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("midi.help.open")
                .accessibilityFocused($helpButtonFocused)
                // Read right after the status it explains, before the model shown above it.
                .accessibilitySortPriority(2)

                Button {
                    cancelAutorun()
                    applySelection()
                    router.pop()
                } label: {
                    HStack {
                        Text(String(localized: "settings_ok"))
                        if let seconds = remainingSeconds {
                            Text("(\(seconds))")
                                .font(.caption)
                        }
                    }
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(AppColors.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityIdentifier("midi.confirm")
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .contain)
    }

    private var statusBox: some View {
        let status = self.status
        let dotColor: Color = switch status.tone {
        case .problem: AppColors.red
        case .attention: AppColors.orange
        case .neutral: AppColors.textSecondary
        case .received: AppColors.green
        }
        let tags = status.tags(customFirmware: midiManager.connectionReport.customFirmware)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(status.tone == .problem ? AppColors.red : AppColors.white)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if status.tone == .received {
                        Image(systemName: "checkmark")
                            .accessibilityHidden(true)
                    }
                    Text(status.nextStep)
                }
                .font(.footnote)
                .foregroundStyle(status.tone == .received ? AppColors.green : AppColors.textPrimary)
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .foregroundStyle(AppColors.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(Capsule().stroke(AppColors.orange, lineWidth: 1))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(AppColors.darkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("midi.status")
    }

    private var devicePreview: some View {
        VStack(spacing: 0) {
            // Selected device preview
            VStack(spacing: 8) {
                if let selectedDevice = midiDevices.first(where: { $0.id == selectedIndex }) {
                    Group {
                        switch selectedDevice.icon {
                        case .asset(let name):
                            Image(name)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityHidden(true)
                        case .system(let systemName):
                            Image(systemName: systemName)
                                .font(.system(size: 80))
                                .foregroundStyle(AppColors.blue)
                                .frame(height: 120)
                                .accessibilityHidden(true)
                        }
                    }

                    Text(selectedDevice.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    if status.isConnected, let source = selection.modelSource {
                        Text(source.text)
                            .font(.caption)
                            .foregroundStyle(AppColors.textPrimary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .overlay(Capsule().stroke(AppColors.divider, lineWidth: 1))
                            .accessibilityIdentifier("midi.model.source")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .animation(.easeInOut(duration: 0.3), value: selectedIndex)

            Spacer().frame(height: 16)

            Rectangle()
                .fill(AppColors.divider)
                .frame(height: 1)
                .padding(.horizontal, 20)
        }
    }

    // MARK: - Device Grid

    private var deviceGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 12)],
                spacing: 12
            ) {
                ForEach(midiDevices) { device in
                    DeviceCardView(
                        device: device,
                        isSelected: device.id == selectedIndex
                    ) {
                        selection.selectModel(device.id)
                    }
                }
            }
            .padding(16)
        }
        .accessibilityIdentifier("midi.models")
    }

    // MARK: - Actions & Autorun Timer

    private func applySelection() {
        PreferenceManager.shared.launchpadConnectMethod = selectedIndex
        if let device = midiDevices.first(where: { $0.id == selectedIndex }) {
            MidiManager.shared.overrideDriver(device.makeDriver())
        }
    }

    private func startAutorunTimer() {
        guard selection.startAutorun(for: status) else { return }
        Task {
            while let seconds = remainingSeconds, seconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                if selection.tickAutorun() {
                    applySelection()
                    router.pop()
                }
            }
        }
    }

    private func cancelAutorun() {
        selection.cancelAutorun()
    }

    /// Shows the model the connected device runs on and where that choice came from.
    private func showModel(of driver: MidiDriver) {
        let manager = MidiManager.shared
        guard manager.isConnected else {
            selection.deviceLeft()
            return
        }
        let device = midiDevices.first(where: { type(of: $0.makeDriver()) == type(of: driver) })?.id
        if !manager.connectionReport.isModelRecognised {
            selection.unrecognisedModel(device)
        } else if manager.isDriverDetected || device == nil {
            selection.detectedModel(device)
        } else {
            selection.earlierChoice(device!)
        }
    }

    private func bindMidiListener() {
        midiListener.driverChangeHandler = { driver in
            showModel(of: driver)
        }
        MidiManager.shared.listener = midiListener
    }
}

// MARK: - Data

struct MidiDevice: Identifiable {
    let id: Int
    let name: String
    let icon: DeviceIcon
    let makeDriver: () -> MidiDriver
}

private final class MidiSelectListener: MidiManagerListener {
    var driverChangeHandler: ((MidiDriver) -> Void)?

    func onConnected() {}

    func onDisconnected() {}

    func onChangeDriver(driver: MidiDriver) {
        driverChangeHandler?(driver)
    }

    func onLog(_ message: String) {}
}

// MARK: - Device Card

private struct DeviceCardView: View {
    let device: MidiDevice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                switch device.icon {
                case .asset(let name):
                    Image(name)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 48)
                        .opacity(isSelected ? 1.0 : 0.6)
                case .system(let systemName):
                    Image(systemName: systemName)
                        .font(.system(size: 34))
                        .foregroundStyle(isSelected ? AppColors.blue : AppColors.textPrimary.opacity(0.6))
                        .frame(height: 48)
                }

                Text(device.name)
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(minHeight: 30)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(isSelected ? AppColors.darkSurface : AppColors.darkSurfaceHigh)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? AppColors.blue : .clear, lineWidth: 2)
            )
            .animation(.easeInOut(duration: 0.3), value: isSelected)
        }
    }
}

#Preview {
    MidiSelectView()
        .environment(AppRouter())
        .preferredColorScheme(.dark)
}
