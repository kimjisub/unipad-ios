import Foundation
import Testing
@testable import unipad

/// Drives LedRunner tick by tick with a manual clock. The runner's own loop task is launched with an
/// hour-long interval, so after its first tick every further tick is one the test runs itself.
@MainActor
struct LedRunnerTests {
    final class StubPack: UniPack {
        override var id: String { "stub-pack" }

        /// A 2x2, two-chain pack with `leds[chain]` on pad (0, 0).
        init(leds: [Int: LedAnimation]) {
            super.init()
            buttonX = 2
            buttonY = 2
            chain = 2
            var table: [[[Deque<LedAnimation>?]]] = Array(
                repeating: Array(repeating: Array(repeating: nil, count: 2), count: 2),
                count: 2
            )
            for (c, animation) in leds {
                var queue = Deque<LedAnimation>()
                queue.append(animation)
                table[c][0][0] = queue
            }
            ledAnimationTable = table
        }

        override func lastModified() -> TimeInterval { 0 }
        override func loadInfo() -> UniPack { self }
        override func loadDetail() -> UniPack { self }
        override func checkFile() {}
        override func delete() {}
        override func getPathString() -> String { "" }
        override func getByteSize() -> Int64 { 0 }
    }

    final class Recorder: LedRunner.Listener {
        private let lock = NSLock()
        private var _outputs: [String] = []
        private var _codes: [Int] = []

        var codes: [Int] { lock.withLock { _codes } }

        var outputs: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _outputs
        }

