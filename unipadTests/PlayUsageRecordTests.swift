import Foundation
import Testing
@testable import unipad

/// Recovered scenarios share one serialized scope. Assertions are ordinary failures, including
/// missing readiness or runner completion; no known-issue wrapper can swallow an observation error.
@MainActor
@Suite(.serialized)
struct PlayUsageRecordTests {
    @Test func menuOnlyRecordsNoPlay() async throws {
        try await PlayUsageScenario.run { s in
            try await s.loadReady()
            s.vm.toggleOptionWindow(true)
            s.vm.toggleOptionWindow(false)
            s.vm.cleanup()
            #expect(s.sink.events.map(\.name) == ["pack_load"])
        }
    }

    @Test func screenPressRecordsOneFirstInputAndOneEnd() async throws {
        try await PlayUsageScenario.run { s in
            try await s.loadReady()
            s.press(); s.release(); s.press(0, 1); s.release(0, 1)
            s.vm.cleanup(); s.vm.cleanup(); s.press()
            #expect(s.starts == ["pad"])
            #expect(s.firstInputs == ["pad"])
            #expect(s.sink.events.map(\.name) == ["pack_load", "play_start", "play_first_input", "play_end"])
        }
    }

    @Test func beforeReadyReleaseAndInvalidPadsDoNotCount() async throws {
        try await PlayUsageScenario.run { s in
            try await s.load()
            try #require(!s.vm.startReady, "before-ready condition was not reached")
            s.press()
            try await s.ready()
            s.release(); s.press(-1, 0); s.press(8, 0); s.press(0, 8)
            #expect(s.starts.isEmpty)
            #expect(s.firstInputs.isEmpty)
            s.press(7, 7)
            #expect(s.starts == ["pad"])
            #expect(s.firstInputs == ["pad"])
        }
    }

    @Test func midiPadCountsButMenuAndChainDoNot() async throws {
        try await PlayUsageScenario.run { s in
            try await s.loadReady()
            s.vm.toggleOptionWindow(true)
            try await s.midi(cmd: 9, note: 81, velocity: 100)
            #expect(s.starts.isEmpty)
            s.vm.toggleOptionWindow(false)
            try await s.midi(cmd: 9, note: 89, velocity: 100) // Chain key, not a pad.
            #expect(s.firstInputs.isEmpty)
            try await s.midi(cmd: 9, note: 81, velocity: 100)
            try await s.midi(cmd: 9, note: 81, velocity: 0)
            try await s.midi(cmd: 9, note: 82, velocity: 100)
            #expect(s.starts == ["pad"])
            #expect(s.firstInputs == ["pad"])
        }
    }

    @Test(arguments: [PlayMode.stepPractice, PlayMode.guidePlay])
    func practiceSelectionAndLeavingDoNotCount(mode: PlayMode) async throws {
        try await PlayUsageScenario.run { s in
            try await s.loadReady()
            s.vm.switchPlayMode(mode)
            try await Task.sleep(for: .milliseconds(100))
            s.vm.cleanup()
            #expect(s.sink.events.map(\.name) == ["pack_load"])
        }
    }

    @Test(arguments: [PlayMode.stepPractice, PlayMode.guidePlay])
    func firstHumanPressInPracticeCounts(mode: PlayMode) async throws {
        try await PlayUsageScenario.run { s in
            try await s.loadReady()
            s.vm.switchPlayMode(mode)
            s.press(); s.release(); s.press(0, 1)
            #expect(s.starts == ["pad"])
            #expect(s.firstInputs == ["pad"])
        }
    }

    @Test func autoplayCountsOnItsFirstTouchAndNeverAsHuman() async throws {
        try await PlayUsageScenario.run { s in
            try await s.loadReady()
            s.vm.switchPlayMode(.autoPlay)
            #expect(s.starts.isEmpty, "mode selection is not a pad input")
            try await s.autoplayEnded()
            s.vm.cleanup()
            #expect(s.starts == ["autoplay"])
            #expect(s.firstInputs.isEmpty)
            #expect(s.sink.events(named: "play_end").count == 1)
        }
    }

    @Test func autoplayChosenBeforeReadyDoesNotCountAsHuman() async throws {
        try await PlayUsageScenario.run { s in
            try await s.load()
            try #require(!s.vm.startReady, "before-ready condition was not reached")
            s.vm.switchPlayMode(.autoPlay)
            try await s.ready()
            try await s.autoplayEnded()
            #expect(s.starts == ["autoplay"])
            #expect(s.firstInputs.isEmpty)
        }
    }

    @Test func switchingFromStepRecordsOnlyWhenAutomaticTouchArrives() async throws {
        try await PlayUsageScenario.run { s in
            try await s.loadReady()
            s.vm.switchPlayMode(.stepPractice)
            try await Task.sleep(for: .milliseconds(50))
            #expect(s.starts.isEmpty)
            s.vm.switchPlayMode(.autoPlay)
            try await s.autoplayEnded()
            #expect(s.starts == ["autoplay"])
            #expect(s.firstInputs.isEmpty)
        }
    }

    @Test func firstHumanAfterAutoplayIsNotLostOrDuplicated() async throws {
        try await PlayUsageScenario.run { s in
            try await s.loadReady()
            s.vm.switchPlayMode(.autoPlay)
            try await s.autoplayEnded()
            #expect(s.firstInputs.isEmpty)
            s.press(5, 5); s.release(5, 5); s.press(5, 6)
            #expect(s.starts == ["autoplay"])
            #expect(s.firstInputs == ["pad"])
        }
    }

    @Test func firstMidiAfterAutoplayIsNotLost() async throws {
        try await PlayUsageScenario.run { s in
            try await s.loadReady()
            s.vm.switchPlayMode(.autoPlay)
            try await s.autoplayEnded()
            try await s.midi(cmd: 9, note: 81, velocity: 100)
            #expect(s.starts == ["autoplay"])
            #expect(s.firstInputs == ["pad"])
        }
    }

    @Test func humanThenAutoplayKeepsOriginalStart() async throws {
        try await PlayUsageScenario.run { s in
            try await s.loadReady()
            s.press()
            s.vm.switchPlayMode(.autoPlay)
            try await s.autoplayEnded()
            #expect(s.starts == ["pad"])
            #expect(s.firstInputs == ["pad"])
        }
    }

    @Test func midiModeKeyDoesNotCountAsHuman() async throws {
        try await PlayUsageScenario.run { s in
            try await s.loadReady()
            try await s.midi(cmd: 11, note: 106, velocity: 127)
            try await s.autoplayEnded()
            #expect(s.starts == ["autoplay"])
            #expect(s.firstInputs.isEmpty)
        }
    }
}
