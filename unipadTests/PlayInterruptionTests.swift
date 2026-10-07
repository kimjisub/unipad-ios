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
                #expect(s.vm.isAutoPlayPlaying)
                try await s.waitWhile { runner.progress <= pausedAt }
                #expect(runner.progress > pausedAt, "autoplay did not continue after the interruption")
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
                #expect(!engine.isPlaybackSuppressed)
                #expect(!s.vm.isAutoPlayPlaying)

                engine.handleInterruption(interruption(.began))
                engine.handleInterruption(interruption(.ended, shouldResume: true))
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
    }
}
#endif
