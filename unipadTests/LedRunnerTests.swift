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
                case .padOn(let x, let y, _, _): _outputs.append("padOn \(x) \(y)")
                case .padOff(let x, let y): _outputs.append("padOff \(x) \(y)")
                case .chainOn(let c, _, _): _outputs.append("chainOn \(c)")
                case .chainOff(let c): _outputs.append("chainOff \(c)")
                }
            }
        }
    }

    final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var now: Int64 = 1000
        private var reads = 0

        func read() -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            return now
        }

        var wasRead: Bool {
            lock.lock()
            defer { lock.unlock() }
            return reads > 0
        }

        func advance(_ ms: Int64) {
            lock.lock()
            now += ms
            lock.unlock()
        }
    }

    @MainActor
    struct Harness {
        let runner: LedRunner
        let recorder: Recorder
        let clock: ManualClock
        let chain: ChainObserver

        func tick(_ ms: Int64 = 4) {
            clock.advance(ms)
            runner.loop()
        }

        /// eventOn queues the animation; the next tick adopts it and the one after plays it.
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
        let clock = ManualClock()
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