        func onLedBatch(_ events: [LedRunner.LedEvent]) {
            lock.lock()
            defer { lock.unlock() }
            for event in events {
                switch event {
                case .padOn(_, _, _, let velocity), .chainOn(_, _, let velocity): _codes.append(velocity)
                case .padOff, .chainOff: _codes.append(0)
                }
                switch event {
                case .padOn(let x, let y, _, _): _outputs.append("padOn \(x) \(y)")
                case .padOff(let x, let y): _outputs.append("padOff \(x) \(y)")
                case .chainOn(let c, _, _): _outputs.append("chainOn \(c)")
                case .chainOff(let c): _outputs.append("chainOff \(c)")
                }
            }
        }
    }

    @MainActor
    struct Harness {
        let runner: LedRunner
        let recorder: Recorder
        let clock: TestManualClock
        let chain: ChainObserver

        func tick(_ ms: Int64 = 4) {
            clock.advance(ms)
            runner.loop()
        }

        /// Advance two normal ticks after a press.
        func press() {
            runner.eventOn(x: 0, y: 0)
            tick()
            tick()
        }
    }

    // Two passes of this strobe fit in one 4 ms tick, more than the per-tick budget allows.
    static let strobe = LedAnimation(
        ledEvents: [.off(x: 0, y: 0), .delay(delay: 1), .on(x: 0, y: 0, color: 5, velocity: 5), .delay(delay: 1)],
        loop: 0,
        num: 0
    )

    static let slowLoop = LedAnimation(
        ledEvents: [.on(x: 0, y: 0, color: 5, velocity: 5), .delay(delay: 10), .off(x: 0, y: 0), .delay(delay: 10)],
        loop: 0,
        num: 0
    )

    private func start(_ leds: [Int: LedAnimation]) async throws -> Harness {
        let clock = TestManualClock()
        let recorder = Recorder()
        let chain = ChainObserver()
        chain.range = 0...1
        let runner = LedRunner(
            unipack: StubPack(leds: leds),
            listener: recorder,
            chain: chain,
            loopDelay: 3600,
            clock: { clock.read() }
        )
        runner.launch()
        let deadline = Date().addingTimeInterval(5)
        while !clock.wasRead {
            try #require(Date() < deadline, "the loop task never ran its first tick")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return Harness(runner: runner, recorder: recorder, clock: clock, chain: chain)
    }

    @Test func autoplayInputMustArriveBeforeRenderingLaterSteps() async throws {
        let h = try await start([
            0: LedAnimation(ledEvents: [.on(x: 1, y: 1, velocity: 5), .delay(delay: 2),
                                       .on(x: 1, y: 1, velocity: 9)], loop: 1, num: 0),
            1: LedAnimation(ledEvents: [.on(x: 1, y: 1, velocity: 21)], loop: 1, num: 0)
        ])
        defer { h.runner.stop() }
        h.runner.setInputTimeThrough(1000)
        h.runner.eventOn(x: 0, y: 0)
        h.tick(0)
        // The LED task runs while autoplay's press for 1001 is still waiting on the main actor.
        h.tick(2)
        #expect(h.recorder.codes == [5])
        h.chain.setValue(1)
        h.runner.eventOn(x: 0, y: 0, pressedAt: 1001)
        h.runner.setInputTimeThrough(1003)
        h.tick(1)
        #expect(h.recorder.codes == [5, 21, 9])
    }

    @Test func clearingTheInputBoundaryLetsTheFiniteTailFinish() async throws {
        let h = try await start([0: LedAnimation(ledEvents: [
            .on(x: 0, y: 0, velocity: 5), .delay(delay: 2), .off(x: 0, y: 0)
        ], loop: 1, num: 0)])
        defer { h.runner.stop() }
        h.runner.setInputTimeThrough(1000)
        h.runner.eventOn(x: 0, y: 0)
        h.tick(3)
        #expect(h.recorder.codes == [5])
        h.runner.setInputTimeThrough(nil)
        h.tick(0)
        #expect(h.recorder.codes == [5, 0])
        // Starting another autoplay run can close the bound while a finished state remains.
        h.runner.setInputTimeThrough(.min)
        h.tick(1)
        #expect(h.recorder.codes == [5, 0])
    }

    @Test func lateFirstTickUsesThePressTime() async throws {
        let h = try await start([0: LedAnimation(ledEvents: [
            .on(x: 0, y: 0, velocity: 5), .delay(delay: 10), .off(x: 0, y: 0)
        ], loop: 1, num: 0)])
        defer { h.runner.stop() }
        h.runner.eventOn(x: 0, y: 0)
        h.tick(12)
        #expect(h.recorder.codes == [5, 0])
    }

    @Test func oneTickInterleavesAnimationsByDueTime() async throws {
        let h = try await start([
            0: LedAnimation(ledEvents: [.on(x: 1, y: 1, velocity: 5), .delay(delay: 5),
                                       .on(x: 1, y: 1, velocity: 9), .delay(delay: 100)], loop: 1, num: 0),
            1: LedAnimation(ledEvents: [.on(x: 1, y: 1, velocity: 21), .delay(delay: 100)], loop: 1, num: 0)
        ])
        defer { h.runner.stop() }
        h.runner.eventOn(x: 0, y: 0)
        h.tick(0)
        h.tick(0)
        h.clock.advance(2)
        h.chain.setValue(1)
        h.runner.eventOn(x: 0, y: 0)
        h.tick(6)
        h.tick(0)
        #expect(h.recorder.codes == [5, 21, 9])
    }

    @Test func pressingAgainPreservesOnlyWhatWasDueBeforeThePress() async throws {
        let h = try await start([0: LedAnimation(ledEvents: [
            .on(x: 0, y: 0, velocity: 5), .delay(delay: 10),
            .on(x: 1, y: 1, velocity: 9), .delay(delay: 10),
            .on(x: 0, y: 1, velocity: 13), .delay(delay: 100)
        ], loop: 1, num: 0)])
        defer { h.runner.stop() }
        h.runner.eventOn(x: 0, y: 0)
        h.tick(0)
        h.tick(0)
        h.clock.advance(15)
        h.runner.eventOn(x: 0, y: 0)
        h.tick(13)
        h.tick(0)
        #expect(h.recorder.codes == [5, 9, 0, 0, 5, 9])
    }

    @Test func runningEventAtThePressTimePrecedesShutdownAndNewAnimation() async throws {
        let h = try await start([0: LedAnimation(ledEvents: [
            .on(x: 0, y: 0, velocity: 5), .delay(delay: 10),
            .on(x: 0, y: 0, velocity: 9), .delay(delay: 10),
            .on(x: 1, y: 1, velocity: 13), .delay(delay: 100)
        ], loop: 1, num: 0)])
        defer { h.runner.stop() }
        h.runner.eventOn(x: 0, y: 0)
        h.tick(0)
        h.tick(0)
        h.clock.advance(10)
        h.runner.eventOn(x: 0, y: 0)
        h.tick(2)
        h.tick(0)
        #expect(h.recorder.codes == [5, 9, 0, 5])
    }

    @Test func twoPressesBetweenTicksEndTheQueuedAnimation() async throws {
        let h = try await start([0: LedAnimation(ledEvents: [
            .on(x: 0, y: 0, velocity: 5), .delay(delay: 2),
            .on(x: 1, y: 1, velocity: 9), .delay(delay: 100)
        ], loop: 1, num: 0)])
        defer { h.runner.stop() }
        h.runner.eventOn(x: 0, y: 0)
        h.clock.advance(1)
        h.runner.eventOn(x: 0, y: 0)
        h.tick(3)
        h.tick(0)
        #expect(h.recorder.codes == [5, 0, 5, 9])
    }

    @Test func ownershipIsAppliedInDueTimeOrderBeforeSuppressingOffs() async throws {
        let h = try await start([
            0: LedAnimation(ledEvents: [.on(x: 1, y: 1, velocity: 5), .delay(delay: 6),
                                       .off(x: 1, y: 1)], loop: 1, num: 0),
            1: LedAnimation(ledEvents: [.on(x: 1, y: 1, velocity: 9), .delay(delay: 100)], loop: 1, num: 0)
        ])
        defer { h.runner.stop() }
        h.runner.eventOn(x: 0, y: 0)
        h.tick(0)
        h.clock.advance(2)
        h.chain.setValue(1)
        h.runner.eventOn(x: 0, y: 0)
        h.tick(6)
        #expect(h.recorder.codes == [5, 9])
    }

    @Test func latePressEndsAnAnimationThatFinishedAfterItsTimestamp() async throws {
        let h = try await start([0: LedAnimation(ledEvents: [
            .on(x: 0, y: 0, velocity: 5), .delay(delay: 10), .on(x: 1, y: 1, velocity: 9)
        ], loop: 1, num: 0)])
        defer { h.runner.stop() }
        h.runner.eventOn(x: 0, y: 0)
        h.tick(12)
        #expect(!h.runner.isEventExist(x: 0, y: 0))
        h.clock.advance(2)
        h.runner.eventOn(x: 0, y: 0, pressedAt: 1008)
        h.tick(2)
        h.tick(4)
        #expect(h.recorder.codes == [5, 9, 0, 0, 5, 9])
    }

    @Test func pressAtTheLastEventLeavesTheFinishedLedsLit() async throws {
        let h = try await start([0: LedAnimation(ledEvents: [
            .on(x: 0, y: 0, velocity: 5), .delay(delay: 10), .on(x: 1, y: 1, velocity: 9)
        ], loop: 1, num: 0)])
        defer { h.runner.stop() }
        h.runner.eventOn(x: 0, y: 0)
        h.tick(12)
        h.clock.advance(2)
        h.runner.eventOn(x: 0, y: 0, pressedAt: 1010)
        h.tick(2)
        #expect(h.recorder.codes == [5, 9, 5])
    }

    @Test func releasingBeforeTheFirstTickEndsTheQueuedEndlessAnimation() async throws {
        let h = try await start([0: Self.slowLoop])
        defer { h.runner.stop() }
        h.runner.eventOn(x: 0, y: 0)
        h.clock.advance(1)
        h.runner.eventOff(x: 0, y: 0)
        h.tick(3)
        #expect(h.recorder.codes == [5, 0])
    }

    @Test func resumeShiftsTheRemainingWaitInsteadOfReplayingPausedTime() async throws {
        let h = try await start([0: LedAnimation(ledEvents: [
            .on(x: 0, y: 0, velocity: 5), .delay(delay: 20), .off(x: 0, y: 0)
        ], loop: 1, num: 0)])
        defer { h.runner.stop() }
        h.runner.eventOn(x: 0, y: 0)
        h.tick(4)
        h.runner.stop()
        h.clock.advance(1000)
        h.runner.launch()
        h.tick(15)
        #expect(h.recorder.codes == [5])
        h.tick(1)
        #expect(h.recorder.codes == [5, 0])
    }

    @Test(arguments: [false, true])
    func finiteZeroDurationLoopRunsOnlyOnePass(zeroDelay: Bool) async throws {
        try await checkZeroDurationLoop(repeats: 3, zeroDelay: zeroDelay)
    }

    @Test(arguments: [false, true])
    func hugeZeroDurationLoopFinishesInOneTick(zeroDelay: Bool) async throws {
        try await checkZeroDurationLoop(repeats: 2_147_483_647, zeroDelay: zeroDelay)
    }

    private func checkZeroDurationLoop(repeats: Int, zeroDelay: Bool) async throws {
        var events: [LedAnimation.LedEvent] = [
            .on(x: 0, y: 0, color: 5, velocity: 5), .off(x: 0, y: 0),
            .on(x: 1, y: 1, color: 9, velocity: 9),
            .on(x: -1, y: 0, color: 5, velocity: 5), .off(x: -1, y: 0),
            .on(x: -1, y: 1, color: 9, velocity: 9)
        ]
        if zeroDelay { events.insert(.delay(delay: 0), at: 1) }
        let h = try await start([0: LedAnimation(ledEvents: events, loop: repeats, num: 0)])
        defer { h.runner.stop() }

        h.press()
        #expect(h.recorder.outputs == [
            "padOn 0 0", "padOff 0 0", "padOn 1 1",
            "chainOn 0", "chainOff 0", "chainOn 1"
        ])
        h.tick()
        #expect(!h.runner.isEventExist(x: 0, y: 0))
        let finishedOutputs = h.recorder.outputs
        h.runner.eventOff(x: 0, y: 0)
        for _ in 0..<5 { h.tick() }
        #expect(h.recorder.outputs == finishedOutputs, "completed finite LEDs keep their final state")
    }

    @Test func finiteNegativeDurationLoopRunsOnlyOnePass() async throws {
        try await checkNegativeDurationLoop(repeats: 3)
    }

    @Test func hugeNegativeDurationLoopFinishesInOneTick() async throws {
        try await checkNegativeDurationLoop(repeats: 2_147_483_647)
    }

    private func checkNegativeDurationLoop(repeats: Int) async throws {
        let h = try await start([0: LedAnimation(
            ledEvents: [.on(x: 0, y: 0, color: 5, velocity: 5), .delay(delay: 10),
                        .off(x: 0, y: 0), .delay(delay: -20),
                        .on(x: 1, y: 1, color: 9, velocity: 9),
                        .on(x: -1, y: 1, color: 9, velocity: 9)],
            loop: repeats, num: 0
        )])
        defer { h.runner.stop() }

        h.press()
        #expect(h.recorder.outputs == ["padOn 0 0"], "the positive delay still waits")
        h.tick(10)
        #expect(h.recorder.outputs == ["padOn 0 0", "padOff 0 0", "padOn 1 1", "chainOn 1"])
        h.tick()
        #expect(!h.runner.isEventExist(x: 0, y: 0))
        let finishedOutputs = h.recorder.outputs
        h.runner.eventOff(x: 0, y: 0)
        for _ in 0..<5 { h.tick() }
        #expect(h.recorder.outputs == finishedOutputs, "completed finite LEDs keep their final state")
    }

    @Test func timedFiniteLoopPlaysAllThreePasses() async throws {
        let h = try await start([0: LedAnimation(
            ledEvents: [.on(x: 0, y: 0, color: 5, velocity: 5), .delay(delay: 10),
                        .off(x: 0, y: 0), .delay(delay: 10)],
            loop: 3, num: 0
        )])
        defer { h.runner.stop() }

        h.press()
        #expect(h.recorder.outputs == ["padOn 0 0"])
        for pass in 0..<3 {
            h.tick(10)
            #expect(h.recorder.outputs == Array(repeating: ["padOn 0 0", "padOff 0 0"], count: pass + 1).flatMap { $0 })
            h.tick(10)
            if pass < 2 {
                #expect(h.recorder.outputs.last == "padOn 0 0")
            }
        }
        h.tick()
        #expect(!h.runner.isEventExist(x: 0, y: 0))
        #expect(h.recorder.outputs == Array(repeating: ["padOn 0 0", "padOff 0 0"], count: 3).flatMap { $0 })
    }

    @Test func resumedPartialPassDoesNotSkipTimedRepeats() async throws {
        let h = try await start([0: LedAnimation(
            ledEvents: [.on(x: 0, y: 0, color: 5, velocity: 5), .delay(delay: 10), .off(x: 0, y: 0)],
            loop: 3, num: 0
        )])
        defer { h.runner.stop() }

        h.press()
        h.runner.stop()
        h.runner.launch()
        h.tick(0)
        h.tick(10)
        h.tick(10)
        h.tick()
        #expect(h.recorder.outputs == Array(repeating: ["padOn 0 0", "padOff 0 0"], count: 3).flatMap { $0 })
        #expect(!h.runner.isEventExist(x: 0, y: 0))
    }

    @Test func slowLoopGoesDarkOnRelease() async throws {
        let h = try await start([0: Self.slowLoop])
        defer { h.runner.stop() }

        h.press()
        h.runner.eventOff(x: 0, y: 0)
        h.tick()
        #expect(h.recorder.outputs == ["padOn 0 0", "padOff 0 0"])

        for _ in 0..<20 { h.tick() }
        #expect(h.recorder.outputs.count == 2)
    }

    @Test func strobeKeepsPlayingInOrderAndGoesDarkOnRelease() async throws {
        let h = try await start([0: Self.strobe])
        defer { h.runner.stop() }

        h.press()
        for _ in 0..<50 { h.tick() }
        h.runner.eventOff(x: 0, y: 0)
        h.tick()

        let outputs = h.recorder.outputs
        #expect(outputs.count > 20, "strobe played \(outputs.count) changes in 200 ms")
        for (i, output) in outputs.enumerated() {
            #expect(output == (i % 2 == 0 ? "padOn 0 0" : "padOff 0 0"), "change \(i)")
        }
        #expect(outputs.last == "padOff 0 0")
    }

    /// The LED toggle calls stop() and then eventOffAll on every pad (PlayViewModel.ledInit).
    @Test func strobeGoesDarkOnEventOffAll() async throws {
        let h = try await start([0: Self.strobe])
        defer { h.runner.stop() }

        h.press()
        for _ in 0..<50 { h.tick() }
        #expect(h.runner.isEventExist(x: 0, y: 0))
        h.runner.eventOffAll(x: 0, y: 0)
        h.tick()

        #expect(h.recorder.outputs.last == "padOff 0 0")
    }

    @Test func strobeKeepsPlayingAcrossAChainSwitch() async throws {
        let h = try await start([0: Self.strobe])
        defer { h.runner.stop() }

        h.press()
        h.chain.setValue(1)
        for _ in 0..<50 { h.tick() }
        let played = h.recorder.outputs.count
        for _ in 0..<10 { h.tick() }
        h.chain.setValue(0)
        h.runner.eventOff(x: 0, y: 0)
        h.tick()

        #expect(h.recorder.outputs.count > played, "strobe froze after the chain switch")
        #expect(h.recorder.outputs.last == "padOff 0 0")
    }

    /// The loop task does not run while the app is suspended, so the tick after a return sees a
    /// long backlog.
    @Test func loopSurvivesALateTickWithoutReplayingTheBacklog() async throws {
        let h = try await start([0: Self.slowLoop])
        defer { h.runner.stop() }

        h.press()
        let beforeStall = h.recorder.outputs.count
        h.tick(1000)
        #expect(h.recorder.outputs.count - beforeStall <= 5)

        let afterStall = h.recorder.outputs.count
        for _ in 0..<20 { h.tick() }
        #expect(h.recorder.outputs.count > afterStall, "the loop stopped after the late tick")

        h.runner.eventOff(x: 0, y: 0)
        h.tick()
        #expect(h.recorder.outputs.last == "padOff 0 0")
    }

    @Test func emptyEndlessAnimationOutputsNothingAndIsDropped() async throws {
        let h = try await start([0: LedAnimation(ledEvents: [], loop: 0, num: 0)])
        defer { h.runner.stop() }

        h.press()
        h.tick()

        #expect(h.recorder.outputs.isEmpty)
        #expect(!h.runner.isEventExist(x: 0, y: 0))
    }

    /// Without the per-tick budget this tick never returns and the whole test run hangs, so the run
    /// needs an external time limit to report it.
    @Test func endlessAnimationWithoutDelaysReturnsFromATick() async throws {
        let h = try await start([0: LedAnimation(
            ledEvents: [.on(x: 0, y: 0, color: 5, velocity: 5), .off(x: 0, y: 0)],
            loop: 0,
            num: 0
        )])
        defer { h.runner.stop() }

        h.press()
        for _ in 0..<5 { h.tick() }

        #expect(!h.recorder.outputs.isEmpty)
        #expect(h.runner.isEventExist(x: 0, y: 0))
    }
}
