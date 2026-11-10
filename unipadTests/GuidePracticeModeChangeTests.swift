#if canImport(UIKit)
import Foundation
import Testing
@testable import unipad

extension PlayUsageRecordTests {
    /// Switching into the guide, pausing it in its last wait, and pausing it before the app leaves.
    /// The screen, the pack and the sound engine are the real ones; each runner pass is released by
    /// the test on a clock only the test moves. Times are song times: milliseconds after the start.
    @MainActor
    struct GuidePracticeModeChangeTests {
        typealias Pad = StepReturnAutoplayTests.Pad
        typealias GatedScreen = StepReturnAutoplayTests.GatedScreen

        private static let keySound = "1 1 1 a.wav\n1 1 2 a.wav\n1 2 1 a.wav\n1 2 2 a.wav\n"
        private static let grid = PlayUsageScenario.PackGrid(buttonX: 2, buttonY: 2, chain: 1)

        /// Starts `mode` on a song clock at 0 and waits for the run's first pass.
        private static func start(_ mode: PlayMode, on screen: GatedScreen) async throws -> (Int64) async throws -> Void {
            let origin = screen.clock.read()
            screen.s.vm.switchPlayMode(mode)
            try await screen.s.waitWhile { screen.ticks == 0 }
            try #require(screen.ticks > 0, "the run never passed")
            return { songMs in try await screen.tick(at: origin + songMs) }
        }

        /// Autoplay has played pad (1,1); the guide that starts now begins at the next line.
        @Test func theGuideStartsAtTheNextUnplayedLine() async throws {
            let text = "o 1 1\nf 1 1\nd 1000\no 1 2\nf 1 2\nd 1000\no 2 1\nf 2 1\nd 1000\n"
            try await PlayUsageScenario.run(keySound: Self.keySound, autoPlay: text, grid: Self.grid) { s in
                let screen = GatedScreen(s)
                try await s.loadReady()
                defer { screen.stop() }
                let origin = screen.clock.read()
                let tick = try await Self.start(.autoPlay, on: screen)
                let recorder = try #require(screen.outputs)
                try #require(recorder.inputs.map(\.pad) == [Pad(x: 0, y: 0)], "autoplay did not play the first pad")
                try await tick(300)
                s.vm.switchPlayMode(.guidePlay)
                try #require(s.vm.playMode == .guidePlay)
                for at: Int64 in [300, 1000, 2000] { try await tick(at) }
                #expect(recorder.guides.map(\.pad) == [Pad(x: 0, y: 1), Pad(x: 1, y: 0)],
                        "a pad autoplay already played is guided again")
                #expect(recorder.guides.map { $0.target - origin } == [1000, 2000])
            }
        }

        /// Pausing during the song's final wait keeps what is left of it; the guide ends only after
        /// that remainder has passed once Play is pressed again.
        @Test func pausingTheLastWaitKeepsItsRemainder() async throws {
            let text = "o 1 1\nf 1 1\nd 1000\n"
            try await PlayUsageScenario.run(keySound: Self.keySound, autoPlay: text, grid: Self.grid) { s in
                let screen = GatedScreen(s)
                try await s.loadReady()
                defer { screen.stop() }
                let runner = try #require(s.vm.autoPlayRunner)
                let tick = try await Self.start(.guidePlay, on: screen)
                let recorder = try #require(screen.outputs)
                try await tick(400)
                try #require(runner.progress == 3, "the final wait was not reached")
                s.vm.autoPlayPause()
                try await tick(400)
                try await tick(5000)
                #expect(recorder.ends == 0, "pausing the last wait ended the guide")
                #expect(runner.active)
                guard runner.active else { return }
                try await screen.resume()
                try #require(s.vm.playMode == .guidePlay)
                try await tick(5000)
                try await tick(5599)
                #expect(recorder.ends == 0, "the guide ended before the remaining 600 ms")
                try await tick(5600)
                #expect(recorder.ends == 1, "the guide did not end after the remaining wait")
                #expect(!runner.active)
            }
        }

        /// Pause the guide, leave the app and come back, then press Play once: the screen is in the
        /// same state as pressing Play once without leaving.
        @Test(arguments: [false, true])
        func playAfterAPausedGuideAndAnAppReturn(leaveTheApp: Bool) async throws {
            let text = "d 1000\no 1 1\nf 1 1\nd 1000\no 1 2\nf 1 2\nd 1000\n"
            try await PlayUsageScenario.run(keySound: Self.keySound, autoPlay: text, grid: Self.grid) { s in
                let screen = GatedScreen(s)
                try await s.loadReady()
                defer { screen.stop() }
                let runner = try #require(s.vm.autoPlayRunner)
                let origin = screen.clock.read()
                let tick = try await Self.start(.guidePlay, on: screen)
                let recorder = try #require(screen.outputs)
                try await tick(500)
                try #require(recorder.guides.map(\.pad) == [Pad(x: 0, y: 0)], "the first guide did not show")
                s.vm.autoPlayPause()
                try await tick(500)
                #expect(s.vm.playMode == .stepPractice)
                if leaveTheApp {
                    s.vm.onPause()
                    try await tick(500)
                    try await tick(3500)
                    s.vm.onResume()
                }
                try await tick(3500)
                let before = recorder.guides.count
                try await screen.resume()
                try await tick(3500)
                #expect(s.vm.playMode == .guidePlay)
                #expect(s.vm.isAutoPlayPlaying)
                #expect(runner.playmode && runner.practiceGuide && !runner.stepMode)
                for at: Int64 in [4000, 5000] { try await tick(at) }
                let resumed = recorder.guides.dropFirst(before)
                print("guide-return leave=\(leaveTheApp) mode=\(s.vm.playMode) "
                      + "guides=\(resumed.map { "\($0.pad) target=\($0.target - origin) shown=\($0.emitted - origin)" })")
                // The note paused before its time keeps its place: 500 ms after Play, then the next.
                #expect(resumed.map(\.pad) == [Pad(x: 0, y: 0), Pad(x: 0, y: 1)])
                #expect(resumed.map { $0.target - origin } == [4000, 5000])
                #expect(recorder.inputs.isEmpty)
            }
        }
    }
}
#endif
