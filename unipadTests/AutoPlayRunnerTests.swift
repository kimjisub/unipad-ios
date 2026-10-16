import XCTest
@testable import unipad

@MainActor
final class AutoPlayRunnerTests: XCTestCase {
    private final class Recorder: AutoPlayRunner.Listener {
        var starts = 0
        var ends = 0
        var onFinish: (() -> Void)?
        var guidePads: [Int] = []
        func onStart() { starts += 1 }
        func onEnd() { ends += 1; onFinish?() }
        func onPadTouchOn(x: Int, y: Int) {}
        func onPadTouchOff(x: Int, y: Int) {}
        func onChainChange(c: Int) {}
        func onGuidePadOn(x: Int, y: Int, targetWallTimeMs: Int64) { guidePads.append(x * 256 + y) }
        func onGuidePadOff(x: Int, y: Int) {}
        func onGuideLedUpdate(x: Int, y: Int, velocity: Int) {}
        func onGuideChainOn(c: Int) {}
        func onRemoveGuide() {}
        func chainButsRefresh() {}
        func onProgressUpdate(progress: Int) {}
    }

    private func wait(until finished: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !finished() {
            guard Date() < deadline else {
                XCTFail("Autoplay did not report the expected lifecycle event")
                throw CancellationError()
            }
            await Task.yield()
        }
    }

    func testCompletedSongBecomesInactiveAndCanLaunchAgain() async throws {
        let pack = UniPack()
        pack.autoPlayTable = AutoPlay(elements: [.delay(delay: 0), .delay(delay: 0)])
        let recorder = Recorder()
        let runner = AutoPlayRunner(unipack: pack, listener: recorder, chain: ChainObserver())
        defer { recorder.onFinish = nil; runner.stop() }
        recorder.onFinish = { XCTAssertFalse(runner.active, "A completed song must be inactive before onEnd") }
        runner.launch()
        runner.launch() // A running song must not be launched twice.
        try await wait { recorder.ends == 1 }
        XCTAssertEqual(recorder.starts, 1)
        XCTAssertEqual(runner.progress, 2)
        runner.launch()
        try await wait { recorder.ends == 2 }
        XCTAssertEqual(recorder.starts, 2)
        XCTAssertEqual(runner.progress, 2)
        XCTAssertFalse(runner.active)
    }

    func testCompletedStepPracticeRelaunchesAtTheFirstPad() async throws {
        let pack = UniPack()
        pack.autoPlayTable = AutoPlay(elements: [
            .on(x: 0, y: 0, currChain: 0, num: 0), .delay(delay: 100),
            .on(x: 0, y: 1, currChain: 0, num: 0),
        ])
        let recorder = Recorder()
        let runner = AutoPlayRunner(unipack: pack, listener: recorder, chain: ChainObserver())
        defer { runner.stop() }
        runner.practiceGuide = true
        runner.stepMode = true
        runner.playmode = false
        runner.launch()
        try await wait { recorder.guidePads == [0] }
        runner.stepPadPressed(x: 0, y: 0)
        try await wait { recorder.ends == 1 }
        XCTAssertEqual(recorder.guidePads, [0, 1])
        XCTAssertFalse(runner.active)

        // Do not press the last pad: a new run must not inherit its pending step.
        runner.launch()
        try await wait { recorder.guidePads.count >= 3 }
        XCTAssertEqual(recorder.guidePads, [0, 1, 0])
        XCTAssertEqual(recorder.starts, 2)
        runner.stepPadPressed(x: 0, y: 0)
        try await wait { recorder.ends == 2 }
        XCTAssertEqual(recorder.guidePads, [0, 1, 0, 1])
    }

    func testMissingAutoplayCanLaunchAfterATableIsLoaded() async throws {
        let pack = UniPack()
        let recorder = Recorder()
        let runner = AutoPlayRunner(unipack: pack, listener: recorder, chain: ChainObserver())
        defer { runner.stop() }
        runner.launch()
        try await wait { recorder.ends == 1 }
        XCTAssertFalse(runner.active)
        pack.autoPlayTable = AutoPlay(elements: [])
        runner.launch()
        try await wait { recorder.ends == 2 }
        XCTAssertEqual(recorder.starts, 2)
        XCTAssertFalse(runner.active)
    }

    func testEndCallbackCanImmediatelyLaunchAnotherSong() async throws {
        let pack = UniPack()
        pack.autoPlayTable = AutoPlay(elements: [])
        let recorder = Recorder()
        let runner = AutoPlayRunner(unipack: pack, listener: recorder, chain: ChainObserver())
        defer { recorder.onFinish = nil; runner.stop() }
        recorder.onFinish = {
            if recorder.ends == 1 { runner.launch() }
        }
        runner.launch()
        try await wait { recorder.ends == 2 }
        XCTAssertEqual(recorder.starts, 2)
        XCTAssertFalse(runner.active)
    }

    func testRestartWaitsForCancelledRunEvenAfterTwoStops() async throws {
        let pack = UniPack()
        pack.autoPlayTable = AutoPlay(elements: [.delay(delay: 0)])
        let recorder = Recorder()
        var suspended: CheckedContinuation<Void, Never>?
        var replacementSuspended: CheckedContinuation<Void, Never>?
        var sleepCalls = 0
        let runner = AutoPlayRunner(unipack: pack, listener: recorder, chain: ChainObserver(), sleep: { _ in
            sleepCalls += 1
            if sleepCalls == 1 {
                await withCheckedContinuation { suspended = $0 }
            } else {
                await withCheckedContinuation { replacementSuspended = $0 }
            }
        })
        defer { suspended?.resume(); replacementSuspended?.resume(); runner.stop() }
        runner.launch()
        try await wait { suspended != nil }
        runner.stop()
        runner.stop()
        runner.launch()
        XCTAssertTrue(runner.active)
        await Task.yield()
        XCTAssertEqual(recorder.starts, 1, "The replacement must wait for the cancelled run")
        suspended?.resume()
        suspended = nil
        try await wait { replacementSuspended != nil }
        XCTAssertEqual(recorder.starts, 2)
        XCTAssertEqual(recorder.ends, 0, "A cancelled run must not send onEnd")
        XCTAssertTrue(runner.active, "The cancelled run must not clear its replacement")
        runner.launch()
        replacementSuspended?.resume()
        replacementSuspended = nil
        try await wait { recorder.ends == 1 }
        XCTAssertEqual(recorder.starts, 2)
        XCTAssertFalse(runner.active)
    }
}
