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
        @Test(arguments: [false, true], [PlayMode.autoPlay, .guidePlay, .stepPractice])
        func leavingPlayRequiresManualResume(covered: Bool, mode: PlayMode) async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try #require(s.vm.autoPlayRunner)
                s.vm.switchPlayMode(mode)
                try await s.waitWhile { runner.progress < 1 }
                if covered { s.vm.screenCovered() } else { s.vm.onPause() }
                let progress = runner.progress
                #expect(!s.vm.isAutoPlayPlaying)
                #expect(s.vm.playMode == mode)
                #expect(s.vm.soundEngine?.activePlayIDs.isEmpty == true)
                if covered { s.vm.screenShown() } else { s.vm.onResume() }
                try await Task.sleep(for: .milliseconds(300))
                #expect(!s.vm.isAutoPlayPlaying)
                #expect(runner.progress == progress)
                #expect(s.vm.playMode == mode)
            }
        }

        @Test func audioPermissionAndRepeatedReturnNeverResumeAutoplay() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)
                engine.handleInterruption(interruption(.began))
                let progress = runner.progress
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

        /// Android pauses autoplay on a short loss of audio focus and resumes it when focus returns;
        /// the iPhone follows the same rule with the interruption's `.shouldResume`.
        @Test func autoplayPausesDuringAnInterruptionAndResumesWhenTheEndSaysSo() async throws {
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
                #expect(s.vm.isAutoPlayPlaying)
                try await s.waitWhile { runner.progress <= pausedAt }
                #expect(runner.progress > pausedAt, "autoplay did not continue after the interruption")
            }
        }

        /// The call screen closes: the end of the interruption and the app coming back arrive together,
        /// before the session has been taken back. Autoplay still resumes.
        @Test func autoplayResumesWhenTheAppComesBackRightAfterAResumableEnd() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let runner = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)

                engine.handleInterruption(interruption(.began))
                let pausedAt = runner.progress
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                s.vm.onResume()
                try await waitForRecovery(s, engine)
                try await s.waitWhile(timeout: 2) { !s.vm.isAutoPlayPlaying }

                #expect(s.vm.isAutoPlayPlaying, "autoplay stayed paused after a resumable end")
                try await s.waitWhile { runner.progress <= pausedAt }
                #expect(runner.progress > pausedAt)
            }
        }

        /// A second interruption begins before the session was taken back after the first. The first
        /// one paused autoplay, and the end of the second resumes it.
        @Test func autoplayResumesAfterASecondInterruptionThatOvertookTheFirstOnesRecovery() async throws {
            try await Self.run { s in
                try await s.loadReady()
                _ = try await startAutoplay(s)
                let engine = try #require(s.vm.soundEngine)

                engine.handleInterruption(interruption(.began))
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                engine.handleInterruption(interruption(.began))
                engine.handleInterruption(interruption(.ended, shouldResume: true))
                try await waitForRecovery(s, engine)
                try await s.waitWhile(timeout: 2) { !s.vm.isAutoPlayPlaying }

                #expect(s.vm.isAutoPlayPlaying, "the second end forgot that the first paused autoplay")
            }
        }

        /// The end says playback may resume, but the app cannot take the session back (another app
        /// still holds it). Resuming would run autoplay with its lights and no sound, so it stays
        /// paused for the user, as on Android when audio focus is lost for good.
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

        /// The end said playback may resume but came while the app was in the background, where a
        /// session that does not mix with others cannot be taken back. The app coming back to the front
        /// takes it back, and autoplay continues as it would after going home and back without a call.
        @Test func autoplayResumesWhenTheAppComesBackWithTheSessionAfterAResumableEndFailed() async throws {
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
                try await s.waitWhile(timeout: 2) { !s.vm.isAutoPlayPlaying }

                #expect(s.vm.isAutoPlayPlaying, "autoplay stayed paused after the app took the session back")
                try await s.waitWhile { runner.progress <= pausedAt }
                #expect(runner.progress > pausedAt)
            }
        }

        /// The app comes back while the try made in the background for a resumable end is still on the
        /// worker, as when the call screen closes. That try fails; the one made on coming back takes the
        /// session, and autoplay continues.
        @Test func autoplayResumesWhenTheAppComesBackWhileTheBackgroundTryIsStillFailing() async throws {
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
                try await s.waitWhile(timeout: 2) { !s.vm.isAutoPlayPlaying }

                #expect(firstTry.calls == 2, "coming back did not try to take the session again")
                #expect(s.vm.isAutoPlayPlaying, "autoplay stayed paused although the app took the session back")
                try await s.waitWhile { runner.progress <= pausedAt }
                #expect(runner.progress > pausedAt)
            }
        }

        /// The app came back but another app still holds the session: autoplay stays paused, and a later
        /// return that gets the session no longer resumes it; by then it is the user's to resume.
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

        /// The app was already in front when the resumable end came, and another app still held the
        /// session. A later return to the front (Control Center pulled down and back) has nothing to do
        /// with the call and does not start autoplay.
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

        /// The user turned autoplay off while the call was on; the end of the call must not restart it.
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

        /// A call that was answered pauses autoplay and never sends its end; the app takes the session
        /// back when it returns and the user leaves autoplay paused. A later short interruption (Siri,
        /// an alarm) that ends with `.shouldResume` is a new one and must not start autoplay again.
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

        /// The user played and paused autoplay again while the call was on; their last choice stands.
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

        /// The user switched to step practice while the call was on; the end must not turn it back
        /// into a playing autoplay.
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

        /// Records, without changing it, what leaving the screen for the home screen and coming back
        /// does: the screen pauses MIDI and the volume observer only, so a held loop keeps its voice
        /// and autoplay keeps its place and keeps running. (Without a background audio mode iOS
        /// suspends the app, so on a device nothing renders while it is away; that part is not
        /// checked here.)
        @Test func goingHomeAndBackLeavesTheLoopAndAutoplayRunning() async throws {
            try await Self.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                s.press(0, 0)
                let runner = try await startAutoplay(s)

                s.vm.onPause()
                let progressWhileAway = runner.progress
                try await Task.sleep(for: .milliseconds(500))
                #expect(runner.progress > progressWhileAway, "autoplay is expected to keep running while away")
                s.vm.onResume()

                #expect(engine.activeVoiceCount >= 1, "the held loop is expected to keep its voice")
                #expect(s.vm.isAutoPlayPlaying)
                #expect(runner.active)
            }
        }

        // MARK: Covered by the device screen

        /// Autoplay paused because the device screen (opened from the connection banner) covers the play
        /// screen counts as playing for an interruption meanwhile: the call's end decides, as it would
        /// without the device screen. Here the call is still on when the play screen is shown again, and
        /// its resumable end comes after the return.
        @Test func autoplayPausedForTheDeviceScreenResumesWhenACallMeanwhileEndsAfterTheReturn() async throws {
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
                try await s.waitWhile(timeout: 2) { !s.vm.isAutoPlayPlaying }

                #expect(s.vm.isAutoPlayPlaying, "autoplay stayed paused after the call ended with the session back")
                try await s.waitWhile { runner.progress <= pausedAt }
                #expect(runner.progress > pausedAt)
            }
        }

        /// The call ends while the device screen still covers the play screen: autoplay does not start
        /// behind it, and continues when the play screen is shown.
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
                #expect(s.vm.isAutoPlayPlaying, "autoplay stayed paused when the play screen was shown again")
                try await s.waitWhile { runner.progress <= pausedAt }
                #expect(runner.progress > pausedAt)
            }
        }

        /// The call ends after the return, but the session cannot be taken back: autoplay stays paused,
        /// and a later return that gets the session leaves it to the user, as without the device screen.
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

        /// A call that was answered never sends its end; on coming back the session is taken back and
        /// autoplay is the user's to resume, as without the device screen.
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

        /// After the return the user played and paused autoplay while the call was still on; the end of
        /// the call does not override their pause.
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

        /// The play screen was closed from under the device screen while the call was on; its end does
        /// not start the closed screen's autoplay.
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
