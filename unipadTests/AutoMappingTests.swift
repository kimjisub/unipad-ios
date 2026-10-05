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

                let deadline = Date().addingTimeInterval(10)
                while s.vm.autoMappingActive && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
                #expect(!s.vm.autoMappingActive, "auto mapping never finished")
                #expect(s.vm.autoPlayRunner != nil, "auto play was not restored after auto mapping")
            }
        }
    }
}
