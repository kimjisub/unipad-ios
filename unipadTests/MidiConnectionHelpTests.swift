import Foundation
import Testing
@testable import unipad

struct MidiConnectionHelpTests {
    private static let connectedAt = Date(timeIntervalSinceReferenceDate: 1_000)

    private static func report(_ build: (inout MidiConnectionReport) -> Void) -> MidiConnectionReport {
        var report = MidiConnectionReport()
        build(&report)
        return report
    }

    private static func connected(recognised: Bool = true, firmware: MidiConnectionReport.CustomFirmware? = nil,
                                  pressed: Bool = false) -> MidiConnectionReport {
        report {
            $0.connected(deviceName: "LPX MIDI", isModelRecognised: recognised, customFirmware: firmware, at: connectedAt)
            if pressed { _ = $0.padPressed() }
        }
    }

    private static let waiting = MidiConnectionStatus.waiting(device: "LPX MIDI", longWait: false)

    // MARK: - Automatic confirmation

    @Test func openingAndClosingHelpPermanentlyCancelsAutorun() {
        var state = MidiSelectState()
        state.detectedModel(3)
        let started = state.startAutorun(for: Self.waiting)
        #expect(started)
        let notDue = state.tickAutorun()
        #expect(!notDue)
        state.openHelp()
        #expect(state.remainingSeconds == nil)
        #expect(state.isHelpPresented)
        for _ in 0..<6 {
            let due = state.tickAutorun()
            #expect(!due)
        }
        state.isHelpPresented = false
        let restarted = state.startAutorun(for: Self.waiting)
        #expect(!restarted)
        #expect(state.remainingSeconds == nil)
    }

    @Test(arguments: [MidiConnectionStatus.waiting(device: "LPX MIDI", longWait: false),
                      .waiting(device: "LPX MIDI", longWait: true), .padReceived(device: "LPX MIDI")])
    func recognisedConnectionStillConfirmsOnTheFifthTick(_ status: MidiConnectionStatus) {
        var state = MidiSelectState()
        state.detectedModel(3)
        let started = state.startAutorun(for: status)
        #expect(started)
        for _ in 0..<4 {
            let due = state.tickAutorun()
            #expect(!due)
        }
        let due = state.tickAutorun()
        #expect(due)
        let notDue = state.tickAutorun()
        #expect(!notDue)
    }

    @Test(arguments: [MidiConnectionStatus.noDevice, .openFailed(device: "LPX MIDI"),
                      .unknownModel(device: "USB MIDI Device"), .disconnected])
    func noAutomaticConfirmationWithoutARecognisedDevice(_ status: MidiConnectionStatus) {
        var state = MidiSelectState()
        state.restoreModel(0)
        let started = state.startAutorun(for: status)
        #expect(!started)
        #expect(state.remainingSeconds == nil)
        for _ in 0..<6 {
            let due = state.tickAutorun()
            #expect(!due)
        }
        // A device connecting later on the same screen does not start it either.
        state.detectedModel(3)
        let later = state.startAutorun(for: Self.waiting)
        #expect(!later)
    }

    @Test func modelChosenBeforeTheScreenOpenedHasNoAutomaticConfirmation() {
        var state = MidiSelectState()
        state.earlierChoice(9)
        #expect(state.modelSource == .manual)
        let started = state.startAutorun(for: Self.waiting)
        #expect(!started)
    }

    @Test(arguments: [MidiConnectionStatus.disconnected, .unknownModel(device: "USB MIDI Device")])
    func losingTheRecognisedDeviceStopsTheCountdown(_ status: MidiConnectionStatus) {
        var state = MidiSelectState()
        state.detectedModel(3)
        let started = state.startAutorun(for: Self.waiting)
        #expect(started)
        state.statusChanged(to: .padReceived(device: "LPX MIDI"))
        #expect(state.remainingSeconds == 5)
        state.statusChanged(to: status)
        #expect(state.remainingSeconds == nil)
    }

    @Test func selectingAModelCancelsAutorunAndMarksItManual() {
        var state = MidiSelectState()
        state.detectedModel(3)
        let started = state.startAutorun(for: Self.waiting)
        #expect(started)
        state.selectModel(4)
        #expect(state.remainingSeconds == nil)
        #expect(state.selectedIndex == 4)
        #expect(state.modelSource == .manual)
        // Reconnecting shows the recognised model again.
        state.detectedModel(1)
        #expect(state.modelSource == .automatic)
        #expect(state.selectedIndex == 1)
    }

    @Test func modelSourceFollowsTheConnection() {
        var state = MidiSelectState()
        state.restoreModel(9)
        #expect(state.modelSource == nil)
        state.unrecognisedModel(8)
        #expect(state.modelSource == nil)
        #expect(state.selectedIndex == 8)
        state.selectModel(4)
        state.deviceLeft()
        #expect(state.modelSource == nil)
        #expect(state.selectedIndex == 4)
    }

