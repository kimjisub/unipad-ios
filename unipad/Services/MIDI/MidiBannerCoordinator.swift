import SwiftUI

@MainActor
@Observable
final class MidiBannerCoordinator {
    var isVisible = false
    var message = ""

    private var announceOnNextActive = false
    private var lastAnnouncedDeviceName: String?
    private var dismissTask: Task<Void, Never>?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        MidiManager.shared.start()
    }

    func handleConnectionStateChanged(_ connected: Bool, scenePhase: ScenePhase, router: AppRouter) {
        if connected {
            if scenePhase == .active {
                presentIfNeeded(router: router, force: false)
            } else {
                announceOnNextActive = true
            }
            return
        }

        announceOnNextActive = false
        lastAnnouncedDeviceName = nil
        dismiss()
    }

    func handleScenePhaseChanged(_ scenePhase: ScenePhase, router: AppRouter) {
        switch scenePhase {
        case .active:
            MidiManager.shared.scanForDevices()
            if announceOnNextActive && MidiManager.shared.isConnected {
                presentIfNeeded(router: router, force: true)
            }
            announceOnNextActive = false
        case .inactive, .background:
            if MidiManager.shared.isConnected {
                announceOnNextActive = true
            }
        @unknown default:
            break
        }
    }

    func openMidiPanel(router: AppRouter) {
        dismiss()
        router.navigateToMidiSelectIfNeeded()
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            isVisible = false
        }
    }

    private func presentIfNeeded(router: AppRouter, force: Bool) {
        guard !router.isShowingMidiSelect else { return }

        let deviceName = MidiManager.shared.connectedDeviceName ?? String(localized: "launchpadConnecting")
        if !force && lastAnnouncedDeviceName == deviceName {
            return
        }

        message = String(
            format: String(localized: "midi_connected_banner %@"),
            deviceName
        )
        lastAnnouncedDeviceName = deviceName

        dismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            isVisible = true
        }

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.dismiss()
        }
    }
}
