#if canImport(UIKit)
import Foundation
import Testing
@testable import unipad

extension PlayUsageRecordTests {
    /// Leaving the app in the middle of a guided group, coming back, then choosing sounding autoplay.
    /// The pack, the screen, the sound engine and the light runner are the real ones. Autoplay and
    /// lights run on one manual clock, so the time away and each written gap are exact.
    @MainActor
    struct StepReturnAutoplayTests {
        struct Pad: Hashable, CustomStringConvertible {
            let x: Int
            let y: Int
            var description: String { "\(x),\(y)" }
        }

        struct Note: Equatable {
            let pad: Pad
            let at: Int64
        }

        /// Records what a run asks for and passes it on to the screen's own listener.
        final class Outputs: AutoPlayRunner.Listener {
            private let screen: AutoPlayRunner.Listener
            private let playsStarted: () -> Int
            private(set) var inputs: [Note] = []
            private(set) var sounds: [Note] = []
            private(set) var ends = 0

            init(screen: AutoPlayRunner.Listener, playsStarted: @escaping () -> Int) {
                self.screen = screen
                self.playsStarted = playsStarted
            }

            func onPadTouchOn(x: Int, y: Int, inputID: UUID, scheduledAtMs: Int64) {
                let note = Note(pad: Pad(x: x, y: y), at: scheduledAtMs)
                inputs.append(note)
                let before = playsStarted()
                screen.onPadTouchOn(x: x, y: y, inputID: inputID, scheduledAtMs: scheduledAtMs)
                if playsStarted() > before { sounds.append(note) }
            }

            func onEnd() { ends += 1; screen.onEnd() }
            func onStart() { screen.onStart() }
            func onPadTouchOn(x: Int, y: Int, inputID: UUID) { screen.onPadTouchOn(x: x, y: y, inputID: inputID) }
            func onPadTouchOff(x: Int, y: Int, inputIDs: [UUID]) { screen.onPadTouchOff(x: x, y: y, inputIDs: inputIDs) }
            func onPadTouchOff(x: Int, y: Int, inputIDs: [UUID], scheduledAtMs: Int64) {
                screen.onPadTouchOff(x: x, y: y, inputIDs: inputIDs, scheduledAtMs: scheduledAtMs)
            }
            func onInputTimeThrough(_ at: Int64?) { screen.onInputTimeThrough(at) }
            func onPadTouchCancel(x: Int, y: Int, inputID: UUID) { screen.onPadTouchCancel(x: x, y: y, inputID: inputID) }
            func onChainChange(c: Int) { screen.onChainChange(c: c) }
            func onGuidePadOn(x: Int, y: Int, targetWallTimeMs: Int64) {
                screen.onGuidePadOn(x: x, y: y, targetWallTimeMs: targetWallTimeMs)
            }
            func onGuidePadOff(x: Int, y: Int) { screen.onGuidePadOff(x: x, y: y) }
            func onGuideLedUpdate(x: Int, y: Int, velocity: Int) { screen.onGuideLedUpdate(x: x, y: y, velocity: velocity) }
            func onGuideChainOn(c: Int) { screen.onGuideChainOn(c: c) }
            func onRemoveGuide() { screen.onRemoveGuide() }
            func chainButsRefresh() { screen.chainButsRefresh() }
            func onProgressUpdate(progress: Int) { screen.onProgressUpdate(progress: progress) }
        }

        @MainActor
        final class Passes {
            var count = 0
        }

        /// One screen whose autoplay and light runners read `clock`.
        @MainActor
        final class Screen {
            let s: PlayUsageScenario
            let clock = TestManualClock()
            private(set) var outputs: Outputs?
            private let passes = Passes()