    @MainActor @Test func readingHelpKeepsSelectionPreferencesAndDriver() {
        let saved = PreferenceManager.shared.launchpadConnectMethod
        let driver = MidiManager.shared.driver
        let log = MidiManager.shared.debugLog
        var state = MidiSelectState()
        state.selectModel(4)
        state.openHelp()
        state.isHelpPresented = false
        #expect(state.selectedIndex == 4)
        #expect(state.modelSource == .manual)
        #expect(PreferenceManager.shared.launchpadConnectMethod == saved)
        #expect(MidiManager.shared.driver === driver)
        #expect(MidiManager.shared.debugLog == log)
    }

    // MARK: - What the manager records

    @Test func firstPadPressIsRecordedOncePerConnection() {
        var report = Self.connected()
        #expect(report.padPressed())
        #expect(!report.padPressed())
        #expect(report.hasPadInput)
        report.connected(deviceName: "LPX MIDI", isModelRecognised: true, customFirmware: nil, at: Self.connectedAt)
        #expect(!report.hasPadInput, "a new connection starts without input")
    }

    @Test func padPressesWithoutAConnectionAreNotRecorded() {
        var report = MidiConnectionReport()
        #expect(!report.padPressed())
        report.openFailed(deviceName: "LPX MIDI")
        #expect(!report.padPressed())
        report.connected(deviceName: "LPX MIDI", isModelRecognised: true, customFirmware: nil, at: Self.connectedAt)
        report.disconnected()
        #expect(!report.padPressed())
        #expect(!report.hasPadInput)
    }

    @Test func onlyAConnectedDeviceCanDisconnect() {
        var report = MidiConnectionReport()
        report.disconnected()
        #expect(report.phase == .noDevice)
        report.openFailed(deviceName: "LPX MIDI")
        report.disconnected()
        #expect(report.phase == .openFailed)
        report.openFailedDeviceRemoved()
        #expect(report.phase == .noDevice)
        report.connected(deviceName: "LPX MIDI", isModelRecognised: true, customFirmware: .coreFW, at: Self.connectedAt)
        report.openFailedDeviceRemoved()
        #expect(report.phase == .connected)
        report.disconnected()
        #expect(report.phase == .disconnected)
        #expect(report.deviceName == nil && report.customFirmware == nil && report.connectedAt == nil)
    }

    // MARK: - Status box

