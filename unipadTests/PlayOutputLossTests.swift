#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
@testable import unipad

/// What the play screen does when the earphones, Bluetooth or USB output it plays to goes away and
/// the sound would carry on out of the device's own speaker. A simulator cannot plug or unplug an
/// output, so each test sets the outputs the session reports and posts the route change the system
/// would post. Each check is about requests to play (a node reaching `play()` or `stop()`), autoplay
/// progress and the Play button's state, never about audible sound.
extension PlayUsageRecordTests {
    @MainActor
    struct PlayOutputLossTests: PlayAudioSessionTesting {
        /// Pad (1,1) loops forever, (1,2) repeats 500 times (30 s of a 60 ms sample), (1,3) and (2,1)
        /// play once. Autoplay starts all three kinds, then keeps playing (2,1) so its place moves.
        private static let keySound = "1 1 1 a.wav 0\n1 1 2 a.wav 500\n1 1 3 a.wav\n1 2 1 a.wav\n"
        private static let autoPlay = "on 1 1\non 1 2\non 1 3\n"
            + String(repeating: "delay 100\non 2 1\noff 2 1\n", count: 300)

        /// Autoplay has started the loop, the 500 repeats and the one-shot, and moved on.
        private static let allKindsStarted = 5

        private static func run(_ body: (PlayUsageScenario) async throws -> Void) async throws {
            try await PlayUsageScenario.run(keySound: keySound, autoPlay: autoPlay, body)
        }

        // MARK: Which route changes pause

        struct RouteCase: CustomTestStringConvertible, Sendable {
            let reason: AVAudioSession.RouteChangeReason
            let previous: [AVAudioSession.Port]?
            let current: [AVAudioSession.Port]
            let pauses: Bool
            var testDescription: String {
                "\(reason.rawValue) \(previous?.map(\.rawValue) ?? ["unknown"]) -> \(current.map(\.rawValue)): \(pauses)"
            }
        }

        nonisolated static let routeCases: [RouteCase] = [
            // An external output went away and the device's own output is left.
            .init(reason: .oldDeviceUnavailable, previous: [.headphones], current: [.builtInSpeaker], pauses: true),
            .init(reason: .oldDeviceUnavailable, previous: [.bluetoothA2DP], current: [.builtInSpeaker], pauses: true),
            .init(reason: .oldDeviceUnavailable, previous: [.usbAudio], current: [.builtInSpeaker], pauses: true),
            .init(reason: .oldDeviceUnavailable, previous: [.bluetoothHFP], current: [.builtInReceiver], pauses: true),
            .init(reason: .oldDeviceUnavailable, previous: nil, current: [.builtInSpeaker], pauses: true),
            .init(reason: .oldDeviceUnavailable, previous: [.headphones], current: [], pauses: true),
            .init(reason: .noSuitableRouteForCategory, previous: [.headphones], current: [], pauses: true),
            // Another external output took over.
            .init(reason: .oldDeviceUnavailable, previous: [.bluetoothA2DP], current: [.headphones], pauses: false),
            .init(reason: .oldDeviceUnavailable, previous: [.usbAudio], current: [.bluetoothA2DP], pauses: false),
            .init(reason: .oldDeviceUnavailable, previous: [.headphones], current: [.airPlay], pauses: false),
            // Nothing external was lost.
            .init(reason: .oldDeviceUnavailable, previous: [.builtInSpeaker], current: [.builtInSpeaker], pauses: false),
            // A connection, and the changes that are not about a lost output.
            .init(reason: .newDeviceAvailable, previous: [.builtInSpeaker], current: [.headphones], pauses: false),
            .init(reason: .newDeviceAvailable, previous: [.headphones], current: [.builtInSpeaker], pauses: false),
            .init(reason: .categoryChange, previous: [.headphones], current: [.builtInSpeaker], pauses: false),
            .init(reason: .override, previous: [.headphones], current: [.builtInSpeaker], pauses: false),
            .init(reason: .routeConfigurationChange, previous: [.headphones], current: [.builtInSpeaker], pauses: false),
        ]

