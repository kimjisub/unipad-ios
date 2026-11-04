#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
@testable import unipad

/// The sound engine's report that loading ended reaches the play screen on the main thread, so the
/// screen can close while the report is on its way. By then the main screen holds the launchpad again
/// and has no reason to take it back, so a closed play screen must leave everything as it is.
extension PlayUsageRecordTests {
    @MainActor
    struct PlayLateSoundLoadTests {
        /// The main screen, holding the launchpad as it does once the play screen has closed.
        private func withMainScreenOnTheLaunchpad(_ body: (MidiController) async throws -> Void) async throws {
            let main = MainViewModel()
            main.setupMidiController()
            defer { main.removeMidiController() }
            try await body(try #require(MidiManager.shared.controller))
        }

        private func expectLeftAlone(by vm: PlayViewModel, _ mainReceiver: MidiController) {
            #expect(MidiManager.shared.controller === mainReceiver, "the closed play screen took the launchpad from the main screen")
            #expect(!vm.isWatchingVolume, "the closed play screen watches the volume again")
            #expect(!vm.startReady, "the closed play screen became ready")
            #expect(!vm.uiLoaded, "the closed play screen was marked as shown")
        }

        /// Loads with the engine held just before it sends its report; `meanwhile` runs while the
        /// report waits, which has reached the screen when this returns.
        private func loadWithTheReportHeld(
            _ s: PlayUsageScenario, soundsFail: Bool, meanwhile: () -> Void
        ) async throws {
            let trace = SoundLoadingTrace()
            let report = DispatchSemaphore(value: 0)
            defer { report.signal() }
            s.vm.makeSoundEngine = { pack, chain, listener in
                SoundEngine(
                    unipack: pack, chain: chain, loadingListener: listener,
                    openAudioFile: { url in
                        if soundsFail { throw CocoaError(.fileReadCorruptFile) }
                        return try AVAudioFile(forReading: url)
                    },
                    observeLoading: { event in
                        trace.record(event)
                        if event == .completionQueued { report.wait() }
                    })
            }
            try await s.load()
            try await s.waitWhile(timeout: 20) { trace.lastEvent != .completionQueued }
            try #require(trace.lastEvent == .completionQueued, "the engine never finished: \(trace.summary)")

            meanwhile()
            report.signal()
            try await s.waitWhile(timeout: 5) { trace.lastEvent != .completionDelivered }
            try #require(trace.lastEvent == .completionDelivered, "the report never arrived: \(trace.summary)")
            try await Task.sleep(for: .milliseconds(100))
        }

        /// The screen closes while the engine's report waits; the report then arrives.
        @Test(arguments: [false, true])
        func aLoadEndingAfterTheScreenClosedChangesNothing(soundsFail: Bool) async throws {
            try await PlayUsageScenario.run(keyLed: ["1 1 1": "on 1 1 a 5\n"]) { s in
                try await withMainScreenOnTheLaunchpad { mainReceiver in
                    try await loadWithTheReportHeld(s, soundsFail: soundsFail) { s.vm.cleanup() }

                    expectLeftAlone(by: s.vm, mainReceiver)
                    #expect(!s.vm.scbLed.checked, "the closed play screen applied its start settings")
                    #expect(!s.vm.quitRequested, "the closed play screen asked to close")
                    #expect(s.vm.toastMessage == nil, "the closed play screen showed a message")
                }
            }
        }

        /// The device screen opened from the connection banner is on top when the load fails. Closing
        /// the top screen then would close the device screen and leave this one open without sound;
        /// this screen closes once it is shown again.
        @Test func aLoadFailingUnderTheDeviceScreenClosesThisScreenWhenItIsShownAgain() async throws {
            try await PlayUsageScenario.run { s in
                try await loadWithTheReportHeld(s, soundsFail: true) { s.vm.screenCovered() }

                #expect(!s.vm.quitRequested, "the covered screen asked to close the screen on top")
                #expect(!s.vm.soundLoadingActive, "the loading screen stayed up")
                #expect(s.vm.toastMessage == String(localized: "outOfCPU"))

                s.vm.screenShown()
                #expect(s.vm.quitRequested, "the screen did not close once it was shown again")
            }
        }

        /// The app went away (another app, the Control Center) before the load ended. The launchpad
        /// was given up when it went away, so its buttons do nothing until the app is back.
        @Test func aLoadEndingWhileTheAppIsAwayLeavesTheLaunchpadUntilTheReturn() async throws {
            try await PlayUsageScenario.run { s in
                try await loadWithTheReportHeld(s, soundsFail: false) { s.vm.onPause() }

                try #require(s.vm.startReady, "the pack never became ready")
                #expect(MidiManager.shared.controller == nil, "the screen took the launchpad while the app was away")
                #expect(!s.vm.isWatchingVolume, "the screen watched the volume while the app was away")
                let feedbackLight = s.vm.scbFeedbackLight.checked
                MidiManager.shared.controller?.onFunctionKeyTouch(f: 0, upDown: true)
                try await Task.sleep(for: .milliseconds(100))
                #expect(s.vm.scbFeedbackLight.checked == feedbackLight, "a launchpad button changed a setting while the app was away")

                s.vm.onResume()
                #expect(MidiManager.shared.controller != nil, "the launchpad did not come back with the app")
                #expect(s.vm.isWatchingVolume, "the volume was not watched after the return")
            }
        }

        /// The engine's reports arrived just before the screen closed; their move to the main actor
        /// runs after that.
        @Test func reportsStillOnTheirWayWhenTheScreenClosedChangeNothing() async throws {
            try await withMainScreenOnTheLaunchpad { mainReceiver in
                let vm = PlayViewModel()
                let adapter = SoundLoadingAdapter(viewModel: vm)
                adapter.onStart(soundCount: 5)
                adapter.onProgressTick()
                adapter.onEnd()
                vm.cleanup()
                try await Task.sleep(for: .milliseconds(100))

                expectLeftAlone(by: vm, mainReceiver)
                #expect(vm.soundLoadingMax == 0, "the closed play screen took the sound count")
                #expect(vm.soundLoadingProgress == 0, "the closed play screen moved its progress")
                withExtendedLifetime(vm) {}
            }
        }

        /// A failure on a screen still open has to reach the user: without the message and the request
        /// to close, the loading screen stays up with no way out.
        @Test func aFailedLoadOnAnOpenScreenTellsTheUserAndAsksToClose() async throws {
            try await PlayUsageScenario.run { s in
                s.vm.makeSoundEngine = { pack, chain, listener in
                    SoundEngine(
                        unipack: pack, chain: chain, loadingListener: listener,
                        openAudioFile: { _ in throw CocoaError(.fileReadCorruptFile) })
                }
                try await s.load()
                try await s.waitWhile(timeout: 20) { !s.vm.quitRequested }

                try #require(s.vm.quitRequested, "the open screen never asked to close")
                #expect(s.vm.toastMessage == String(localized: "outOfCPU"))
                #expect(!s.vm.soundLoadingActive, "the loading screen stayed up")
                #expect(!s.vm.startReady)
                #expect(s.sink.events(named: "pack_load").first?.parameters["result"] != "success")
            }
        }
    }
}
#endif
