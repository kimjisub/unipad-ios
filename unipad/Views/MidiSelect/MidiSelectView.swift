import SwiftUI

struct MidiSelectView: View {
    @Environment(AppRouter.self) private var router
    @State private var selectedIndex = 0
    @State private var isConnected = false
    @State private var logText = ""
    @State private var remainingSeconds: Int?

    private let midiDevices: [MidiDevice] = [
        MidiDevice(name: String(localized: "midi_lp_s"), icon: "pianokeys"),
        MidiDevice(name: String(localized: "midi_lp_mk2"), icon: "square.grid.3x3"),
        MidiDevice(name: String(localized: "midi_lp_pro"), icon: "square.grid.3x3.fill"),
        MidiDevice(name: String(localized: "midi_lp_x"), icon: "square.grid.3x3.topleft.filled"),
        MidiDevice(name: String(localized: "midi_lp_mini_mk3"), icon: "square.grid.3x3.middle.filled"),
        MidiDevice(name: String(localized: "midi_lp_mk3"), icon: "square.grid.3x3.bottomright.filled"),
        MidiDevice(name: String(localized: "midi_midi_fighter"), icon: "dial.medium"),
        MidiDevice(name: String(localized: "midi_matrix"), icon: "rectangle.grid.3x2"),
        MidiDevice(name: String(localized: "midi_master_keyboard"), icon: "pianokeys.inverse"),
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
            startAutorunTimer()
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
                    .font(.system(size: 64))
                    .foregroundStyle(AppColors.blue)

                Text(midiDevices[selectedIndex].name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 16)

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
                            .foregroundStyle(AppColors.textSecondary)
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
}

// MARK: - Data

struct MidiDevice {
    let name: String
    let icon: String
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
                    .font(.system(size: 36))
                    .foregroundStyle(isSelected ? AppColors.blue : AppColors.textPrimary.opacity(0.6))

                Text(device.name)
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(minHeight: 30)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(isSelected ? AppColors.darkSurface.opacity(0.8) : AppColors.darkSurface.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? AppColors.blue : .clear, lineWidth: 2)
            )
        }
    }
}