    @Test func statusFollowsTheReport() {
        let now = Self.connectedAt.addingTimeInterval(19.9)
        let later = Self.connectedAt.addingTimeInterval(20)
        #expect(MidiConnectionStatus(MidiConnectionReport(), now: now) == .noDevice)
        #expect(MidiConnectionStatus(Self.report { $0.openFailed(deviceName: "LPX MIDI") }, now: now)
                == .openFailed(device: "LPX MIDI"))
        #expect(MidiConnectionStatus(Self.connected(recognised: false), now: now) == .unknownModel(device: "LPX MIDI"))
        #expect(MidiConnectionStatus(Self.connected(), now: now) == .waiting(device: "LPX MIDI", longWait: false))
        #expect(MidiConnectionStatus(Self.connected(), now: later) == .waiting(device: "LPX MIDI", longWait: true))
        #expect(MidiConnectionStatus(Self.connected(pressed: true), now: later) == .padReceived(device: "LPX MIDI"))
        let gone = Self.report {
            $0.connected(deviceName: "LPX MIDI", isModelRecognised: true, customFirmware: nil, at: Self.connectedAt)
            $0.disconnected()
        }
        #expect(MidiConnectionStatus(gone, now: now) == .disconnected)
    }

    @Test func waitingLongIsNeverShownAsAProblem() {
        let status = MidiConnectionStatus.waiting(device: "LPX MIDI", longWait: true)
        #expect(status.tone == .neutral)
        #expect(status.announcement == nil)
        #expect(MidiConnectionStatus.padReceived(device: "x").announcement != nil)
        #expect(MidiConnectionStatus.disconnected.announcement != nil)
    }

    @Test func firmwareIsMarkedOnlyWhileItsDeviceIsConnected() {
        #expect(Self.waiting.tags(customFirmware: .coreFW) == [String(format: MidiHelpText.text("midi_help_tag_custom_firmware"), "CoreFW")])
        #expect(Self.waiting.tags(customFirmware: .launchpadOpen).first?.hasSuffix("Launchpad Open") == true)
        #expect(MidiConnectionStatus.disconnected.tags(customFirmware: .coreFW).isEmpty)
        #expect(MidiConnectionStatus.noDevice.tags(customFirmware: nil).isEmpty)
        #expect(MidiConnectionStatus.unknownModel(device: "x").tags(customFirmware: nil)
                == [MidiHelpText.text("midi_help_tag_model_unknown")])
    }

    @Test func helpOpensTheQuestionForTheStatus() {
        let cases: [(MidiConnectionStatus, MidiConnectionReport.CustomFirmware?, MidiHelpQuestion)] = [
            (.noDevice, nil, .notFound), (.openFailed(device: "x"), nil, .notFound), (.disconnected, .coreFW, .notFound),
            (.unknownModel(device: "x"), nil, .noResponse), (Self.waiting, nil, .noResponse),
            (.waiting(device: "x", longWait: true), nil, .noResponse), (.padReceived(device: "x"), nil, .noLights),
            (.padReceived(device: "x"), .launchpadOpen, .customFirmware), (Self.waiting, .coreFW, .customFirmware),
        ]
        for (status, firmware, question) in cases {
            #expect(status.firstHelpQuestion(customFirmware: firmware) == question, "\(status)")
        }
    }

    @Test func questionsKeepTheirApprovedOrderAndIPhoneLines() {
        #expect(MidiHelpQuestion.allCases.map(\.rawValue) == Array(1...7))
        #expect(MidiHelpQuestion.noResponse.lines.map(\.key)
                == ["midi_help_q2_1", "midi_help_q2_2", "midi_help_q2_2_ios", "midi_help_q2_3"])
        #expect(MidiHelpQuestion.noResponse.lines.filter(\.continuation).map(\.key) == ["midi_help_q2_2_ios"])
        #expect(MidiHelpQuestion.chains.lines.first?.key == "midi_help_q5_intro")
        #expect(MidiHelpLinks.guide.absoluteString == "https://unipad.io/docs/guide#launchpad")
        #expect(MidiHelpLinks.customFirmware.absoluteString == "https://unipad.io/docs/guide#custom-firmware")
    }

    // MARK: - Texts

    @Test(arguments: ["en", "ko"])
    func everyKeyTheScreenUsesIsTranslated(_ language: String) throws {
        let table = try #require(LocalizationBundleTests.strings(for: language))
        var keys = ["midi_help_title", "midi_help_close", "midi_help_now", "midi_help_selected_model",
                    "midi_help_web", "midi_help_cfw_link", "midi_help_link_failed",
                    "midi_help_tag_model_unknown", "midi_help_tag_custom_firmware",
                    "midi_help_source_auto", "midi_help_source_manual"]
        keys += ["none_title", "none_next", "openfail_title", "openfail_next", "connected_title", "unknown_next",
                 "wait_next", "wait_long_next", "input_next", "disc_title", "disc_next"].map { "midi_help_status_" + $0 }
        for question in MidiHelpQuestion.allCases {
            keys.append(question.titleKey)
            keys += question.lines.map(\.key)
        }
        let help = table.filter { $0.key.hasPrefix("midi_help_") }
        #expect(Set(help.keys) == Set(keys), "unused or missing help texts")
        #expect(help.values.allSatisfy { !$0.isEmpty })
        #expect(table["settings_ok"] == (language == "ko" ? "확인" : "OK"))
        #expect(table["midiDevicesNotDetected"] == nil)
    }

    @Test(arguments: [
        ("ko", "midi_help_title", "연결이 안 되나요?"), ("en", "midi_help_title", "Not connecting?"),
        ("ko", "midi_help_status_none_title", "런치패드를 찾지 못했어요"), ("en", "midi_help_status_none_title", "No Launchpad found"),
        ("ko", "midi_help_source_manual", "직접 고름 · 다시 꽂으면 자동으로 돌아가요"),
        ("en", "midi_help_status_unknown_next",
         "UniPad didn't recognise the model, so it connected it as a keyboard. If it's a Launchpad, tap “Not connecting?”."),
    ])
    func approvedTextIsUnchanged(_ language: String, _ key: String, _ expected: String) throws {
        let table = try #require(LocalizationBundleTests.strings(for: language))
        #expect(table[key] == expected)
    }

    @Test func manufacturerSettingsLinkIsGone() throws {
        for language in ["en", "ko"] {
            let table = try #require(LocalizationBundleTests.strings(for: language))
            #expect(!table.values.contains { $0.contains("novationmusic.com") })
            #expect(table["midi_help_manufacturer"] == nil)
        }
    }

    @Test func proCustomFirmwareCardHasTheSameNameInEveryLanguage() throws {
        for language in Bundle.main.localizations where language != "Base" {
            let table = try #require(LocalizationBundleTests.strings(for: language), "\(language)")
            #expect(table["midi_lp_pro_cfw"] == "Launchpad Pro (Launchpad Open)", "\(language)")
        }
    }

    @Test func untranslatedHelpUsesEnglishPerKey() throws {
        let english = try #require(LocalizationBundleTests.strings(for: "en"))
        let languages = Bundle.main.localizations.filter { !["Base", "en", "ko"].contains($0) }
        #expect(!languages.isEmpty)
        for language in languages {
            let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: url))
            for (key, expected) in english where key.hasPrefix("midi_help_") {
                #expect(MidiHelpText.text(key, bundle: bundle) == expected, "\(language).\(key)")
            }
        }
    }
}
