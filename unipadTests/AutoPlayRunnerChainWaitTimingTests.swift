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
        var guidePads: [Int] = []
        var litGuides: Set<Int> = []
        var hints: [Int] = []
        var chainChanges: [(time: Int64, chain: Int)] = []

        init(elements suppliedElements: [AutoPlay.Element]? = nil) {
            let pack = UniPack()
            var elements: [AutoPlay.Element] = [.delay(delay: 1000), .chain(c: 1)]
            for index in 0..<3 {
                elements += [.on(x: 0, y: 0, currChain: 1, num: index),
                             .off(x: 0, y: 0, currChain: 1), .delay(delay: index == 2 ? 10000 : 500)]
            }
            // Keep the runner alive through the trailing delay while each deadline is sampled.
            elements.append(.off(x: 0, y: 0, currChain: 1))
            pack.autoPlayTable = AutoPlay(elements: suppliedElements ?? elements)
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
        func onChainChange(c: Int) { chainChanges.append((now, c)); chain.setValue(c) }
        func onGuidePadOn(x: Int, y: Int, targetWallTimeMs: Int64) {
            guides.append(targetWallTimeMs)
            guidePads.append(x * 256 + y)
            litGuides.insert(x * 256 + y)
        }
        func onGuidePadOff(x: Int, y: Int) { litGuides.remove(x * 256 + y) }
        func onGuideLedUpdate(x: Int, y: Int, velocity: Int) {}
        func onGuideChainOn(c: Int) { hints.append(c) }
        func onRemoveGuide() { litGuides.removeAll() }
        func chainButsRefresh() {}
        func onProgressUpdate(progress: Int) {}
    }

    private var delayedSwitch: [AutoPlay.Element] {
        [.on(x: 0, y: 0, currChain: 0, num: 0), .delay(delay: 100), .chain(c: 1),
         .delay(delay: 900)]
    }

    func testPendingSwitchPausesWithSongTime() async throws {
        let playback = Playback(elements: delayedSwitch); defer { playback.stop() }
        playback.runner.launch()
        try await playback.waitForIteration(1)
        try await playback.tick(1020)
        XCTAssertTrue(playback.chainChanges.isEmpty)
        playback.runner.playmode = false
        try await playback.tick(5020)
        XCTAssertTrue(playback.chainChanges.isEmpty)
        playback.runner.playmode = true
        try await playback.tick(5099)
        XCTAssertTrue(playback.chainChanges.isEmpty)
        try await playback.tick(5100)
        XCTAssertEqual(playback.chainChanges.map(\.chain), [1])
    }

    func testStoppingDiscardsASwitchStillInsideTheDelay() async throws {
        let playback = Playback(elements: delayedSwitch)
        playback.runner.launch()
        try await playback.waitForIteration(1)
        try await playback.tick(1020)
        playback.stop()
        playback.now = 1170
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(playback.chainChanges.isEmpty)
        XCTAssertFalse(playback.runner.active)
    }

    func testPracticeUsesTheOriginalPageBeforeTheSwitch() async throws {
        let playback = Playback(elements: [
            .on(x: 0, y: 0, currChain: 0, num: 0), .delay(delay: 1),
            .on(x: 0, y: 1, currChain: 0, num: 0), .delay(delay: 99), .chain(c: 1),
            .delay(delay: 1000), .on(x: 0, y: 0, currChain: 1, num: 0), .delay(delay: 1000),
        ]); defer { playback.stop() }
        playback.runner.practiceGuide = true
        playback.runner.launch()
        try await playback.waitForIteration(1)
        XCTAssertEqual(playback.guides, [1000, 1001])
        XCTAssertTrue(playback.hints.isEmpty)
        try await playback.tick(1300)
        XCTAssertEqual(playback.hints, [1])
        try await playback.tick(5300)
        XCTAssertTrue(playback.chainChanges.isEmpty)
        playback.chain.setValue(1)
        try await playback.tick()
        try await playback.tick()
        XCTAssertEqual(playback.guides.last, 6100)
    }

    func testSlowStepInputAfterAChainMoveKeepsAlreadyPlayedNotes() async throws {
        for pressed in [0, 1] {
            let pending = 1 - pressed
            let playback = Playback(elements: [
                .on(x: 0, y: 0, currChain: 0, num: 0), .delay(delay: 1),
                .on(x: 0, y: 1, currChain: 0, num: 0), .delay(delay: 99), .chain(c: 1),
                .delay(delay: 200), .on(x: 0, y: 2, currChain: 1, num: 0), .delay(delay: 1000),
            ]); defer { playback.stop() }
            playback.runner.practiceGuide = true
            playback.runner.stepMode = true
            playback.runner.playmode = false
            playback.runner.launch()
            try await playback.waitForIteration(1)
            XCTAssertEqual(playback.litGuides, [0, 1])
            playback.runner.stepPadPressed(x: 0, y: pressed)
            try await playback.tick(1050)
            XCTAssertEqual(playback.litGuides, [pending])

            // A hand-played sound moves the page after 100 ms of wall time. The next
            // written input still belongs to the original page while step practice waits.
            playback.chain.setValue(1)
            try await playback.tick(1100)
            XCTAssertEqual(playback.hints.last, 0)
            try await playback.tick(1400)
            let beforeReturn = playback.guidePads.count
            playback.chain.setValue(0)
            try await playback.tick()
            XCTAssertEqual(Array(playback.guidePads.dropFirst(beforeReturn)), [pending],
                           "Returning to the song's page must not guide an already played note")
            XCTAssertEqual(playback.litGuides, [pending])

            playback.runner.stepPadPressed(x: 0, y: pending)
            try await playback.tick(1450)
            XCTAssertEqual(playback.hints.last, 1)
            playback.chain.setValue(1)
            try await playback.tick(1500)
            XCTAssertEqual(playback.litGuides, [2], "The next group must still be reachable")
        }
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