            init(_ s: PlayUsageScenario) {
                self.s = s
                s.vm.makeLedRunner = { [clock] in LedRunner(unipack: $0, listener: $1, chain: $2, clock: { clock.read() }) }
                s.vm.makeAutoPlayRunner = { [weak self, weak vm = s.vm, clock, passes] pack, listener, chain in
                    let outputs = Outputs(screen: listener) { vm?.soundEngine?.playsStarted ?? 0 }
                    self?.outputs = outputs
                    return AutoPlayRunner(unipack: pack, listener: outputs, chain: chain, clock: { clock.read() }, sleep: { _ in
                        passes.count += 1
                        try await Task.sleep(for: .milliseconds(1))
                    })
                }
            }

            var plays: Int { s.vm.soundEngine?.playsStarted ?? 0 }

            func pads(lit channel: ChannelManager.Channel) -> Set<Pad> {
                var pads: Set<Pad> = []
                for x in 0..<8 {
                    for y in 0..<8 where s.vm.channelManager?.get(x: x, y: y, channel: channel) != nil {
                        pads.insert(Pad(x: x, y: y))
                    }
                }
                return pads
            }

            func waitForGuides(_ expected: Set<Pad>, _ comment: Comment) async throws {
                try await s.waitWhile { pads(lit: .guide) != expected }
                try #require(pads(lit: .guide) == expected, comment)
            }

            func waitForLights(_ expected: Set<Pad>, _ comment: Comment) async throws {
                try await s.waitWhile { pads(lit: .led) != expected }
                try #require(pads(lit: .led) == expected, comment)
            }

            /// A human tap, stamped on the clock the light runner reads.
            func tap(_ pad: Pad) {
                s.vm.padTouch(x: pad.x, y: pad.y, isDown: true, trigger: .pad(.screen), ledTimeMs: clock.read())
                s.vm.padTouch(x: pad.x, y: pad.y, isDown: false, trigger: .pad(.screen), ledTimeMs: clock.read())
            }

            /// Waits for two whole runner passes at the clock's current time.
            func settle() async throws {
                let target = passes.count + 2
                try await s.waitWhile { passes.count < target && s.vm.autoPlayRunner?.active == true }
            }

            func advance(_ ms: Int64) async throws {
                clock.advance(ms)
                try await settle()
            }
        }

        private static let opening = Pad(x: 0, y: 0)
        private static let lowerPad = Pad(x: 0, y: 1)
        private static let upperPad = Pad(x: 1, y: 0)
        private static let nextPad = Pad(x: 1, y: 1)
        private static let gapMs: Int64 = 1000

        private static let keySound = "1 1 1 a.wav\n1 1 2 a.wav\n1 2 1 a.wav\n1 2 2 a.wav\n"
        private static let keyLed = Dictionary(uniqueKeysWithValues: [(1, 1), (1, 2), (2, 1), (2, 2)].map { x, y in
            ("1 \(x) \(y)", "on \(x) \(y) a 5\ndelay 60000\noff \(x) \(y)\n")
        })

        /// The same pack as the web and Android checks: a two-pad group after one opening pad.
        private static func autoPlay(finalGroup: Bool) -> String {
            "o 1 1\nd 1000\no 1 2\no 2 1\n" + (finalGroup ? "" : "d 1000\no 2 2\nd 1000\n")
        }

        @Test(arguments: [false, true], [Int64(1000), 10000])
        func autoplayAfterPlayingToThePartialGroupSoundsOnlyTheUnpressedPad(finalGroup: Bool, awayMs: Int64) async throws {
            for pressed in [Self.lowerPad, Self.upperPad] {
                try await check(pressed: pressed, finalGroup: finalGroup, awayMs: awayMs, playFirst: true)
            }
        }

        /// Choosing autoplay straight after the return, without pressing Play. The shared behaviour
        /// does not cover this path; the result is kept as it is on the web and on Android.
        @Test(arguments: [false, true], [Int64(1000), 10000])
        func autoplayRightAfterTheReturnSoundsOnlyTheUnpressedPad(finalGroup: Bool, awayMs: Int64) async throws {
            for pressed in [Self.lowerPad, Self.upperPad] {
                try await check(pressed: pressed, finalGroup: finalGroup, awayMs: awayMs, playFirst: false)
            }
        }

