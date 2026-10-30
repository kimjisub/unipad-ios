import AVFoundation
import Testing
@testable import unipad

extension PlayUsageRecordTests {
    @MainActor
    struct PlayPreferenceParityTests {
        @Test func slideDefaultsOffAndKeepsAnExplicitChoice() {
            let defaults = UserDefaults.standard
            let key = PreferenceManager.Keys.slideEnabled
            let previous = defaults.object(forKey: key)
            defer { defaults.set(previous, forKey: key) }
            defaults.removeObject(forKey: key)
            #expect(!PreferenceManager.shared.slideEnabled)
            defaults.set(true, forKey: key)
            #expect(PreferenceManager.shared.slideEnabled)
            defaults.set(false, forKey: key)
            #expect(!PreferenceManager.shared.slideEnabled)
        }

        @Test func savedWatermarkOffIsUsedByANewPerformance() {
            let defaults = UserDefaults.standard
            let previous = defaults.object(forKey: "Watermark")
            defer { defaults.set(previous, forKey: "Watermark") }
            defaults.set(false, forKey: "Watermark")
            let vm = PlayViewModel()
            #expect(!vm.scbWatermark.checked)
        }

        @Test func watermarkChoiceSurvivesANewModel() {
            let defaults = UserDefaults.standard
            let previous = defaults.object(forKey: "Watermark")
            defer { defaults.set(previous, forKey: "Watermark") }
            defaults.removeObject(forKey: "Watermark")
            let first = PlayViewModel()
            first.setupCheckBoxListeners()
            #expect(first.scbWatermark.checked)
            first.scbWatermark.setChecked(false)
            #expect(!PlayViewModel().scbWatermark.checked)
            first.scbWatermark.setChecked(true)
            #expect(PlayViewModel().scbWatermark.checked)
        }

        @Test func newTraceDisplayUsesNumbersAndKeepsAnExplicitLineChoice() {
            let defaults = UserDefaults.standard
            let key = PreferenceManager.Keys.traceLogClassic
            let previous = defaults.object(forKey: key)
            defer { defaults.set(previous, forKey: key) }
            defaults.removeObject(forKey: key)
            #expect(PreferenceManager.shared.traceLogClassic)
            defaults.set(false, forKey: key)
            #expect(!PreferenceManager.shared.traceLogClassic)
            defaults.set(true, forKey: key)
            #expect(PreferenceManager.shared.traceLogClassic)
        }

        @Test(arguments: [false, true])
        func packDefaultsAndVolumeDoNotDependOnPreviousFeedback(_ hasLED: Bool) async throws {
            try await PlayUsageScenario.run(keyLed: hasLED ? ["1 1 1": "on 1 1 5\nd 50\n"] : [:]) { s in
                try await s.loadReady()
                let volume = AVAudioSession.sharedInstance().outputVolume
                s.vm.scbFeedbackLight.setCheckedSilently(hasLED)
                s.vm.initSetting()
                #expect(s.vm.scbFeedbackLight.checked == !hasLED)
                #expect(AVAudioSession.sharedInstance().outputVolume == volume)
            }
        }

        @Test(arguments: [false, true])
        func autoplayEndRestoresThePackFeedbackDefault(_ hasLED: Bool) async throws {
            try await PlayUsageScenario.run(autoPlay: "d 100\no 1 1\nf 1 1\nd 50\n",
                                            keyLed: hasLED ? ["1 1 1": "on 1 1 5\nd 50\n"] : [:]) { s in
                try await s.loadReady()
                s.vm.switchPlayMode(.autoPlay)
                s.vm.scbFeedbackLight.setCheckedSilently(hasLED)
                try await s.autoplayEnded()
                #expect(s.vm.scbFeedbackLight.checked == !hasLED)
            }
        }

        @Test func loadingDoesNotRestoreWatermarkOverTheUsersChoice() async throws {
            let defaults = UserDefaults.standard
            let previous = defaults.object(forKey: "Watermark")
            defer { defaults.set(previous, forKey: "Watermark") }
            defaults.set(true, forKey: "Watermark")
            try await PlayUsageScenario.run { s in
                s.vm.setupCheckBoxListeners()
                s.vm.scbWatermark.setChecked(false)
                try await s.loadReady()
                #expect(!s.vm.scbWatermark.checked)
                s.vm.scbWatermark.setChecked(true)
                s.vm.initSetting()
                #expect(s.vm.scbWatermark.checked)
            }
        }

        @Test func leavingThePackClearsTraces() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                s.vm.scbTraceLog.setChecked(true)
                s.press(); s.release()
                #expect(s.vm.traceLogSequence[0].count == 1)
                s.vm.cleanup()
                #expect(s.vm.traceLogSequence.allSatisfy { $0.isEmpty })
            }
        }

        @Test func recordingOffKeepsAllChainsAndResumesTheirOrder() async throws {
            try await PlayUsageScenario.run(grid: .init(chain: 2)) { s in
                try await s.loadReady()
                #expect(!s.vm.scbTraceLog.checked)
                #expect(s.vm.traceLogSequence.allSatisfy { $0.isEmpty })
                s.vm.scbTraceLog.setChecked(true)
                s.press(); s.release()
                s.press(0, 1); s.release(0, 1)
                s.press(); s.release()
                s.vm.selectChain(1)
                s.press(); s.release()
                s.vm.scbTraceLog.setChecked(false)
                s.press(1, 1); s.release(1, 1)
                s.vm.proLightMode(true)
                s.vm.proLightMode(false)
                #expect(TraceLogText.perPad(s.vm.traceLogSequence[0], columns: 8, rows: 8) == [0: "1 3", 1: "2"])
                #expect(TraceLogText.perPad(s.vm.traceLogSequence[1], columns: 8, rows: 8) == [0: "1"])
                s.vm.scbTraceLog.setChecked(true)
                s.press(0, 1); s.release(0, 1)
                #expect(TraceLogText.perPad(s.vm.traceLogSequence[1], columns: 8, rows: 8) == [0: "1", 1: "2"])
                s.vm.clearTraceLog()
                #expect(s.vm.scbTraceLog.checked)
                #expect(s.vm.traceLogSequence.allSatisfy { $0.isEmpty })
            }
        }
    }
}
