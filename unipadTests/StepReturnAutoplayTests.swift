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
        struct Pad: Hashable, Sendable, CustomStringConvertible {
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
            private(set) var guideRemovals = 0
            var now: () -> Int64 = { 0 }
            private(set) var guides: [(pad: Pad, target: Int64, emitted: Int64)] = []
            private(set) var guideLeds: [(pad: Pad, velocity: Int, emitted: Int64)] = []

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
                guides.append((Pad(x: x, y: y), targetWallTimeMs, now()))
                screen.onGuidePadOn(x: x, y: y, targetWallTimeMs: targetWallTimeMs)
            }
            func onGuidePadOff(x: Int, y: Int) { screen.onGuidePadOff(x: x, y: y) }
            func onGuideLedUpdate(x: Int, y: Int, velocity: Int) {
                guideLeds.append((Pad(x: x, y: y), velocity, now()))
                screen.onGuideLedUpdate(x: x, y: y, velocity: velocity)
            }
            func onGuideChainOn(c: Int) { screen.onGuideChainOn(c: c) }
            func onRemoveGuide() { guideRemovals += 1; screen.onRemoveGuide() }
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
                try #require(passes.count >= target || s.vm.autoPlayRunner?.active != true, "the runner stopped passing")
            }

            func advance(_ ms: Int64) async throws {
                clock.advance(ms)
                try await settle()
            }
        }

        /// Each sleep holds a real runner pass until the test releases it, even across mode changes.
        @MainActor
        final class GatedScreen {
            let s: PlayUsageScenario
            let clock = TestManualClock()
            private(set) var outputs: Outputs?
            private(set) var ticks = 0
            private var continuation: CheckedContinuation<Void, Never>?

            init(_ s: PlayUsageScenario) {
                self.s = s
                s.vm.makeAutoPlayRunner = { [weak self, weak vm = s.vm, clock] pack, listener, chain in
                    let recorder = Outputs(screen: listener) { vm?.soundEngine?.playsStarted ?? 0 }
                    recorder.now = { clock.read() }
                    self?.outputs = recorder
                    return AutoPlayRunner(unipack: pack, listener: recorder, chain: chain,
                        clock: { clock.read() }, sleep: { [weak self] _ in
                            await withCheckedContinuation { pending in
                                guard let self else { pending.resume(); return }
                                self.continuation = pending
                                self.ticks += 1
                            }
                        })
                }
            }

            func tick(at time: Int64? = nil) async throws {
                if let time { clock.advance(time - clock.read()) }
                let runner = try #require(s.vm.autoPlayRunner)
                let target = ticks + 1
                let pending = continuation; continuation = nil; pending?.resume()
                try await s.waitWhile {
                    if ticks >= target { return false }
                    return runner.active
                }
                let reached = ticks >= target
                let stopped = !runner.active
                try #require(reached || stopped)
            }

            func resume() async throws {
                let runner = try #require(s.vm.autoPlayRunner)
                s.vm.autoPlayResume()
                try await s.waitWhile { !runner.playmode }
            }

            func stop() {
                s.vm.autoPlayRunner?.stop()
                continuation?.resume()
                continuation = nil
            }

            func isGuided(_ pad: Pad) -> Bool {
                s.vm.channelManager?.get(x: pad.x, y: pad.y, channel: .guide) != nil
            }
        }

        private nonisolated static let opening = Pad(x: 0, y: 0)
        private nonisolated static let lowerPad = Pad(x: 0, y: 1)
        private nonisolated static let upperPad = Pad(x: 1, y: 0)
        private nonisolated static let nextPad = Pad(x: 1, y: 1)
        private static let gapMs: Int64 = 1000

        private static let keySound = "1 1 1 a.wav\n1 1 2 a.wav\n1 2 1 a.wav\n1 2 2 a.wav\n"
        private static let keyLed = Dictionary(uniqueKeysWithValues: [(1, 1), (1, 2), (2, 1), (2, 2)].map { x, y in
            ("1 \(x) \(y)", "on \(x) \(y) a 5\ndelay 60000\noff \(x) \(y)\n")
        })

        /// The same pack as the web and Android checks: a two-pad group after one opening pad.
        private static func autoPlay(finalGroup: Bool) -> String {
            "o 1 1\nd 1000\no 1 2\no 2 1\n" + (finalGroup ? "" : "d 1000\no 2 2\nd 1000\n")
        }

        /// Either pad of the group may be the pressed one, before a final or a following group.
        nonisolated static let cases: [(pressed: Pad, finalGroup: Bool, awayMs: Int64)] = [lowerPad, upperPad].flatMap { pressed in
            [false, true].flatMap { finalGroup in [Int64(1000), 10000].map { (pressed, finalGroup, $0) } }
        }

        @Test(arguments: Self.cases)
        func autoplayAfterPlayingToThePartialGroupSoundsOnlyTheUnpressedPad(pressed: Pad, finalGroup: Bool, awayMs: Int64) async throws {
            try await check(pressed: pressed, finalGroup: finalGroup, awayMs: awayMs, playFirst: true)
        }

        /// Choosing autoplay straight after the return, without pressing Play. The shared behaviour
        /// does not cover this path; the result is kept as it is on the web and on Android.
        @Test(arguments: Self.cases)
        func autoplayRightAfterTheReturnSoundsOnlyTheUnpressedPad(pressed: Pad, finalGroup: Bool, awayMs: Int64) async throws {
            try await check(pressed: pressed, finalGroup: finalGroup, awayMs: awayMs, playFirst: false)
        }

        /// Exact file bytes shared by the three players. Each sleeper gates a real runner pass,
        /// including the late pause before the first due note can be processed.
        @Test(arguments: [Int64(500), 1500], [false, true])
        func timedGuideResumePreservesUnpressedNotes(songMs: Int64, pressed: Bool) async throws {
            try await checkTimedResume(songMs: songMs, pressed: pressed, processedFirst: false)
        }

        @Test(arguments: [false, true])
        func timedGuideResumeAfterTheFirstNotePreservesTheSecond(pressed: Bool) async throws {
            try await checkTimedResume(songMs: 1500, pressed: pressed, processedFirst: true)
        }

        private func checkTimedResume(songMs: Int64, pressed: Bool, processedFirst: Bool) async throws {
            let text = "d 1000\no 1 1\nf 1 1\nd 1000\no 1 2\nf 1 2\nd 1000\no 2 1\nf 2 1\nd 1000\n"
            try await PlayUsageScenario.run(keySound: Self.keySound, autoPlay: text, grid: PlayUsageScenario.PackGrid(buttonX: 2, buttonY: 2, chain: 1)) { s in
                let screen = GatedScreen(s)
                let clock = screen.clock
                try await s.loadReady()
                let runner = try #require(s.vm.autoPlayRunner)
                defer { screen.stop() }
                s.vm.switchPlayMode(.guidePlay)
                try await s.waitWhile { screen.ticks == 0 }
                let recorder = try #require(screen.outputs)
                #expect(runner.progress == 1, "the opening delay was read")
                if processedFirst {
                    clock.advance(1000)
                    try await screen.tick()
                    #expect(runner.progress == 4)
                    clock.advance(500)
                } else { clock.advance(songMs) }
                s.vm.autoPlayPause()
                try await screen.tick()
                let pending = processedFirst ? Self.lowerPad : Self.opening
                #expect(recorder.guides.last?.pad == pending)
                if pressed {
                    s.vm.padTouch(x: pending.x, y: pending.y, isDown: true, trigger: .pad(.screen), ledTimeMs: clock.read())
                    s.vm.padTouch(x: pending.x, y: pending.y, isDown: false, trigger: .pad(.screen), ledTimeMs: clock.read())
                    try await screen.tick()
                }
                clock.advance(2000)
                let resumedAt = clock.read()
                let before = recorder.guides.count
                let plays = s.vm.soundEngine?.playsStarted
                try await screen.resume()
                try await screen.tick()
                let overdue = !pressed && !processedFirst && songMs == 1500
                if overdue {
                    #expect(screen.isGuided(Self.opening), "the overdue guide must reach the screen")
                    #expect(recorder.guideLeds.contains { $0.pad == Self.opening && $0.emitted == resumedAt && $0.velocity > 0 },
                            "the overdue guide must send positive brightness in the resume pass")
                }
                // Literal song-relative expectations: an unpressed group retains its old deadline;
                // a played group starts its following written gap at resume.
                let targets: [Int64]
                let pads: [Pad]
                if processedFirst {
                    targets = pressed ? [5500] : [5000, 6000]
                    pads = pressed ? [Self.upperPad] : [Self.lowerPad, Self.upperPad]
                } else {
                    targets = pressed ? [resumedAt + 1000, resumedAt + 2000] : [4000, 5000, 6000]
                    pads = pressed ? [Self.lowerPad, Self.upperPad] : [Self.opening, Self.lowerPad, Self.upperPad]
                }
                let checkpoints = Set([resumedAt, resumedAt + 49, resumedAt + 50, targets.last! + 1000] + targets.flatMap { [$0 - 801, $0 - 800, $0 - 1, $0] })
                for at in checkpoints.filter({ $0 >= resumedAt }).sorted() {
                    if at > clock.read() { clock.advance(at - clock.read()); try await screen.tick() }
                    if overdue && at < resumedAt + 50 {
                        #expect(screen.isGuided(Self.opening), "the overdue guide stays visible for 50 ms")
                    } else if overdue {
                        #expect(!screen.isGuided(Self.opening))
                    }
                    let events = Array(recorder.guides.dropFirst(before))
                    let expectedCount = targets.filter { $0 <= at + 800 }.count
                    #expect(events.map(\.pad) == Array(pads.prefix(expectedCount)), "guide order at \(at)")
                    #expect(events.map(\.target) == Array(targets.prefix(expectedCount)), "guide deadlines at \(at)")
                    if !pressed && !processedFirst && songMs == 1500 {
                        #expect(events.first?.emitted == resumedAt, "the overdue guide is emitted in the resume pass")
                    }
                }
                let trace = recorder.guides.dropFirst(before).map {
                    "\($0.pad):target=\($0.target),emitted=\($0.emitted)"
                }.joined(separator: ";")
                print("timed-guide songMs=\(songMs) pressed=\(pressed) processedFirst=\(processedFirst) resume=\(resumedAt) \(trace)")
                #expect(recorder.inputs.isEmpty, "timed guidance never requests an autoplay press")
                #expect(s.vm.soundEngine?.playsStarted == plays, "guidance stays silent")
                #expect(recorder.ends == 1)
                for x in 0..<2 {
                    for y in 0..<2 {
                        #expect(s.vm.channelManager?.get(x: x, y: y, channel: .guide) == nil)
                    }
                }
            }
        }

        @Test
        func overdueGuideSendsBrightnessImmediatelyBetweenThrottleTicks() async throws {
            let text = "d 1000\no 1 1\nf 1 1\nd 1000\no 1 2\nf 1 2\nd 1000\n"
            try await PlayUsageScenario.run(keySound: Self.keySound, autoPlay: text) { s in
                let screen = GatedScreen(s)
                try await s.loadReady()
                defer { screen.stop() }
                s.vm.switchPlayMode(.guidePlay)
                try await s.waitWhile { screen.ticks == 0 }
                try await screen.tick(at: 1999)
                screen.clock.advance(2)
                s.vm.autoPlayPause()
                try await screen.tick()
                let recorder = try #require(screen.outputs)
                let before = recorder.guideLeds.count
                try await screen.resume()
                try await screen.tick()
                let updates = Array(recorder.guideLeds.dropFirst(before))
                #expect(updates.contains { $0.pad == Self.opening && $0.emitted == 2001 && $0.velocity > 0 })
                #expect(screen.isGuided(Self.opening))
                try await screen.tick(at: 2050)
                #expect(screen.isGuided(Self.opening))
                try await screen.tick(at: 2051)
                #expect(!screen.isGuided(Self.opening))
                #expect(recorder.guideLeds.last { $0.pad == Self.opening }?.velocity == 0)
            }
        }

        @Test(arguments: ["", "d 0\n", "d 20\n"])
        func overdueFinalGuideFinishesItsVisiblePulseBeforeSongEnd(tail: String) async throws {
            let text = "d 1000\no 1 1\nf 1 1\n" + tail
            try await PlayUsageScenario.run(keySound: Self.keySound, autoPlay: text) { s in
                let screen = GatedScreen(s)
                try await s.loadReady()
                defer { screen.stop() }
                let runner = try #require(s.vm.autoPlayRunner)
                s.vm.switchPlayMode(.guidePlay)
                try await s.waitWhile { screen.ticks == 0 }
                screen.clock.advance(1500)
                s.vm.autoPlayPause()
                try await screen.tick()
                screen.clock.advance(2000)
                let recorder = try #require(screen.outputs)
                let before = recorder.guideLeds.count
                try await screen.resume()
                try await screen.tick()
                #expect(screen.isGuided(Self.opening))
                #expect(recorder.ends == 0)
                #expect(runner.active)
                #expect(recorder.guideLeds.dropFirst(before).contains {
                    $0.pad == Self.opening && $0.emitted == 4500 && $0.velocity > 0
                })
                try await screen.tick(at: 4549)
                #expect(recorder.ends == 0)
                #expect(screen.isGuided(Self.opening))
                try await screen.tick(at: 4550)
                #expect(recorder.ends == 1)
                #expect(!runner.active)
                #expect(!screen.isGuided(Self.opening))
                #expect(recorder.guideLeds.last { $0.pad == Self.opening }?.velocity == 0)
                #expect(recorder.inputs.isEmpty)
                #expect(s.vm.soundEngine?.playsStarted == 0)
            }
        }

        @Test
        func repeatedPauseBeforeTheResumeTickKeepsTheUnplayedChordMember() async throws {
            let text = "d 1000\no 1 1\no 1 2\nf 1 1\nf 1 2\nd 1000\no 2 1\nf 2 1\nd 1000\n"
            try await PlayUsageScenario.run(keySound: Self.keySound, autoPlay: text) { s in
                let screen = GatedScreen(s)
                try await s.loadReady()
                defer { screen.stop() }
                s.vm.switchPlayMode(.guidePlay)
                try await s.waitWhile { screen.ticks == 0 }
                screen.clock.advance(500)
                s.vm.autoPlayPause()
                try await screen.tick()
                s.vm.padTouch(x: 0, y: 1, isDown: true, trigger: .pad(.screen), ledTimeMs: screen.clock.read())
                s.vm.padTouch(x: 0, y: 1, isDown: false, trigger: .pad(.screen), ledTimeMs: screen.clock.read())
                try await screen.tick()
                let recorder = try #require(screen.outputs)
                let afterPress = recorder.guides.count
                let plays = s.vm.soundEngine?.playsStarted
                screen.clock.advance(2000)
                for _ in 0..<2 {
                    try await screen.resume()
                    // Do not release the sleeper: pause before the very first resumed iteration.
                    s.vm.autoPlayPause()
                    try await screen.tick()
                    #expect(screen.isGuided(Self.opening))
                    #expect(!screen.isGuided(Self.lowerPad))
                    screen.clock.advance(2000)
                }
                let beforeResume = recorder.guides.count
                let resumedAt = screen.clock.read()
                try await screen.resume()
                try await screen.tick()
                #expect(recorder.guides.dropFirst(beforeResume).map(\.pad) == [Self.opening])
                #expect(recorder.guides.last?.target == resumedAt)
                #expect(screen.isGuided(Self.opening), "a remaining chord member due at resume must actually be visible")
                #expect(recorder.guideLeds.contains {
                    $0.pad == Self.opening && $0.emitted == resumedAt && $0.velocity > 0
                })
                try await screen.tick(at: resumedAt + 49)
                #expect(screen.isGuided(Self.opening))
                try await screen.tick(at: resumedAt + 50)
                #expect(!screen.isGuided(Self.opening))
                try await screen.tick(at: resumedAt + 1000)
                #expect(recorder.guides.last?.pad == Self.upperPad)
                #expect(recorder.guides.last?.target == resumedAt + 1000)
                try await screen.tick(at: resumedAt + 2000)
                #expect(recorder.ends == 1)
                #expect(!recorder.guides.dropFirst(afterPress).contains { $0.pad == Self.lowerPad })
                #expect(recorder.inputs.isEmpty)
                #expect(s.vm.soundEngine?.playsStarted == plays)
            }
        }

        @Test(arguments: [false, true])
        func seekingWhilePausedThenPlayingAStepKeepsTheFollowingGap(seekBack: Bool) async throws {
            // The next button moves from index 3 to 43; Prev then scans zero delays back to
            // that same note. Neither pending seek may replace the interval after a press.
            let text = "d 1000\no 1 1\nf 1 1\nd 1000\n"
                + String(repeating: "d 0\n", count: 39)
                + "o 1 2\nf 1 2\nd 1000\no 2 1\nf 2 1\nd 1000\n"
            try await PlayUsageScenario.run(keySound: Self.keySound, autoPlay: text) { s in
                let screen = GatedScreen(s)
                try await s.loadReady()
                defer { screen.stop() }
                s.vm.switchPlayMode(.guidePlay)
                try await s.waitWhile { screen.ticks == 0 }
                screen.clock.advance(500)
                s.vm.autoPlayPause()
                try await screen.tick()
                s.vm.autoPlayNext()
                try await screen.tick()
                if seekBack { s.vm.autoPlayPrev(); try await screen.tick() }
                #expect(screen.isGuided(Self.lowerPad))
                s.vm.padTouch(x: 0, y: 1, isDown: true, trigger: .pad(.screen), ledTimeMs: screen.clock.read())
                s.vm.padTouch(x: 0, y: 1, isDown: false, trigger: .pad(.screen), ledTimeMs: screen.clock.read())
                try await screen.tick()
                #expect(screen.isGuided(Self.upperPad))
                screen.clock.advance(2000)
                let resumedAt = screen.clock.read()
                let recorder = try #require(screen.outputs)
                let before = recorder.guides.count
                let plays = s.vm.soundEngine?.playsStarted
                try await screen.resume()
                try await screen.tick()
                #expect(recorder.guides.count == before, "the following note is still beyond the 800 ms lookahead")
                try await screen.tick(at: resumedAt + 200)
                #expect(recorder.guides.last?.pad == Self.upperPad)
                #expect(recorder.guides.last?.target == resumedAt + 1000)
                try await screen.tick(at: resumedAt + 999)
                #expect(screen.isGuided(Self.upperPad))
                try await screen.tick(at: resumedAt + 1000)
                #expect(!screen.isGuided(Self.upperPad))
                try await screen.tick(at: resumedAt + 2000)
                #expect(recorder.ends == 1)
                #expect(recorder.inputs.isEmpty)
                #expect(s.vm.soundEngine?.playsStarted == plays)
            }
        }

        @Test(arguments: ["beforeResumeTick", "pauseBeforeResumeTick", "waitingForChain"])
        func switchingResumedGuideToAutoplayNeverSoundsThePlayedChordMember(transition: String) async throws {
            let chainWait = transition == "waitingForChain"
            let gap = chainWait ? 100 : 1000
            let text = "d 1000\no 1 1\no 1 2\nf 1 1\nf 1 2\nd \(gap)\n"
                + (chainWait ? "c 2\n" : "") + "o 2 1\nf 2 1\nd 1000\n"
            try await PlayUsageScenario.run(keySound: Self.keySound + "2 2 1 a.wav\n", autoPlay: text,
                grid: PlayUsageScenario.PackGrid(buttonX: 2, buttonY: 2, chain: 2)) { s in
                let screen = GatedScreen(s)
                try await s.loadReady()
                defer { screen.stop() }
                s.vm.switchPlayMode(.guidePlay)
                try await s.waitWhile { screen.ticks == 0 }
                screen.clock.advance(500)
                s.vm.autoPlayPause()
                try await screen.tick()
                s.vm.padTouch(x: 0, y: 1, isDown: true, trigger: .pad(.screen), ledTimeMs: screen.clock.read())
                s.vm.padTouch(x: 0, y: 1, isDown: false, trigger: .pad(.screen), ledTimeMs: screen.clock.read())
                try await screen.tick()
                screen.clock.advance(2000)
                let recorder = try #require(screen.outputs)
                try await screen.resume()
                if chainWait {
                    try await screen.tick()
                    try await screen.tick(at: screen.clock.read() + 2000)
                } else if transition == "pauseBeforeResumeTick" {
                    s.vm.autoPlayPause()
                    // No runner pass has scanned a new paused step yet.
                }
                let before = recorder.inputs.count
                let plays = s.vm.soundEngine?.playsStarted ?? 0
                s.vm.switchPlayMode(.autoPlay)
                try await screen.tick()
                #expect(recorder.inputs.dropFirst(before).map(\.pad) == [Self.opening])
                try await screen.tick(at: screen.clock.read() + Int64(gap))
                #expect(recorder.inputs.dropFirst(before).map(\.pad) == [Self.opening, Self.upperPad])
                #expect(!recorder.inputs.dropFirst(before).contains { $0.pad == Self.lowerPad },
                        "the manually played chord member must never sound again")
                #expect((s.vm.soundEngine?.playsStarted ?? 0) == plays + 2)
                try await screen.tick(at: screen.clock.read() + 1000)
                #expect(recorder.ends == 1)
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

                if !finalGroup {
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
                }
                try await s.waitWhile { outputs.ends == 0 }
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
