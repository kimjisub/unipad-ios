import Testing
@testable import unipad

extension PlayUsageRecordTests {
    @MainActor
    struct AutoPlayRelaunchTests {
        @Test func guideAndAutoplayStartFromTheBeginningAfterSongEnd() async throws {
            try await PlayUsageScenario.run(autoPlay: "delay 400\non 1 1\ndelay 100\noff 1 1\n") { s in
                try await s.loadReady()
                let runner = try #require(s.vm.autoPlayRunner)
                let engine = try #require(s.vm.soundEngine)
                s.vm.switchPlayMode(.autoPlay)
                try await s.autoplayEnded()
                #expect(!runner.active)
                #expect(engine.playsStarted == 1)

                s.vm.switchPlayMode(.guidePlay)
                try await s.waitWhile { !s.vm.padGuideTargets.flatMap({ $0 }).contains(where: { $0 > 0 }) }
                #expect(s.vm.padGuideTargets[0][0] > 0, "The guide did not show the first pad")
                #expect(runner.progress < 4, "The guide must restart at the beginning")
                try await s.autoplayEnded()
                #expect(engine.playsStarted == 1, "A guide must not automatically play the pad")
                #expect(!runner.active)

                s.vm.switchPlayMode(.autoPlay)
                try await s.autoplayEnded()
                #expect(engine.playsStarted == 2, "Autoplay did not play the song again")
                #expect(!runner.active)
            }
        }
    }
}
