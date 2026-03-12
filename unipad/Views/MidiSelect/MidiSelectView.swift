import SwiftUI

struct MidiSelectView: View {
    @Environment(AppRouter.self) private var router
    @State private var selectedIndex = 0
    @State private var isConnected = false
    @State private var logText = ""
    @State private var remainingSeconds: Int?
    @State private var midiListener = MidiSelectListener()

    private let midiDevices: [MidiDevice] = [
        MidiDevice(name: String(localized: "midi_lp_s"), icon: "pianokeys", makeDriver: { LaunchpadSDriver() }),
        MidiDevice(name: String(localized: "midi_lp_mk2"), icon: "square.grid.3x3", makeDriver: { LaunchpadMK2Driver() }),
        MidiDevice(name: String(localized: "midi_lp_pro"), icon: "square.grid.3x3.fill", makeDriver: { LaunchpadProDriver() }),
        MidiDevice(name: String(localized: "midi_lp_x"), icon: "square.grid.3x3.topleft.filled", makeDriver: { LaunchpadXDriver() }),
        MidiDevice(name: String(localized: "midi_lp_mini_mk3"), icon: "square.grid.3x3.middle.filled", makeDriver: { LaunchpadMiniMK3Driver() }),
        MidiDevice(name: String(localized: "midi_lp_mk3"), icon: "square.grid.3x3.bottomright.filled", makeDriver: { LaunchpadProMK3Driver() }),
        MidiDevice(name: String(localized: "midi_midi_fighter"), icon: "dial.medium", makeDriver: { MidiFighterDriver() }),
        MidiDevice(name: String(localized: "midi_matrix"), icon: "rectangle.grid.3x2", makeDriver: { MatrixDriver() }),
        MidiDevice(name: String(localized: "midi_master_keyboard"), icon: "pianokeys.inverse", makeDriver: { MasterKeyboardDriver() }),
    ]

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
                .frame(maxWidth: .infinity)
                .layoutPriority(1.5)

            deviceGrid
                .frame(maxWidth: .infinity)
                .layoutPriority(3)
        }
        .background(AppColors.background1)
        .platformNavigationBarHidden(true)
        .onAppear {
            selectedIndex = PreferenceManager.shared.launchpadConnectMethod
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
                Image(systemName: midiDevices[selectedIndex].icon)
                    .font(.system(size: 120))
                    .foregroundStyle(AppColors.blue)
                    .contentTransition(.symbolEffect(.replace))

                Text(midiDevices[selectedIndex].name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 16)
            .animation(.easeInOut(duration: 0.3), value: selectedIndex)

            Spacer().frame(height: 16)

            Rectangle()
                .fill(AppColors.divider)
                .frame(height: 1)
                .padding(.horizontal, 20)

            Spacer()

            if !logText.isEmpty {
                Rectangle()
                    .fill(AppColors.divider)
                    .frame(height: 1)
                    .padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Log")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppColors.textPrimary)

                    ScrollView {
                        Text(logText)
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 80)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }

            Button {
                cancelAutorun()
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
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                spacing: 12
            ) {
                ForEach(Array(midiDevices.enumerated()), id: \.element.name) { index, device in
                    DeviceCardView(
                        device: device,
                        isSelected: index == selectedIndex
                    ) {
                        cancelAutorun()
                        selectedIndex = index
                        PreferenceManager.shared.launchpadConnectMethod = index
                        MidiManager.shared.overrideDriver(midiDevices[index].makeDriver())
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Autorun Timer

    private func startAutorunTimer() {
        remainingSeconds = 5
        Task {
            while let seconds = remainingSeconds, seconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard remainingSeconds != nil else { break }
                remainingSeconds = (remainingSeconds ?? 0) - 1
            }
            if remainingSeconds == 0 {
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
        midiListener.logHandler = { message in
            logText += message + "\n"
        }
        midiListener.driverChangeHandler = { driver in
            if let index = midiDevices.firstIndex(where: { type(of: $0.makeDriver()) == type(of: driver) }) {
                selectedIndex = index
            }
        }
        MidiManager.shared.listener = midiListener
    }
}

// MARK: - Data

struct MidiDevice {
    let name: String
    let icon: String
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
                Image(systemName: device.icon)
                    .font(.system(size: 48))
                    .foregroundStyle(isSelected ? AppColors.blue : AppColors.textPrimary.opacity(0.6))

                Text(device.name)
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
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