        private func check(pressed: Pad, finalGroup: Bool, awayMs: Int64, playFirst: Bool) async throws {
            let unpressed = pressed == Self.lowerPad ? Self.upperPad : Self.lowerPad
            try await PlayUsageScenario.run(keySound: Self.keySound, autoPlay: Self.autoPlay(finalGroup: finalGroup),
                                            keyLed: Self.keyLed) { s in
                let screen = Screen(s)
                try await s.loadReady()
                let engine = try #require(s.vm.soundEngine)
                let runner = try #require(s.vm.autoPlayRunner)

                s.vm.switchPlayMode(.stepPractice)
                try await screen.waitForGuides([Self.opening], "the opening pad was not guided")
                screen.tap(Self.opening)
                try await screen.waitForGuides([Self.lowerPad, Self.upperPad], "the group was not guided")
                screen.tap(pressed)
                try await screen.waitForGuides([unpressed], "the pressed pad stayed guided")
                try await screen.waitForLights([Self.opening, pressed], "the pressed pads did not light")
                #expect(screen.plays == 2)

                s.vm.onPause()
                #expect(screen.pads(lit: .guide).isEmpty)
                try await screen.waitForLights([], "leaving the app must clear the lights")
                try await screen.advance(awayMs)
                s.vm.onResume()
                try await s.waitWhile { engine.isPlaybackSuppressed }
                try await screen.settle()
                #expect(s.vm.playMode == .stepPractice)
                #expect(!s.vm.isAutoPlayPlaying)
                #expect(screen.pads(lit: .guide).isEmpty, "the guide waits for an explicit request")
                #expect(screen.pads(lit: .led).isEmpty)
                #expect(screen.plays == 2, "returning must not sound anything")

                if playFirst {
                    s.vm.autoPlayResume()
                    try await screen.waitForGuides([unpressed], "Play must guide only the unpressed pad")
                    #expect(s.vm.playMode == .stepPractice)
                    #expect(runner.stepMode)
                    try await screen.settle()
                    #expect(screen.plays == 2, "Play in step practice is silent")
                    #expect(screen.pads(lit: .led).isEmpty)
                }

                let chosenAt = screen.clock.read()
                s.vm.switchPlayMode(.autoPlay)
                let outputs = try #require(screen.outputs)
                try await s.waitWhile { outputs.inputs.isEmpty }
                let replayed = Note(pad: unpressed, at: chosenAt)
                #expect(outputs.inputs == [replayed], "only the unpressed pad is played, at once")
                #expect(outputs.sounds == [replayed], "and it is heard once")
                try await screen.waitForLights([unpressed], "the replayed pad's own light must show alone")
                #expect(screen.pads(lit: .guide).isEmpty, "no guide outlives step practice")

                if finalGroup {
                    try await s.waitWhile { outputs.ends == 0 }
                    #expect(outputs.ends == 1)
                } else {
                    #expect(s.vm.playMode == .autoPlay)
                    try await screen.advance(Self.gapMs - 1)
                    #expect(outputs.inputs == [replayed], "the next group keeps its written gap")
                    try await screen.advance(1)
                    let next = Note(pad: Self.nextPad, at: chosenAt + Self.gapMs)
                    #expect(outputs.inputs == [replayed, next])
                    #expect(outputs.sounds == [replayed, next])
                    try await screen.waitForLights([unpressed, Self.nextPad], "the next pad did not light")
                    #expect(outputs.ends == 0)
                    try await screen.advance(Self.gapMs - 1)
                    #expect(outputs.ends == 0, "the closing delay keeps its written length")
                    try await screen.advance(1)
                    try await s.waitWhile { outputs.ends == 0 }
                }
                #expect(outputs.ends == 1)
                #expect(!runner.active)
                #expect(s.vm.playMode == .none)
                #expect(!s.vm.isAutoPlayPlaying)
                #expect(screen.plays == (finalGroup ? 3 : 4), "nothing but the notes above may sound")
            }
        }
    }
}
#endif
