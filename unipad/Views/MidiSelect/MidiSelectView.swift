import SwiftUI

enum DeviceIcon {
    case asset(String)
    case system(String)
}

struct MidiSelectView: View {
    @Environment(AppRouter.self) private var router
    @State private var selectedIndex = 0
    @State private var isConnected = false
    @State private var remainingSeconds: Int?
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
            HStack(spacing: 0) {
                leftPanel
                    .frame(width: geometry.size.width * 0.35)

                deviceGrid
                    .frame(width: geometry.size.width * 0.65)
            }
        }
        .background(AppColors.background1)
        .platformNavigationBarHidden(true)
        .onAppear {
            if let activeDevice = midiDevices.first(where: { type(of: $0.makeDriver()) == type(of: MidiManager.shared.driver) }) {
                selectedIndex = activeDevice.id
            } else {
                selectedIndex = min(max(PreferenceManager.shared.launchpadConnectMethod, 0), midiDevices.count - 1)
            }
            bindMidiListener()
            isConnected = MidiManager.shared.isConnected
            startAutorunTimer()
        }
        .onDisappear {
            if MidiManager.shared.listener === midiListener {
                MidiManager.shared.listener = nil
            }
        }
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(spacing: 0) {
            Text(isConnected
                 ? String(localized: "launchpadConnecting")
                 : String(localized: "midiDevicesNotDetected"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isConnected ? AppColors.textPrimary : AppColors.red)
                .padding(.top, 20)

            Spacer().frame(height: 12)

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
                        case .system(let systemName):
                            Image(systemName: systemName)
                                .font(.system(size: 80))
                                .foregroundStyle(AppColors.blue)
                                .frame(height: 120)
                        }
                    }

                    Text(selectedDevice.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.vertical, 16)
            .animation(.easeInOut(duration: 0.3), value: selectedIndex)

            Spacer().frame(height: 16)

            Rectangle()
                .fill(AppColors.divider)
                .frame(height: 1)
                .padding(.horizontal, 20)

            Spacer()

            Button {
                cancelAutorun()
                applySelection()
                router.pop()
            } label: {
                HStack {
                    Text("OK")
                    if let seconds = remainingSeconds {
                        Text("(\(seconds))")
                            .font(.system(size: 12))
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(AppColors.blue)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(20)
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
                        cancelAutorun()
                        selectedIndex = device.id
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Actions & Autorun Timer

    private func applySelection() {
        PreferenceManager.shared.launchpadConnectMethod = selectedIndex
        if let device = midiDevices.first(where: { $0.id == selectedIndex }) {
            MidiManager.shared.overrideDriver(device.makeDriver())
        }
    }

    private func startAutorunTimer() {
        remainingSeconds = 5
        Task {
            while let seconds = remainingSeconds, seconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard remainingSeconds != nil else { break }
                remainingSeconds = (remainingSeconds ?? 0) - 1
            }
            if remainingSeconds == 0 {
                applySelection()
                router.pop()
            }
        }
    }

    private func cancelAutorun() {
        remainingSeconds = nil
    }

    private func bindMidiListener() {
        midiListener.connectedHandler = {
            isConnected = true
        }
        midiListener.disconnectedHandler = {
            isConnected = false
        }
        midiListener.driverChangeHandler = { driver in
            if let device = midiDevices.first(where: { type(of: $0.makeDriver()) == type(of: driver) }) {
                selectedIndex = device.id
            }
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
    var connectedHandler: (() -> Void)?
    var disconnectedHandler: (() -> Void)?
    var driverChangeHandler: ((MidiDriver) -> Void)?
    var logHandler: ((String) -> Void)?

    func onConnected() {
        connectedHandler?()
    }

    func onDisconnected() {
        disconnectedHandler?()
    }

    func onChangeDriver(driver: MidiDriver) {
        driverChangeHandler?(driver)
    }

    func onLog(_ message: String) {
        logHandler?(message)
    }
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
