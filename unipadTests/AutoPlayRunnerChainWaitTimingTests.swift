import XCTest
@testable import unipad

/// The sleeper gates each real runner iteration; host scheduling never advances song time.
@MainActor
final class AutoPlayRunnerChainWaitTimingTests: XCTestCase {
    private final class Playback: AutoPlayRunner.Listener {
        var now: Int64 = 1000
        var iteration = 0
        var continuation: CheckedContinuation<Void, Never>?
        var runner: AutoPlayRunner!
        let chain = ChainObserver()
        var presses: [Int64] = []
        var scheduled: [Int64] = []
        var guides: [Int64] = []
        var hints: [Int] = []

        init() {
            let pack = UniPack()
            var elements: [AutoPlay.Element] = [.delay(delay: 1000), .chain(c: 1)]
            for index in 0..<3 {
                elements += [.on(x: 0, y: 0, currChain: 1, num: index),
                             .off(x: 0, y: 0, currChain: 1), .delay(delay: index == 2 ? 10000 : 500)]
            }
            // Keep the runner alive through the trailing delay while each deadline is sampled.
            elements.append(.off(x: 0, y: 0, currChain: 1))
            pack.autoPlayTable = AutoPlay(elements: elements)
            runner = AutoPlayRunner(unipack: pack, listener: self, chain: chain,
                clock: { [unowned self] in now }, sleep: { [unowned self] _ in
                    await withCheckedContinuation { continuation = $0; iteration += 1 }
                })
        }

        func waitForIteration(_ target: Int) async throws {
            let deadline = Date().addingTimeInterval(10)
            while iteration < target {
                guard Date() < deadline else { XCTFail("Runner did not reach its next tick"); throw CancellationError() }
                await Task.yield()
            }
        }

        func startWaiting() async throws {
            runner.practiceGuide = true
            runner.launch()
            try await waitForIteration(1)
            try await tick(1200)
            XCTAssertEqual(hints, [1])
            try await tick(6200)
            XCTAssertTrue(presses.isEmpty)
        }

        func tick(_ time: Int64? = nil) async throws {
            if let time { now = time }
            let target = iteration + 1
            let pending = continuation
            continuation = nil
            pending?.resume()
            try await waitForIteration(target)
        }

        func auto(reset: Bool = false) {
            runner.practiceGuide = false
            runner.stepMode = false
            if reset { runner.resetStepState() }
            runner.playmode = true
        }

        func stop() {
            runner.stop()
            continuation?.resume()
            continuation = nil
        }

        func onStart() {}
        func onEnd() {}
        func onPadTouchOn(x: Int, y: Int, inputID: UUID) {}
        func onPadTouchOff(x: Int, y: Int, inputIDs: [UUID]) {}
        func onPadTouchOn(x: Int, y: Int, inputID: UUID, scheduledAtMs: Int64) {
            presses.append(now); scheduled.append(scheduledAtMs)
        }
        func onChainChange(c: Int) { chain.setValue(c) }
        func onGuidePadOn(x: Int, y: Int, targetWallTimeMs: Int64) { guides.append(targetWallTimeMs) }
        func onGuidePadOff(x: Int, y: Int) {}
        func onGuideLedUpdate(x: Int, y: Int, velocity: Int) {}
        func onGuideChainOn(c: Int) { hints.append(c) }
        func onRemoveGuide() {}
        func chainButsRefresh() {}
        func onProgressUpdate(progress: Int) {}
    }

    private func assertThreePresses(_ playback: Playback) async throws {
        XCTAssertEqual(playback.presses, [], "Changing mode must preserve the remaining 800 ms")
        let deadlines: [Int64] = [7000, 7500, 8000]
        for at in deadlines {
            try await playback.tick(at - 1)
            XCTAssertEqual(playback.presses, deadlines.filter { $0 < at })
            try await playback.tick(at)
            XCTAssertEqual(playback.presses, deadlines.filter { $0 <= at })
            XCTAssertEqual(playback.scheduled, playback.presses)
        }
    }

