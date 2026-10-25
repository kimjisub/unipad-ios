#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
@testable import unipad

/// What the play screen does when another app takes the audio session (an incoming call, Siri, an
/// alarm) and when the app comes back. A simulator cannot raise a real interruption, so the
/// notification goes through the handler the system would call, and "the app is back" is the call
/// PlayView makes on `didBecomeActiveNotification`. Each check is about a request to play (a node
/// reaching `play()`), autoplay progress and pad lights, never about audible sound.
extension PlayUsageRecordTests {
    @MainActor
    struct PlayInterruptionTests {
        enum Boundary: CaseIterable {
            case appAway, covered, audioInterruption, routeLoss, mediaReset
        }

        @Test(arguments: Boundary.allCases, [PlayMode.autoPlay, .guidePlay, .stepPractice])
        func leavingPlayRequiresManualResume(boundary: Boundary, mode: PlayMode) async throws {
            for seconds in [1, 10] {
                try await Self.run { s in
                    try await s.loadReady()
                    let runner = try #require(s.vm.autoPlayRunner)
                    let engine = try #require(s.vm.soundEngine)
                    s.vm.switchPlayMode(mode)
                    try await s.waitWhile { runner.progress < 1 }
                    s.press() // A held human loop must be released in every mode too.
                    switch boundary {
                    case .appAway: s.vm.onPause()
                    case .covered: s.vm.screenCovered()
                    case .audioInterruption: engine.handleInterruption(interruption(.began))
                    case .routeLoss:
                        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
                            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
                    case .mediaReset: engine.handleMediaServicesReset()
                    }
                    let progress = runner.progress
                    #expect(!s.vm.isAutoPlayPlaying)
                    #expect(s.vm.playMode == mode)
                    #expect(engine.activePlayIDs.isEmpty)
                    try await Task.sleep(for: .seconds(seconds))
                    switch boundary {
                    case .covered: s.vm.screenShown()
                    case .audioInterruption:
                        engine.handleInterruption(interruption(.ended, shouldResume: true))
                        try await waitForRecovery(s, engine)
                    default: s.vm.onResume()
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    #expect(!s.vm.isAutoPlayPlaying)
                    #expect(runner.progress == progress)
                    #expect(s.vm.playMode == mode)
                    #expect(engine.activePlayIDs.isEmpty)
                    try await waitForRecovery(s, engine)
                    try #require(!engine.isPlaybackSuppressed)
                    s.vm.autoPlayResume()
                    #expect(s.vm.playMode == mode)
                    #expect(runner.playmode == (mode != .stepPractice))
                    #expect(!runner.isSuspended)
                }
            }
        }

        @Test func audioPermissionAndRepeatedReturnNeverResumeAutoplay() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)
                engine.handleInterruption(interruption(.began))
                let progress = runner.progress
                s.vm.autoPlayResume()
                #expect(!s.vm.isAutoPlayPlaying, "a request without audio permission must fail")
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                try await waitForRecovery(s, engine)
                s.vm.onResume()
                s.vm.onResume()
                try await Task.sleep(for: .milliseconds(300))
                #expect(!s.vm.isAutoPlayPlaying)
                #expect(runner.progress == progress)
                s.vm.autoPlayResume()
                #expect(s.vm.isAutoPlayPlaying)
            }
        }

        @Test func turningLightsOffDiscardsFiniteAnimations() async throws {
            try await PlayUsageScenario.run(keyLed: ["1 1 1 1": "on 1 1 a 5\ndelay 20000\non 1 2 a 9\n"]) { s in
                try await s.loadReady()
                s.vm.scbLed.forceSetChecked(true)
                s.press()
                let runner = try #require(s.vm.ledRunner)
                #expect(runner.isEventExist(x: 0, y: 0))
                let audio = s.vm.soundEngine?.activePlayIDs
                s.vm.scbLed.forceSetChecked(false)
                #expect(!runner.isEventExist(x: 0, y: 0), "finite animations must be discarded too")
                #expect(s.vm.soundEngine?.activePlayIDs == audio)
                s.vm.scbLed.forceSetChecked(true)
                #expect(!runner.isEventExist(x: 0, y: 0), "old animations returned when enabled")
            }
        }

        @Test(arguments: [0, 1, 2], [1, 10])
        func lightsOnlyResumeForNewInput(loop: Int, seconds: Int) async throws {
            try await PlayUsageScenario.run(keySound: "1 1 1 a.wav 0\n", autoPlay: "delay 60000\n",
                keyLed: ["1 1 1 \(loop)": "on 1 1 a 5\ndelay 100\non 1 2 a 9\ndelay 20000\n"]) { s in
                try await s.loadReady()
                s.vm.switchPlayMode(.autoPlay)
                let runner = try #require(s.vm.autoPlayRunner)
                try await s.waitWhile { runner.progress == 0 }
                s.press()
                let engine = try #require(s.vm.soundEngine)
                let audio = engine.activePlayIDs
                let lights = try #require(s.vm.ledRunner)
                s.vm.scbLed.forceSetChecked(false)
                #expect(!lights.isEventExist(x: 0, y: 0))
                let before = runner.progress
                try await Task.sleep(for: .seconds(seconds))
                #expect(engine.activePlayIDs == audio)
                #expect(s.vm.isAutoPlayPlaying)
                #expect(runner.progress == before) // Still inside the final 60-second wait.
                s.press() // Disabled input must not queue a scene.
                s.vm.scbLed.forceSetChecked(true)
                try await Task.sleep(for: .milliseconds(200))
                #expect(s.vm.channelManager?.get(x: 0, y: 1, channel: .led) == nil)
                #expect(!lights.isEventExist(x: 0, y: 0))
                s.press()
                try await s.waitWhile { s.vm.channelManager?.get(x: 0, y: 0, channel: .led) == nil }
                #expect(s.vm.channelManager?.get(x: 0, y: 0, channel: .led) != nil)
            }
        }

        @Test(arguments: [false, true])
        func losingSoundOutputRequiresManualResume(mediaReset: Bool) async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)
                if mediaReset {
                    engine.handleMediaServicesReset()
                } else {
                    NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
                        userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
                }
                #expect(!s.vm.isAutoPlayPlaying)
                #expect(runner.isSuspended)
                #expect(engine.activePlayIDs.isEmpty)
            }
        }

        @Test func aBatchFromBeforeDisablingLightsCannotReturnAfterReenabling() async throws {
            try await PlayUsageScenario.run(keyLed: ["1 1 1 1": "on 1 1 a 5\ndelay 20000\n"]) { s in
                try await s.loadReady()
                let adapter = LedListenerAdapter(viewModel: s.vm)
                adapter.onLedBatch([.padOn(x: 0, y: 0, color: 5, velocity: 5)], generation: 0)
                s.vm.scbLed.forceSetChecked(false)
                s.vm.scbLed.forceSetChecked(true)
                try await Task.sleep(for: .milliseconds(100))
                #expect(s.vm.channelManager?.get(x: 0, y: 0, channel: .led) == nil)
            }
        }

        /// Pad (1,1) loops forever (a keySound loop count of 0), (1,2) and (1,3) are one-shots.
        /// Autoplay holds (1,3) down for the whole run and keeps pressing (1,2), so it is still
        /// running and a pad is lit at any point.
        private static let keySound = "1 1 1 a.wav 0\n1 1 2 a.wav\n1 1 3 a.wav\n"
        private static let autoPlay = "on 1 3\n" + String(repeating: "on 1 2\ndelay 200\noff 1 2\n", count: 60)

        private static func run(_ body: (PlayUsageScenario) async throws -> Void) async throws {
            try await PlayUsageScenario.run(keySound: keySound, autoPlay: autoPlay, body)
        }

        private func interruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool = false) -> Notification {
            var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
            if shouldResume {
                info[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue
            }
            return Notification(name: AVAudioSession.interruptionNotification, object: nil, userInfo: info)
        }

        private func startAutoplay(_ s: PlayUsageScenario) async throws -> AutoPlayRunner {
            let runner = try #require(s.vm.autoPlayRunner)
            s.vm.switchPlayMode(.autoPlay)
            try await s.waitWhile { runner.progress < 3 }
            try #require(runner.progress >= 3, "autoplay never started")
            return runner
        }

        /// Taking the session back runs on the audio session worker and reports on the main queue.
        private func waitForRecovery(_ s: PlayUsageScenario, _ engine: SoundEngine) async throws {
            try await s.waitWhile { engine.isPlaybackSuppressed }
        }

        /// What the engine reported to the screen, in order, after the screen's own handler ran.
        private func observeInterruptions(_ engine: SoundEngine) -> Reports {
            let reports = Reports()
            let screen = engine.onInterruption
            engine.onInterruption = { interruption in
                screen?(interruption)
                reports.all.append(interruption)
            }
            return reports
        }

        /// Waits for a report instead of a fixed time: the worker may be slow on a loaded machine.
        private func waitForReport(
            _ s: PlayUsageScenario, _ reports: Reports, _ matches: (SoundEngine.Interruption) -> Bool
        ) async throws {
            let seen = reports.all.count
            func reported() -> Bool { reports.all.dropFirst(seen).contains(where: matches) }
            try await s.waitWhile { !reported() }
            let found = reported()
            try #require(found, "the engine never reported it")
        }

        /// The app comes back to the front again, now with the session, and autoplay stays paused.
        private func expectALaterReturnLeavesAutoplayPaused(
            _ s: PlayUsageScenario, _ engine: SoundEngine, _ runner: AutoPlayRunner, _ reports: Reports,
            _ activate: @escaping () throws -> Void
        ) async throws {
            engine.activateSessionForRecovery = activate
            s.vm.onResume()
            try await waitForReport(s, reports) { $0 == .appReturned(recovered: true) }
            let pausedAt = runner.progress
            try await Task.sleep(for: .milliseconds(500))

            #expect(!s.vm.isAutoPlayPlaying, "a later return resumed autoplay")
            #expect(runner.progress == pausedAt)
            #expect(s.vm.playMode == .autoPlay, "the user's choice of autoplay is kept for them to resume")
        }

        final class Reports {
            var all: [SoundEngine.Interruption] = []
        }

        /// The first try to take the session back fails, as it does in the background; later ones run
        /// `then`. Called on the audio session worker.
        nonisolated final class FailsFirstActivation: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            private let then: () throws -> Void

            init(then: @escaping () throws -> Void) { self.then = then }

            var calls: Int { lock.withLock { count } }

            func activate() throws {
                let call = lock.withLock { count += 1; return count }
                if call == 1 { throw CocoaError(.featureUnsupported) }
                try then()
            }
        }

        private func isPressedLit(_ s: PlayUsageScenario, x: Int, y: Int) -> Bool {
            s.vm.channelManager?.get(x: x, y: y, channel: .pressed) != nil
        }

        /// Apple: a began interruption is not always followed by an ended one; after a call is
        /// answered the app is suspended and may never hear the end. Coming back to the app has to
        /// bring the sound back on its own.
        @Test func aPadSoundsAgainWhenTheAppComesBackFromAnInterruptionThatNeverEnded() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                s.press(0, 1); s.release(0, 1)
                #expect(engine.playsStarted == 1)

                engine.handleInterruption(interruption(.began))
                s.vm.onResume()
                try await waitForRecovery(s, engine)
                s.press(0, 1); s.release(0, 1)

                #expect(engine.playsStarted == 2, "the pad after coming back was not requested to play")
                #expect(!engine.isPlaybackSuppressed)
            }
        }

        private func expectManualResume(_ s: PlayUsageScenario, _ runner: AutoPlayRunner, pausedAt: Int) async throws {
            try await Task.sleep(for: .milliseconds(100))
            #expect(!s.vm.isAutoPlayPlaying)
            #expect(runner.progress == pausedAt)
            s.vm.autoPlayResume()
            #expect(s.vm.isAutoPlayPlaying)
            try await s.waitWhile { runner.progress <= pausedAt }
            #expect(runner.progress > pausedAt)
        }

        @Test func autoplayPausesDuringAnInterruptionAndWaitsForTheUser() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                #expect(isPressedLit(s, x: 0, y: 2))
                let engine = try #require(s.vm.soundEngine)

                engine.handleInterruption(interruption(.began))
                #expect(!s.vm.isAutoPlayPlaying, "autoplay kept playing during the interruption")
                #expect(!isPressedLit(s, x: 0, y: 2), "the pad autoplay held stayed lit")
                let pausedAt = runner.progress
                try await Task.sleep(for: .milliseconds(700))
                #expect(runner.progress == pausedAt, "autoplay moved on silently during the interruption")

                engine.handleInterruption(interruption(.ended, shouldResume: true))
                try await waitForRecovery(s, engine)
                try await expectManualResume(s, runner, pausedAt: pausedAt)
            }
        }

        @Test func autoplayWaitsForManualResumeWhenTheAppComesBackRightAfterAResumableEnd() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)

                engine.handleInterruption(interruption(.began))
                let pausedAt = runner.progress
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                s.vm.onResume()
                try await waitForRecovery(s, engine)

                try await expectManualResume(s, runner, pausedAt: pausedAt)
            }
        }

        @Test func autoplayWaitsForManualResumeAfterASecondInterruptionThatOvertookTheFirstOnesRecovery() async throws {
            try await Self.run { s in
                try await s.loadReady()
                _ = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)

                engine.handleInterruption(interruption(.began))
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                engine.handleInterruption(interruption(.began))
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                try await waitForRecovery(s, engine)

                #expect(!s.vm.isAutoPlayPlaying, "an allowed end must still wait for the user")
            }
        }

        @Test func autoplayStaysPausedWhenTheSessionCannotBeTakenBackAfterAResumableEnd() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)
                engine.activateSessionForRecovery = { throw CocoaError(.featureUnsupported) }

                engine.handleInterruption(interruption(.began))
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                let pausedAt = runner.progress
                try await Task.sleep(for: .milliseconds(500))

                #expect(engine.isPlaybackSuppressed)
                #expect(!s.vm.isAutoPlayPlaying, "autoplay resumed without sound")
                #expect(runner.progress == pausedAt)
                #expect(s.vm.playMode == .autoPlay, "the user's choice of autoplay is kept for them to resume")
            }
        }

        @Test func autoplayWaitsForManualResumeWhenTheAppComesBackWithTheSessionAfterAResumableEndFailed() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)
                let reported = observeInterruptions(engine)
                let activate = engine.activateSessionForRecovery
                engine.activateSessionForRecovery = { throw CocoaError(.featureUnsupported) }
                engine.isAppInFront = { false }

                engine.handleInterruption(interruption(.began))
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                try await waitForReport(s, reported) { if case .ended = $0 { true } else { false } }
                #expect(!s.vm.isAutoPlayPlaying, "autoplay resumed without sound")
                let pausedAt = runner.progress

                engine.activateSessionForRecovery = activate
                engine.isAppInFront = { true }
                s.vm.onResume()
                try await waitForRecovery(s, engine)

                try await expectManualResume(s, runner, pausedAt: pausedAt)
            }
        }

        @Test func autoplayWaitsForManualResumeWhenTheAppComesBackWhileTheBackgroundTryIsStillFailing() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)
                let activate = engine.activateSessionForRecovery
                let firstTry = FailsFirstActivation(then: activate)
                engine.activateSessionForRecovery = { try firstTry.activate() }
                engine.isAppInFront = { false }

                engine.handleInterruption(interruption(.began))
                let pausedAt = runner.progress
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                engine.isAppInFront = { true }
                s.vm.onResume()
                try await waitForRecovery(s, engine)

                #expect(firstTry.calls == 2, "coming back did not try to take the session again")
                try await expectManualResume(s, runner, pausedAt: pausedAt)
            }
        }

        @Test func autoplayStaysPausedWhenTheAppComesBackStillWithoutTheSession() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)
                let reported = observeInterruptions(engine)
                let activate = engine.activateSessionForRecovery
                engine.activateSessionForRecovery = { throw CocoaError(.featureUnsupported) }
                engine.isAppInFront = { false }

                engine.handleInterruption(interruption(.began))
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                try await waitForReport(s, reported) { if case .ended = $0 { true } else { false } }
                engine.isAppInFront = { true }
                s.vm.onResume()
                try await waitForReport(s, reported) { $0 == .appReturned(recovered: false) }
                #expect(engine.isPlaybackSuppressed)
                #expect(!s.vm.isAutoPlayPlaying, "autoplay resumed without sound")

                try await expectALaterReturnLeavesAutoplayPaused(s, engine, runner, reported, activate)
            }
        }

        @Test func autoplayStaysPausedOnALaterReturnAfterAResumableEndFailedInFront() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)
                let reported = observeInterruptions(engine)
                let activate = engine.activateSessionForRecovery
                engine.activateSessionForRecovery = { throw CocoaError(.featureUnsupported) }
                engine.isAppInFront = { true }

                engine.handleInterruption(interruption(.began))
                s.vm.onResume()
                try await waitForReport(s, reported) { $0 == .appReturned(recovered: false) }
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                try await waitForReport(s, reported) { if case .ended = $0 { true } else { false } }
                #expect(!s.vm.isAutoPlayPlaying, "autoplay resumed without sound")

                try await expectALaterReturnLeavesAutoplayPaused(s, engine, runner, reported, activate)
            }
        }

        @Test func autoplayStaysPausedWhenTheEndDoesNotSayResume() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)

                engine.handleInterruption(interruption(.began))
                engine.handleInterruption(interruption(.ended))
                let pausedAt = runner.progress
                try await Task.sleep(for: .milliseconds(500))

                #expect(!s.vm.isAutoPlayPlaying)
                #expect(runner.progress == pausedAt)
                #expect(s.vm.playMode == .autoPlay, "the user's choice of autoplay is kept for them to resume")
            }
        }

        @Test func autoplayTurnedOffDuringTheInterruptionStaysOff() async throws {
            try await Self.run { s in
                try await s.loadReady()
                _ = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)

                engine.handleInterruption(interruption(.began))
                s.vm.switchPlayMode(.none)
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                try await waitForRecovery(s, engine)

                #expect(!s.vm.isAutoPlayPlaying)
                #expect(s.vm.playMode == .none)
            }
        }

        @Test func aLaterShortInterruptionDoesNotRestartAutoplayPausedByACallThatNeverEnded() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)

                engine.handleInterruption(interruption(.began))
                s.vm.onResume()
                try await waitForRecovery(s, engine)
                #expect(!engine.isPlaybackSuppressed)
                #expect(!s.vm.isAutoPlayPlaying)

                engine.handleInterruption(interruption(.began))
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                try await waitForRecovery(s, engine)
                let pausedAt = runner.progress
                try await Task.sleep(for: .milliseconds(500))

                #expect(!s.vm.isAutoPlayPlaying, "autoplay the user left paused started by itself")
                #expect(runner.progress == pausedAt)
            }
        }

        @Test func autoplayTheUserPausedDuringTheInterruptionStaysPaused() async throws {
            try await Self.run { s in
                try await s.loadReady()
                _ = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)

                engine.handleInterruption(interruption(.began))
                s.vm.autoPlayResume()
                s.vm.autoPlayPause()
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                try await waitForRecovery(s, engine)

                #expect(!s.vm.isAutoPlayPlaying, "the end of the interruption overrode the user's pause")
            }
        }

        @Test func aModeChosenDuringTheInterruptionIsKept() async throws {
            try await Self.run { s in
                try await s.loadReady()
                _ = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)

                engine.handleInterruption(interruption(.began))
                s.vm.switchPlayMode(.stepPractice)
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                try await waitForRecovery(s, engine)

                #expect(s.vm.playMode == .stepPractice)
                #expect(!s.vm.isAutoPlayPlaying, "step practice was turned into a playing autoplay")
            }
        }

        @Test func anInterruptionReleasesALoopingPad() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                s.press(0, 0)
                // Longer than the one-shot sample, so only a loop can still hold a voice.
                try await Task.sleep(for: .milliseconds(300))
                #expect(engine.activeVoiceCount == 1)

                engine.handleInterruption(interruption(.began))

                #expect(engine.activeVoiceCount == 0, "the looping pad kept its voice through the interruption")
            }
        }

        @Test func goingHomeAndBackStopsTheLoopAndLeavesAutoplayPaused() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                s.press(0, 0)
                let runner = try await startAutoplay(s)

                s.vm.onPause()
                let progressWhileAway = runner.progress
                try await Task.sleep(for: .milliseconds(500))
                #expect(runner.progress == progressWhileAway)
                s.vm.onResume()

                #expect(engine.activeVoiceCount == 0)
                #expect(!s.vm.isAutoPlayPlaying)
                #expect(runner.active)
            }
        }

        // MARK: Covered by the device screen

        @Test func autoplayPausedForTheDeviceScreenWaitsAfterACallEnds() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)

                s.vm.screenCovered()
                engine.handleInterruption(interruption(.began))
                s.vm.screenShown()
                #expect(!s.vm.isAutoPlayPlaying, "autoplay resumed without sound")
                let pausedAt = runner.progress

                engine.handleInterruption(interruption(.ended, shouldResume: true))
                try await waitForRecovery(s, engine)

                try await expectManualResume(s, runner, pausedAt: pausedAt)
            }
        }

        @Test func autoplayPausedForTheDeviceScreenWaitsForTheScreenWhenACallEndsBehindIt() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)

                s.vm.screenCovered()
                engine.handleInterruption(interruption(.began))
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                try await waitForRecovery(s, engine)
                let pausedAt = runner.progress
                try await Task.sleep(for: .milliseconds(500))
                #expect(!s.vm.isAutoPlayPlaying, "autoplay started behind the device screen")
                #expect(runner.progress == pausedAt)

                s.vm.screenShown()
                try await expectManualResume(s, runner, pausedAt: pausedAt)
            }
        }

        @Test func autoplayPausedForTheDeviceScreenStaysPausedWhenTheSessionCannotBeTakenBack() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)
                let reported = observeInterruptions(engine)
                let activate = engine.activateSessionForRecovery
                engine.activateSessionForRecovery = { throw CocoaError(.featureUnsupported) }

                s.vm.screenCovered()
                engine.handleInterruption(interruption(.began))
                s.vm.screenShown()
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                try await waitForReport(s, reported) { if case .ended = $0 { true } else { false } }
                #expect(engine.isPlaybackSuppressed)
                #expect(!s.vm.isAutoPlayPlaying, "autoplay resumed without sound")

                try await expectALaterReturnLeavesAutoplayPaused(s, engine, runner, reported, activate)
            }
        }

        @Test func autoplayPausedForTheDeviceScreenStaysPausedAfterACallThatNeverEnded() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)

                s.vm.screenCovered()
                engine.handleInterruption(interruption(.began))
                s.vm.screenShown()
                try await waitForRecovery(s, engine)
                let pausedAt = runner.progress
                try await Task.sleep(for: .milliseconds(500))

                #expect(!engine.isPlaybackSuppressed)
                #expect(!s.vm.isAutoPlayPlaying, "autoplay started after a call that never ended")
                #expect(runner.progress == pausedAt)
                #expect(s.vm.playMode == .autoPlay, "the user's choice of autoplay is kept for them to resume")
            }
        }

        @Test func autoplayTheUserPausedAfterTheDeviceScreenStaysPausedWhenTheCallEnds() async throws {
            try await Self.run { s in
                try await s.loadReady()
                _ = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)

                s.vm.screenCovered()
                engine.handleInterruption(interruption(.began))
                s.vm.screenShown()
                s.vm.autoPlayResume()
                s.vm.autoPlayPause()
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                try await waitForRecovery(s, engine)
                try await Task.sleep(for: .milliseconds(300))

                #expect(!s.vm.isAutoPlayPlaying, "the end of the call overrode the user's pause")
            }
        }

        @Test func autoplayOfAPlayScreenClosedDuringACallStaysStoppedWhenTheCallEnds() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)

                s.vm.screenCovered()
                engine.handleInterruption(interruption(.began))
                s.vm.cleanup()
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                try await Task.sleep(for: .milliseconds(500))

                #expect(!s.vm.isAutoPlayPlaying)
                #expect(!runner.playmode, "the closed screen's autoplay started again")
            }
        }
    }
}
#endif
