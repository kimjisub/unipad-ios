import AVFoundation
import Foundation
import Testing
@testable import unipad

extension PlayUsageRecordTests {
    @MainActor
    struct StabilityBackportRegressionTests {
        @Test func releasingAfterAChainChangeStopsTheOriginalLoop() async throws {
            try await PlayUsageScenario.run(keySound: "1 1 1 a.wav 0\n2 1 1 a.wav\n") { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                s.press()
                try await Task.sleep(for: .milliseconds(200))
                #expect(engine.activeVoiceCount == 1)
                s.vm.selectChain(1)
                s.release()
                #expect(engine.activeVoiceCount == 0)
            }
        }

        @Test func returningWithoutAnInterruptionEndRestoresPadPlayback() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                s.press(); s.release()
                #expect(engine.playsStarted == 1)
                engine.handleInterruption(Notification(name: AVAudioSession.interruptionNotification,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]))
                s.vm.onResume()
                s.press(); s.release()
                #expect(engine.playsStarted == 2)
                #expect(!engine.isPlaybackSuppressed)
            }
        }
    }
}
