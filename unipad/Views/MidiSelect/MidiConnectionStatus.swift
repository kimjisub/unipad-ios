import Foundation

/// One of the approved states of the device screen's status box.
nonisolated enum MidiConnectionStatus: Equatable {
    case noDevice
    case openFailed(device: String)
    case unknownModel(device: String)
    /// Connected and recognised, no pad press yet. `longWait` after `quietPeriod`; still not a failure.
    case waiting(device: String, longWait: Bool)
    case padReceived(device: String)
    case disconnected

    static let quietPeriod: TimeInterval = 20

    init(_ report: MidiConnectionReport, now: Date) {
        let device = report.deviceName ?? ""
        switch report.phase {
        case .noDevice: self = .noDevice
        case .openFailed: self = .openFailed(device: device)
        case .disconnected: self = .disconnected
        case .connected:
            if report.isConnectedAsKeyboard {
                self = .unknownModel(device: device)
            } else if report.hasPadInput {
                self = .padReceived(device: device)
            } else {
                let waited = report.connectedAt.map { now.timeIntervalSince($0) } ?? 0
                self = .waiting(device: device, longWait: waited >= Self.quietPeriod)
            }
        }
    }

    enum Tone { case problem, attention, neutral, received }

    var tone: Tone {
        switch self {
        case .noDevice, .openFailed: .problem
        case .unknownModel: .attention
        case .waiting, .disconnected: .neutral
        case .padReceived: .received
        }
    }

    var isConnected: Bool {
        switch self {
        case .unknownModel, .waiting, .padReceived: true
        case .noDevice, .openFailed, .disconnected: false
        }
    }

    /// Only a connected device whose model was recognised keeps the automatic confirmation.
    var allowsAutomaticConfirmation: Bool {
        switch self {
        case .waiting, .padReceived: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .noDevice: MidiHelpText.text("midi_help_status_none_title")
        case .openFailed: MidiHelpText.text("midi_help_status_openfail_title")
        case .disconnected: MidiHelpText.text("midi_help_status_disc_title")
        case .unknownModel(let device), .waiting(let device, _), .padReceived(let device):
            String(format: MidiHelpText.text("midi_help_status_connected_title"), device)
        }
    }

    var nextStep: String {
        switch self {
        case .noDevice: MidiHelpText.text("midi_help_status_none_next")
        case .openFailed(let device): String(format: MidiHelpText.text("midi_help_status_openfail_next"), device)
        case .unknownModel: MidiHelpText.text("midi_help_status_unknown_next")
        case .waiting(_, let longWait):
            MidiHelpText.text(longWait ? "midi_help_status_wait_long_next" : "midi_help_status_wait_next")
        case .padReceived: MidiHelpText.text("midi_help_status_input_next")
        case .disconnected: MidiHelpText.text("midi_help_status_disc_next")
        }
    }

    /// Marks under the status: an unknown model, and firmware recognised on the connected device.
    /// A model chosen by hand never adds a firmware mark.
    func tags(customFirmware: MidiConnectionReport.CustomFirmware?) -> [String] {
        var tags: [String] = []
        if case .unknownModel = self { tags.append(MidiHelpText.text("midi_help_tag_model_unknown")) }
        if isConnected, let customFirmware {
            tags.append(String(format: MidiHelpText.text("midi_help_tag_custom_firmware"), customFirmware.name))
        }
        return tags
    }

    /// Spoken once when the box changes to it; other changes stay quiet.
    var announcement: String? {
        switch self {
        case .padReceived: nextStep
        case .disconnected: title
        default: nil
        }
    }

    /// The help question shown open first for this status.
    func firstHelpQuestion(customFirmware: MidiConnectionReport.CustomFirmware?) -> MidiHelpQuestion {
        if isConnected, customFirmware != nil { return .customFirmware }
        switch self {
        case .noDevice, .openFailed, .disconnected: return .notFound
        case .unknownModel, .waiting: return .noResponse
        case .padReceived: return .noLights
        }
    }
}

/// Where the selected model came from. None while no device is connected.
nonisolated enum MidiModelSource: Equatable {
    case automatic, manual

    var text: String {
        MidiHelpText.text(self == .automatic ? "midi_help_source_auto" : "midi_help_source_manual")
    }
}

/// The help's questions, in the fixed order they are listed.
nonisolated enum MidiHelpQuestion: Int, CaseIterable, Identifiable {
    case notFound = 1, noResponse, noLights, wrongPad, chains, customFirmware, appCloses

    struct Line: Equatable {
        let key: String
        /// Continues the numbered step above it.
        var continuation = false
    }

    var id: Int { rawValue }
    var titleKey: String { "midi_help_q\(rawValue)_title" }

    var lines: [Line] {
        let numbered = { (count: Int) in (1...count).map { Line(key: "midi_help_q\(rawValue)_\($0)") } }
        switch self {
        case .notFound, .noLights, .wrongPad, .customFirmware: return numbered(3)
        case .noResponse:
            return [Line(key: "midi_help_q2_1"), Line(key: "midi_help_q2_2"),
                    Line(key: "midi_help_q2_2_ios", continuation: true), Line(key: "midi_help_q2_3")]
        case .chains: return [Line(key: "midi_help_q5_intro")] + numbered(3)
        case .appCloses: return numbered(1)
        }
    }
}

/// The help's web pages. Set `isEnabled` to false to ship without both links while the pages are not public;
/// the addresses themselves stay as approved.
nonisolated enum MidiHelpLinks {
    static let isEnabled = true
    static let guide = URL(string: "https://unipad.io/docs/guide#launchpad")!
    static let customFirmware = URL(string: "https://unipad.io/docs/guide#custom-firmware")!
}