    func testSwitchingFromGuideToAutoPreservesRemainingDelay() async throws {
        let playback = Playback(); defer { playback.stop() }
        try await playback.startWaiting()
        playback.auto()
        try await playback.tick()
        try await assertThreePresses(playback)
    }

    func testSwitchingWithScreenStepResetPreservesRemainingDelay() async throws {
        let playback = Playback(); defer { playback.stop() }
        try await playback.startWaiting()
        playback.auto(reset: true)
        try await playback.tick()
        try await assertThreePresses(playback)
    }

    func testPausingThenSwitchingToAutoPreservesRemainingDelay() async throws {
        let playback = Playback(); defer { playback.stop() }
        try await playback.startWaiting()
        playback.runner.playmode = false
        try await playback.tick(9200)
        playback.auto(reset: true)
        try await playback.tick()
        XCTAssertEqual(playback.presses, [])
        try await playback.tick(9999)
        XCTAssertEqual(playback.presses, [])
        try await playback.tick(10000)
        XCTAssertEqual(playback.presses, [10000])
        XCTAssertEqual(playback.scheduled, [10000])
    }

    func testChoosingRequestedChainKeepsOriginalSongDelay() async throws {
        let playback = Playback(); defer { playback.stop() }
        try await playback.startWaiting()
        playback.chain.setValue(1)
        try await playback.tick()
        try await playback.tick(6201)
        XCTAssertEqual(playback.guides, [7000])
        try await playback.tick(7000)
        XCTAssertEqual(playback.runner.progress, 5)
    }

    func testResettingWaitPreservesGuideDeadline() async throws {
        let playback = Playback(); defer { playback.stop() }
        try await playback.startWaiting()
        playback.runner.resetStepState()
        playback.chain.setValue(1)
        try await playback.tick()
        XCTAssertEqual(playback.guides, [7000])
        try await playback.tick(6999)
        XCTAssertEqual(playback.runner.progress, 1)
        try await playback.tick(7000)
        XCTAssertEqual(playback.runner.progress, 5)
    }

    func testSeekingDuringWaitRebasesWithoutKeepingOldWait() async throws {
        let playback = Playback(); defer { playback.stop() }
        try await playback.startWaiting()
        playback.runner.progressOffset(4)
        playback.chain.setValue(1)
        playback.auto(reset: true)
        try await playback.tick()
        XCTAssertEqual(playback.presses, [6200])
        try await playback.tick(6699)
        XCTAssertEqual(playback.presses, [6200])
        try await playback.tick(6700)
        XCTAssertEqual(playback.presses, [6200, 6700])
        XCTAssertEqual(playback.scheduled, playback.presses)
    }

    func testResettingWaitWhilePausedDoesNotCountPauseTwice() async throws {
        let playback = Playback(); defer { playback.stop() }
        try await playback.startWaiting()
        playback.runner.playmode = false
        try await playback.tick(7200)
        playback.runner.resetStepState()
        try await playback.tick()
        playback.chain.setValue(1)
        playback.now = 9200
        playback.runner.playmode = true
        try await playback.tick()
        XCTAssertEqual(playback.guides, [10000])
        try await playback.tick(9999)
        XCTAssertEqual(playback.runner.progress, 1)
        try await playback.tick(10000)
        XCTAssertEqual(playback.runner.progress, 5)
    }

    func testSeekingWhilePausedRebasesAtResume() async throws {
        let playback = Playback(); defer { playback.stop() }
        try await playback.startWaiting()
        playback.runner.playmode = false
        try await playback.tick(7200)
        playback.runner.progressOffset(4)
        try await playback.tick()
        playback.chain.setValue(1)
        playback.now = 9200
        playback.auto(reset: true)
        try await playback.tick()
        XCTAssertEqual(playback.presses, [9200])
        try await playback.tick(9699)
        XCTAssertEqual(playback.presses, [9200])
        try await playback.tick(9700)
        XCTAssertEqual(playback.presses, [9200, 9700])
        XCTAssertEqual(playback.scheduled, playback.presses)
    }
}
