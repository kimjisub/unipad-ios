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
        /// The engine is held just before it sends its report; the screen closes; the report then arrives.
        @Test(arguments: [false, true])
        func aLoadEndingAfterTheScreenClosedChangesNothing(soundsFail: Bool) async throws {
            try await PlayUsageScenario.run(keyLed: ["1 1 1": "on 1 1 a 5\n"]) { s in
                let main = MainViewModel()
                main.setupMidiController()
                defer { main.removeMidiController() }
                let mainReceiver = try #require(MidiManager.shared.controller)

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
                let eventsWhenClosed = s.sink.events
                report.signal()
                try await s.waitWhile(timeout: 5) { trace.lastEvent != .completionDelivered }
                try #require(trace.lastEvent == .completionDelivered, "the report never arrived: \(trace.summary)")
                try await Task.sleep(for: .milliseconds(100))

                #expect(MidiManager.shared.controller === mainReceiver, "the closed play screen took the launchpad from the main screen")
                #expect(s.vm.volumeObservation == nil, "the closed play screen watches the volume again")
                #expect(!s.vm.startReady, "the closed play screen became ready")
                #expect(!s.vm.uiLoaded, "the closed play screen was marked as shown")
                #expect(!s.vm.scbLed.checked, "the closed play screen applied its start settings")
                #expect(!s.vm.quitRequested, "the closed play screen asked to close")
                #expect(s.vm.toastMessage == nil, "the closed play screen showed a message")
                #expect(s.sink.events.count == eventsWhenClosed.count, "a usage event was sent after the screen closed")
            }
        }

        /// The engine's report arrived just before the screen closed; its move to the main actor runs
        /// after that.
        @Test func aLoadReportStillOnItsWayWhenTheScreenClosedLeavesTheLaunchpad() async throws {
            let main = MainViewModel()
            main.setupMidiController()
            defer { main.removeMidiController() }
            let mainReceiver = try #require(MidiManager.shared.controller)

            let vm = PlayViewModel()
            let adapter = SoundLoadingAdapter(viewModel: vm)
            adapter.onEnd()
            vm.cleanup()
            try await Task.sleep(for: .milliseconds(100))

            #expect(MidiManager.shared.controller === mainReceiver, "the closed play screen took the launchpad from the main screen")
            #expect(vm.volumeObservation == nil, "the closed play screen watches the volume again")
            #expect(!vm.startReady, "the closed play screen became ready")
            withExtendedLifetime(vm) {}
        }
    }
}
#endif
