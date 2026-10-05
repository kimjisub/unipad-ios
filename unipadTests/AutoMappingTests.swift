import Foundation
import Testing
@testable import unipad

/// The option panel's auto mapping stops the auto play runner, rewrites the pack's autoPlay and
/// then has to finish: the progress row goes away and auto play is available again.
extension PlayUsageRecordTests {
    @MainActor
    struct AutoMappingTests {
        @Test func autoMappingFinishesAndRestoresAutoPlay() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                try #require(s.vm.autoPlayRunner != nil, "the fixture pack has no auto play")

                s.vm.autoMapping()
                #expect(s.vm.autoMappingActive)

                try await s.waitWhile { s.vm.autoMappingActive }
                #expect(!s.vm.autoMappingActive, "auto mapping never finished")
                #expect(s.vm.autoPlayRunner != nil, "auto play was not restored after auto mapping")
            }
        }

        @Test func failedAutoMappingStillRestoresAutoPlay() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                // Without the file the mapper cannot back it up and fails before writing.
                try s.removePackFile("autoPlay")

                s.vm.autoMapping()
                try await s.waitWhile { s.vm.autoMappingActive }
                #expect(!s.vm.autoMappingActive, "auto mapping never finished")
                #expect(s.vm.toastMessage != nil, "the failure was not shown")
                #expect(s.vm.autoPlayRunner != nil, "auto play was not restored after a failed auto mapping")
            }
        }

        @Test func autoMappingDuringAutoPlayResetsPlayState() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                s.vm.switchPlayMode(.autoPlay)
                try #require(s.vm.isAutoPlayPlaying)

                s.vm.autoMapping()
                #expect(s.vm.playMode == .none)
                #expect(!s.vm.isAutoPlayPlaying, "auto play still shows as playing after its runner was stopped")
                try await s.waitWhile { s.vm.autoMappingActive }
            }
        }
    }
}