        @Test(arguments: routeCases)
        func onlyALostExternalOutputPauses(_ route: RouteCase) {
            #expect(SoundEngine.leavesOnlyTheDeviceOutput(
                reason: route.reason, previousOutputs: route.previous, currentOutputs: route.current) == route.pauses)
        }

        /// The engine takes the lost output from the notification: a loss that leaves the speaker
        /// pauses only when the route before it played to something external.
        @Test(arguments: [
            ([AVAudioSession.Port.headphones], true),
            ([.bluetoothA2DP, .builtInSpeaker], true),
            ([.builtInSpeaker], false),
        ])
        func theLostOutputComesFromTheNotification(previous: [AVAudioSession.Port], pauses: Bool) async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                let reports = observeInterruptions(engine)
                _ = try await startAutoplay(s, reaching: Self.allKindsStarted)

                loseOutput(engine, leaving: [.builtInSpeaker], previous: previous)

                let beginnings = reports.all.filter { if case .began = $0 { return true }; return false }
                #expect(beginnings.count == (pauses ? 1 : 0))
                #expect(s.vm.isAutoPlayPlaying == !pauses)
            }
        }

        // MARK: Losing the output

        @Test func autoplayPausesInPlaceAndItsSoundsStop() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                let held = holdOneShotCompletions(engine)
                defer { engine.playbackCompletionDelivery = nil }
                let runner = try await startAutoplay(s, reaching: Self.allKindsStarted)
                #expect(engine.activeVoiceCount >= 3, "the loop, the repeat and the one-shot were not all playing")
                #expect(engine.repeatedBuffersScheduled > 0)
                let stopped = engine.playerNodesStopped

                loseOutput(engine, leaving: [.builtInSpeaker])

                #expect(!s.vm.isAutoPlayPlaying, "the Play button still shows pause")
                #expect(s.vm.playMode == .autoPlay)
                #expect(runner.isSuspended)
                #expect(engine.activeVoiceCount == 0, "a sound autoplay started kept its voice")
                #expect(engine.playerNodesStopped > stopped)
                let pausedAt = runner.progress
                let plays = engine.playsStarted
                let repeats = engine.repeatedBuffersScheduled
                try await Task.sleep(for: .milliseconds(700))
                #expect(runner.progress == pausedAt, "autoplay moved on after the output was lost")
                #expect(engine.playsStarted == plays, "autoplay requested a new sound after the output was lost")
                #expect(engine.repeatedBuffersScheduled == repeats, "the finite repeat kept scheduling")
                #expect(engine.activeVoiceCount == 0)
                held.finish()
            }
        }

        @Test func soundsTheHandStartedStop() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                let held = holdOneShotCompletions(engine)
                defer { engine.playbackCompletionDelivery = nil }
                s.press(0, 0)
                s.press(0, 1)
                s.press(0, 2)
                #expect(engine.activeVoiceCount == 3)
                try await s.waitWhile { engine.repeatedBuffersScheduled == 0 }
                #expect(engine.repeatedBuffersScheduled > 0)

                loseOutput(engine, leaving: [.builtInSpeaker])

                #expect(engine.activeVoiceCount == 0, "a sound the hand started kept its voice")
                let repeats = engine.repeatedBuffersScheduled
                try await Task.sleep(for: .milliseconds(500))
                #expect(engine.repeatedBuffersScheduled == repeats, "the finite repeat kept scheduling")
                #expect(!isPressedLit(s, x: 0, y: 0), "the held pad stayed lit")
                held.finish()
            }
        }

        @Test func reconnectingRestartsNothingAndAHeldPadStaysSilent() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                let runner = try await startAutoplay(s, reaching: Self.allKindsStarted)
                s.press(1, 0) // held through the loss and the reconnection

                loseOutput(engine, leaving: [.builtInSpeaker])
                let pausedAt = runner.progress
                let plays = engine.playsStarted
                engine.currentOutputPorts = { [.headphones] }
                postRouteChange(.newDeviceAvailable)
                engine.handleConfigurationChange()
                try await waitForRecovery(s, engine, untilSettled: true)
                try await Task.sleep(for: .milliseconds(500))

                #expect(!s.vm.isAutoPlayPlaying, "reconnecting resumed autoplay")
                #expect(runner.progress == pausedAt)
                #expect(engine.activeVoiceCount == 0, "reconnecting brought a stopped sound back")
                #expect(engine.playsStarted == plays)
                s.release(1, 0)
                #expect(engine.playsStarted == plays, "releasing the held pad played it")
                #expect(engine.activeVoiceCount == 0)
            }
        }

        @Test(arguments: [false, true])
        func aNewPadSoundsWithoutPressingPlay(controller: Bool) async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                let runner = try await startAutoplay(s, reaching: Self.allKindsStarted)
                loseOutput(engine, leaving: [.builtInSpeaker])
                try await waitForRecovery(s, engine, untilSettled: true)
                let plays = engine.playsStarted

                if controller { s.vm.controllerPadTouch(x: 0, y: 0, isDown: true) } else { s.press(0, 0) }

                #expect(engine.playsStarted == plays + 1, "the new pad was not requested to play")
                #expect(engine.activeVoiceCount == 1)
                #expect(!s.vm.isAutoPlayPlaying, "a pad resumed autoplay")
                #expect(runner.isSuspended)
                if controller { s.vm.controllerPadTouch(x: 0, y: 0, isDown: false) } else { s.release(0, 0) }
                #expect(engine.activeVoiceCount == 0)
            }
        }

        @Test(arguments: [false, true])
        func playResumesFromWhereItPaused(reconnected: Bool) async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                let runner = try await startAutoplay(s, reaching: Self.allKindsStarted)
                loseOutput(engine, leaving: [.builtInSpeaker])
                let pausedAt = runner.progress
                if reconnected {
                    engine.currentOutputPorts = { [.bluetoothA2DP] }
                    postRouteChange(.newDeviceAvailable)
                }
                try await waitForRecovery(s, engine, untilSettled: true)
                try await Task.sleep(for: .milliseconds(300))
                #expect(runner.progress == pausedAt)

                s.vm.autoPlayResume()

                #expect(s.vm.isAutoPlayPlaying, "Play did not resume on \(reconnected ? "the earphones" : "the speaker")")
                #expect(!runner.isSuspended)
                #expect(runner.progress == pausedAt, "Play did not continue from the paused place")
                try await s.waitWhile { runner.progress <= pausedAt }
                #expect(runner.progress > pausedAt)
            }
        }

        // MARK: What does not pause

        enum KeptPlaying: String, CaseIterable {
            case anotherExternalOutput, newConnection, launchpadUnplugged
        }

        @Test(arguments: KeptPlaying.allCases)
        func autoplayAndHeldSoundsKeepPlaying(_ change: KeptPlaying) async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                let runner = try await startAutoplay(s, reaching: Self.allKindsStarted)
                s.press(0, 0)
                let reports = observeInterruptions(engine)

                switch change {
                case .anotherExternalOutput:
                    loseOutput(engine, leaving: [.headphones])
                case .newConnection:
                    engine.currentOutputPorts = { [.headphones] }
                    postRouteChange(.newDeviceAvailable)
                case .launchpadUnplugged:
                    s.vm.setupMidiController()
                    let controller = try #require(MidiManager.shared.controller)
                    controller.onDetach()
                    try await Task.sleep(for: .milliseconds(200))
                }
                engine.handleConfigurationChange()

                #expect(reports.all.isEmpty, "the change was reported as an interruption")
                #expect(s.vm.isAutoPlayPlaying)
                #expect(!runner.isSuspended)
                // The finger's loop and autoplay's 30 s repeat.
                #expect(engine.activeVoiceCount >= 2, "a playing sound was stopped")
                #expect(isPressedLit(s, x: 0, y: 0), "the finger's pad was released")
                let progress = runner.progress
                try await s.waitWhile { runner.progress <= progress }
                #expect(runner.progress > progress, "autoplay stopped moving")
                s.release(0, 0)
            }
        }

        @Test func aClosedPlayScreenNoLongerHearsTheRoute() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                let runner = try await startAutoplay(s, reaching: Self.allKindsStarted)
                s.vm.cleanup()
                #expect(!engine.isObservingSession)
                let progress = runner.progress
                let reports = observeInterruptions(engine)
                let plays = engine.playsStarted

                loseOutput(engine, leaving: [.builtInSpeaker])
                engine.currentOutputPorts = { [.headphones] }
                postRouteChange(.newDeviceAvailable)
                try await Task.sleep(for: .milliseconds(300))

                #expect(reports.all.isEmpty, "a closed screen's engine heard the route change")
                #expect(engine.playsStarted == plays)
                #expect(runner.progress == progress)
            }
        }

        // MARK: Repeated and empty cases

        @Test func aRepeatedLossPausesOnceAndPlayStillResumes() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                let runner = try await startAutoplay(s, reaching: Self.allKindsStarted)
                loseOutput(engine, leaving: [.builtInSpeaker])
                let pausedAt = runner.progress
                let plays = engine.playsStarted

                loseOutput(engine, leaving: [.builtInSpeaker])
                loseOutput(engine, leaving: [.builtInSpeaker])
                try await waitForRecovery(s, engine, untilSettled: true)

                #expect(!s.vm.isAutoPlayPlaying)
                #expect(runner.progress == pausedAt)
                #expect(engine.playsStarted == plays)
                s.vm.autoPlayResume()
                #expect(s.vm.isAutoPlayPlaying)
                try await s.waitWhile { runner.progress <= pausedAt }
                #expect(runner.progress > pausedAt)
            }
        }

        @Test func autoplayTheUserPausedStaysPausedAndResumes() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                let runner = try await startAutoplay(s, reaching: Self.allKindsStarted)
                s.vm.autoPlayPause()
                let pausedAt = runner.progress

                loseOutput(engine, leaving: [.builtInSpeaker])
                try await waitForRecovery(s, engine, untilSettled: true)
                try await Task.sleep(for: .milliseconds(300))

                #expect(!s.vm.isAutoPlayPlaying)
                #expect(runner.progress == pausedAt)
                s.vm.autoPlayResume()
                #expect(s.vm.isAutoPlayPlaying)
                #expect(runner.progress == pausedAt)
                try await s.waitWhile { runner.progress <= pausedAt }
                #expect(runner.progress > pausedAt)
            }
        }

        @Test func nothingPlayingStaysQuietAndPadsStillSound() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                #expect(engine.activeVoiceCount == 0)

                loseOutput(engine, leaving: [.builtInSpeaker])
                loseOutput(engine, leaving: [.builtInSpeaker])
                try await waitForRecovery(s, engine, untilSettled: true)

                #expect(s.vm.playMode == .none, "losing the output chose a mode")
                #expect(!s.vm.isAutoPlayPlaying)
                #expect(engine.playsStarted == 0)
                s.press(1, 0); s.release(1, 0)
                #expect(engine.playsStarted == 1)
            }
        }

        // MARK: Calls, other apps and the engine

        enum LaterRecovery: String, CaseIterable {
            case callEndsWithResume, appReturns, engineRestarts
        }

        @Test(arguments: LaterRecovery.allCases)
        func aLaterRecoveryKeepsWaitingForPlay(_ recovery: LaterRecovery) async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                let runner = try await startAutoplay(s, reaching: Self.allKindsStarted)
                s.press(0, 0)
                loseOutput(engine, leaving: [.builtInSpeaker])
                let pausedAt = runner.progress
                let plays = engine.playsStarted

                switch recovery {
                case .callEndsWithResume:
                    engine.handleInterruption(interruption(.began))
                    engine.handleInterruption(interruption(.ended, shouldResume: true))
                case .appReturns:
                    s.vm.onPause()
                    s.vm.onResume()
                case .engineRestarts:
                    let rendering = PlayInterruptionTests.RenderingState()
                    let original = engine.activateSessionForRecovery
                    engine.isEngineRunningForRecovery = { rendering.isRunning }
                    engine.activateSessionForRecovery = { try original(); rendering.recover() }
                    engine.handleConfigurationChange()
                }
                try await waitForRecovery(s, engine, untilSettled: true)
                try await Task.sleep(for: .milliseconds(500))

                #expect(!s.vm.isAutoPlayPlaying, "a later recovery resumed autoplay")
                #expect(runner.progress == pausedAt)
                #expect(engine.activeVoiceCount == 0, "a later recovery brought a stopped sound back")
                #expect(engine.playsStarted == plays)
                s.release(0, 0)
                #expect(engine.playsStarted == plays)
                s.vm.autoPlayResume()
                #expect(s.vm.isAutoPlayPlaying)
                #expect(runner.progress == pausedAt)
            }
        }

        @Test func aFailedEngineRecoveryKeepsAutoplayPausedAndPadsSilent() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                let runner = try await startAutoplay(s, reaching: Self.allKindsStarted)
                let original = engine.activateSessionForRecovery
                let rendering = PlayInterruptionTests.RenderingState()
                engine.isEngineRunningForRecovery = { rendering.isRunning }
                engine.activateSessionForRecovery = { throw CocoaError(.featureUnsupported) }

                loseOutput(engine, leaving: [.builtInSpeaker])
                try await s.waitWhile { engine.isRecoveringPlayback }
                #expect(engine.isPlaybackSuppressed, "the engine was taken as running")
                let pausedAt = runner.progress
                let plays = engine.playsStarted

                s.vm.autoPlayResume()
                try await s.waitWhile { engine.isRecoveringPlayback }
                try await Task.sleep(for: .milliseconds(300))
                #expect(!s.vm.isAutoPlayPlaying, "Play resumed autoplay on an engine that is not rendering")
                #expect(runner.progress == pausedAt)
                s.press(1, 0); s.release(1, 0)
                #expect(engine.playsStarted == plays, "a pad reached play() on an engine that is not rendering")

                engine.activateSessionForRecovery = { try original(); rendering.recover() }
                try await Task.sleep(for: .milliseconds(1100)) // a failed pad recovery waits 1 s
                s.vm.autoPlayResume()
                try await s.waitWhile { !s.vm.isAutoPlayPlaying }
                #expect(s.vm.isAutoPlayPlaying, "Play did not resume once the engine came back")
                #expect(!engine.isPlaybackSuppressed)
            }
        }

        // MARK: Helpers

        /// Keeps a finished one-shot's voice counted until the test lets it go, so a 60 ms sample is
        /// still playing when the output goes away however slow the machine is.
        private func holdOneShotCompletions(_ engine: SoundEngine) -> HeldCompletions {
            let held = HeldCompletions()
            engine.playbackCompletionDelivery = { _, _, complete in held.add(complete) }
            return held
        }

        final class HeldCompletions {
            private var pending: [() -> Void] = []
            func add(_ complete: @escaping () -> Void) { pending.append(complete) }
            func finish() { let all = pending; pending = []; all.forEach { $0() } }
        }
    }
}
#endif
