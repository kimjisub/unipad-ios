import Foundation

/// What the device screen may say about the current connection. It holds only what MidiManager
/// observed; it never claims a model works or a firmware is installed.
nonisolated struct MidiConnectionReport: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case noDevice
        /// A device was found but CoreMIDI refused to open its source.
        case openFailed
        case connected
        /// The connected device went away; cleared by the next connection.
        case disconnected
    }

    enum CustomFirmware: Equatable, Sendable {
        case coreFW, launchpadOpen

        var name: String {
            switch self {
            case .coreFW: "CoreFW"
            case .launchpadOpen: "Launchpad Open"
            }
        }
    }

    private(set) var phase = Phase.noDevice
    /// The name the device reports about itself, not the model UniPad chose for it.
    private(set) var deviceName: String?
    /// False when no model matched the device and it was connected as a keyboard.
    private(set) var isModelRecognised = false
    /// Firmware recognised from the device's own endpoint names when it connected.
    private(set) var customFirmware: CustomFirmware?
    private(set) var connectedAt: Date?
    /// A pad press the connected device's driver could handle arrived during this connection.
    private(set) var hasPadInput = false

    mutating func connected(deviceName: String, isModelRecognised: Bool, customFirmware: CustomFirmware?, at date: Date) {
        self = MidiConnectionReport(phase: .connected, deviceName: deviceName, isModelRecognised: isModelRecognised,
                                    customFirmware: customFirmware, connectedAt: date, hasPadInput: false)
    }

    mutating func openFailed(deviceName: String) {
        self = MidiConnectionReport(phase: .openFailed, deviceName: deviceName)
    }

    mutating func disconnected() {
        guard phase == .connected else { return }
        self = MidiConnectionReport(phase: .disconnected)
    }

    /// A device that could not be opened is gone from the list.
    mutating func openFailedDeviceRemoved() {
        guard phase == .openFailed else { return }
        self = MidiConnectionReport()
    }

    /// Returns true only for the first press of a connection, so observers change once.
    mutating func padPressed() -> Bool {
        guard phase == .connected, !hasPadInput else { return false }
        hasPadInput = true
        return true
    }
}
