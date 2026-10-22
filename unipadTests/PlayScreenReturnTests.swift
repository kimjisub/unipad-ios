#if canImport(UIKit)
import Foundation
import Testing
@testable import unipad

/// What the play screen keeps and restores when the app or the screen is left for a while and comes
/// back. A simulator neither suspends the app nor refuses the audio session, so a blocked main thread
/// stands in for a suspended app (nothing on the main actor runs meanwhile) and the engine's session
/// activation is replaced by one that refuses, as a call in progress makes it refuse on a phone.
extension PlayUsageRecordTests {
    @MainActor
    struct PlayScreenReturnTests {
        /// Refuses the audio session while `inProgress` is set. Called on the audio session worker.
        nonisolated final class Call: @unchecked Sendable {
            private let lock = NSLock()
            private var on = true

            var inProgress: Bool {
                get { lock.withLock { on } }
                set { lock.withLock { on = newValue } }
            }

            func activate() throws {
                if inProgress { throw CocoaError(.featureUnsupported) }
                try SoundEngine.configureSession()
            }
        }

        /// Nothing on the main actor runs meanwhile, as in a suspended app.
        private func suspendTheApp(for seconds: TimeInterval) {
            Thread.sleep(forTimeInterval: seconds)
        }

        private func refuseTheSession(_ s: PlayUsageScenario, while call: Call) {
            s.vm.makeSoundEngine = { pack, chain, listener in
                SoundEngine(unipack: pack, chain: chain, loadingListener: listener, activateSession: call.activate)
            }
        }

        /// Opening a pack during a call: the session cannot be activated until the call ends. That says
        /// nothing about the device, so the screen stays open with silent pads, and the sound comes back
        /// once the call is over and the app is in front again.
        @Test func aPackOpenedWhileTheSessionIsRefusedStaysOpenAndSoundsAfterTheCall() async throws {
            try await PlayUsageScenario.run { s in
                let call = Call()
                refuseTheSession(s, while: call)
                try await s.load()
                try await s.waitWhile(timeout: 15) { !s.vm.startReady && !s.vm.quitRequested }

                #expect(!s.vm.quitRequested, "the screen closed because the session was refused")
                #expect(s.vm.toastMessage != String(localized: "outOfCPU"), "a refused session was reported as a slow device")
                try #require(s.vm.startReady, "the pack never became ready")
                #expect(s.sink.events(named: "pack_load").first?.parameters["result"] == "success")
                let engine = try #require(s.vm.soundEngine)
                s.press(0, 0); s.release(0, 0)
                #expect(engine.playsStarted == 0, "a pad played without the session")

                call.inProgress = false
                s.vm.onResume()
                try await s.waitWhile { engine.isPlaybackSuppressed }
                s.press(0, 0); s.release(0, 0)
                #expect(engine.playsStarted == 1, "the pad stayed silent after the call ended")
            }
        }

        /// Autoplay presses (1,2) every 100 ms. The app is suspended for 1.5 s: on coming back, autoplay
        /// continues from where it was instead of playing the 15 presses it missed at once.
        @Test func autoplayDoesNotPlayWhatItMissedWhileTheAppWasSuspendedAtOnce() async throws {
            let autoPlay = String(repeating: "on 1 2\ndelay 100\noff 1 2\n", count: 100)
            try await PlayUsageScenario.run(autoPlay: autoPlay) { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                let runner = try #require(s.vm.autoPlayRunner)
                s.vm.switchPlayMode(.autoPlay)
                try await s.waitWhile { runner.progress < 6 }
                try #require(runner.progress >= 6, "autoplay never started")

                s.vm.onPause()
                suspendTheApp(for: 1.5)
                s.vm.onResume()
                let playsBefore = engine.playsStarted
                try await Task.sleep(for: .milliseconds(50))

                let burst = engine.playsStarted - playsBefore
                #expect(burst <= 2, "\(burst) autoplay presses came at once after the return")
                #expect(s.vm.isAutoPlayPlaying)
                try await s.waitWhile { engine.playsStarted < playsBefore + 3 }
                #expect(engine.playsStarted >= playsBefore + 3, "autoplay did not go on after the return")
            }
        }

        /// A batch of lights that the light runner worked out just before the lights were turned off
        /// reaches the screen after they were cleared; it must not light the pad again.
        @Test func lightsWorkedOutBeforeTheyWereTurnedOffDoNotComeBack() async throws {
            try await PlayUsageScenario.run(keyLed: ["1 1 1": "on 1 1 a 5\ndelay 5000\noff 1 1\n"]) { s in
                try await s.loadReady()
                let runner = try #require(s.vm.ledRunner)
                #expect(s.vm.scbLed.checked)
                s.press(0, 0)
                runner.loop()
                s.vm.scbLed.setChecked(false)
                try await Task.sleep(for: .milliseconds(100))

                #expect(s.vm.channelManager?.get(x: 0, y: 0, channel: .led) == nil, "the pad lit again after the lights were turned off")
            }
        }
    }
}
#endif
