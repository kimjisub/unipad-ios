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

        /// The engine is held just before it sends its report; the screen closes; the report then arrives.
        @Test(arguments: [false, true])
        func aLoadEndingAfterTheScreenClosedChangesNothing(soundsFail: Bool) async throws {
            try await PlayUsageScenario.run(keyLed: ["1 1 1": "on 1 1 a 5\n"]) { s in
                try await withMainScreenOnTheLaunchpad { mainReceiver in
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

                    s.vm.cleanup()
                    report.signal()
                    try await s.waitWhile(timeout: 5) { trace.lastEvent != .completionDelivered }
                    try #require(trace.lastEvent == .completionDelivered, "the report never arrived: \(trace.summary)")
                    try await Task.sleep(for: .milliseconds(100))

                    expectLeftAlone(by: s.vm, mainReceiver)
                    #expect(!s.vm.scbLed.checked, "the closed play screen applied its start settings")
                    #expect(!s.vm.quitRequested, "the closed play screen asked to close")
                    #expect(s.vm.toastMessage == nil, "the closed play screen showed a message")
                }
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
