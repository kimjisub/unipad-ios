import XCTest
@testable import unipad

@MainActor
final class AutoPlayRunnerTests: XCTestCase {
    private final class Recorder: AutoPlayRunner.Listener {
        var starts = 0
        var ends = 0
        var onFinish: (() -> Void)?
        var guidePads: [Int] = []
        var pressTimes: [Int64] = []
        var pressedPads: [Int] = []
        var releaseTimes: [Int64] = []
        var inputBoundaries: [Int64?] = []
        /// Guide pads on screen, as the play screen tracks them.
        var litGuides: Set<Int> = []
        func onStart() { starts += 1 }
        func onEnd() { ends += 1; onFinish?() }
        func onPadTouchOn(x: Int, y: Int, inputID: UUID) {}
        func onPadTouchOff(x: Int, y: Int, inputIDs: [UUID]) {}
        func onPadTouchOn(x: Int, y: Int, inputID: UUID, scheduledAtMs: Int64) {
            pressedPads.append(x * 256 + y)
            pressTimes.append(scheduledAtMs)
        }
        func onPadTouchOff(x: Int, y: Int, inputIDs: [UUID], scheduledAtMs: Int64) { releaseTimes.append(scheduledAtMs) }
        func onInputTimeThrough(_ at: Int64?) { inputBoundaries.append(at) }
        func onChainChange(c: Int) {}
        func onGuidePadOn(x: Int, y: Int, targetWallTimeMs: Int64) {
            guidePads.append(x * 256 + y)
            litGuides.insert(x * 256 + y)
        }
        func onGuidePadOff(x: Int, y: Int) { litGuides.remove(x * 256 + y) }
        func onGuideLedUpdate(x: Int, y: Int, velocity: Int) {}
        func onGuideChainOn(c: Int) {}
        func onRemoveGuide() { litGuides.removeAll() }
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

    func testLateTickKeepsScheduledPressAndReleaseTimes() async throws {
        let pack = UniPack()
        pack.autoPlayTable = AutoPlay(elements: [
            .on(x: 0, y: 0, currChain: 0, num: 0), .delay(delay: 2),
            .on(x: 0, y: 1, currChain: 0, num: 0), .delay(delay: 3),
            .off(x: 0, y: 0, currChain: 0)
        ])
        let clock = TestManualClock()
        let recorder = Recorder()
        let runner = AutoPlayRunner(unipack: pack, listener: recorder, chain: ChainObserver(),
                                    clock: { clock.read() }, sleep: { _ in clock.advance(20); await Task.yield() })
        defer { runner.stop() }
        runner.launch()
        try await wait { recorder.ends == 1 }
        XCTAssertEqual(recorder.pressTimes, [1000, 1002])
        XCTAssertEqual(recorder.releaseTimes, [1005])
        XCTAssertEqual(recorder.inputBoundaries.first!, .min)
        XCTAssertTrue(recorder.inputBoundaries.compactMap { $0 }.contains(1020))
        XCTAssertNil(recorder.inputBoundaries.last!)
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

    private func twoStepPack() -> UniPack {
        let pack = UniPack()
        pack.autoPlayTable = AutoPlay(elements: [
            .on(x: 0, y: 0, currChain: 0, num: 0), .delay(delay: 100),
            .on(x: 0, y: 1, currChain: 0, num: 0),
        ])
        return pack
    }

    private func startStepPractice(_ runner: AutoPlayRunner) {
        runner.practiceGuide = true
        runner.stepMode = true
        runner.playmode = false
        runner.launch()
    }


    /// The guided chord is still owed until its pads are pressed. Scanning past it must not
    /// discard it when sound-producing autoplay starts, even at the end of the table.
    func testStepToSoundingAutoplayKeepsUnplayedPadsAcrossPauseDurations() async throws {
        for pauseBeforeFirstTick in [false, true] {
            for pausedMs: Int64 in [0, 1, 300, 3_000] {
                for partialChord in [false, true] {
                    for lastGroup in [false, true] {
                        let label = "pauseBeforeFirstTick=\(pauseBeforeFirstTick), pause=\(pausedMs), partial=\(partialChord), final=\(lastGroup)"
                        let pack = UniPack()
                        var elements: [AutoPlay.Element] = [
                            .on(x: 0, y: 0, currChain: 0, num: 0), .delay(delay: 200),
                            .on(x: 0, y: 1, currChain: 0, num: 0),
                            .on(x: 0, y: 2, currChain: 0, num: 0),
                        ]
                        if !lastGroup {
                            elements += [.delay(delay: 250), .on(x: 0, y: 3, currChain: 0, num: 0)]
                        }
                        pack.autoPlayTable = AutoPlay(elements: elements)
                        let clock = TestManualClock()
                        let recorder = Recorder()
                        var ticks = 0
                        let runner = AutoPlayRunner(unipack: pack, listener: recorder, chain: ChainObserver(),
                                                    clock: { clock.read() }, sleep: { _ in
                            ticks += 1
                            await Task.yield()
                        })
                        let vm = PlayViewModel()
                        vm.autoPlayRunner = runner
                        defer { runner.stop() }
                        vm.switchPlayMode(.stepPractice)
                        try await wait { recorder.guidePads == [0] }
                        runner.stepPadPressed(x: 0, y: 0)
                        try await wait { recorder.guidePads == [0, 1, 2] }
                        // Leave this press queued, as a user's press can arrive just before
                        // the mode button in the same tick.
                        if partialChord { runner.stepPadPressed(x: 0, y: 1) }
                        clock.advance(pausedMs)
                        vm.switchPlayMode(.autoPlay)
                        if pauseBeforeFirstTick {
                            vm.autoPlayPause()
                            clock.advance(pausedMs)
                            vm.autoPlayResume()
                        }
                        let resumedAt = clock.read()
                        let nextTick = ticks + 2
                        try await wait { ticks >= nextTick || !runner.active }
                        let pending = partialChord ? [2] : [1, 2]
                        XCTAssertEqual(recorder.pressedPads, pending, label)
                        XCTAssertEqual(recorder.pressTimes, Array(repeating: resumedAt, count: pending.count), label)
                        if !lastGroup {
                            clock.advance(249)
                            let nextTick = ticks + 2
                            try await wait { ticks >= nextTick || !runner.active }
                            XCTAssertEqual(recorder.pressedPads, pending, label)
                            clock.advance(1)
                            let finalTick = ticks + 2
                            try await wait { ticks >= finalTick || !runner.active }
                            XCTAssertEqual(recorder.pressedPads, pending + [3], label)
                            XCTAssertEqual(recorder.pressTimes.last, resumedAt + 250, label)
                        }
                        XCTAssertFalse(runner.active, label)
                    }
                }
            }
        }
    }

    /// The play button in step practice resumes silent timed guidance. It is deliberately
    /// outside the sounding-autoplay rule and keeps the existing scan position.
    func testStepResumeKeepsExistingSilentGuideBehavior() async throws {
        for pausedMs: Int64 in [0, 1, 300, 3_000] {
            for lastGroup in [false, true] {
                let pack = UniPack()
                var elements: [AutoPlay.Element] = [
                    .on(x: 0, y: 0, currChain: 0, num: 0), .delay(delay: 200),
                    .on(x: 0, y: 1, currChain: 0, num: 0),
                ]
                if !lastGroup { elements += [.delay(delay: 4_000), .on(x: 0, y: 2, currChain: 0, num: 0)] }
                pack.autoPlayTable = AutoPlay(elements: elements)
                let clock = TestManualClock()
                let recorder = Recorder()
                var ticks = 0
                let runner = AutoPlayRunner(unipack: pack, listener: recorder, chain: ChainObserver(),
                                            clock: { clock.read() }, sleep: { _ in
                    ticks += 1
                    await Task.yield()
                })
                let vm = PlayViewModel()
                vm.autoPlayRunner = runner
                defer { runner.stop() }
                vm.switchPlayMode(.stepPractice)
                try await wait { recorder.guidePads == [0] }
                runner.stepPadPressed(x: 0, y: 0)
                try await wait { recorder.guidePads == [0, 1] }
                clock.advance(pausedMs)
                vm.autoPlayResume()
                let nextTick = ticks + 2
                try await wait { ticks >= nextTick || !runner.active }
                XCTAssertEqual(vm.playMode, .guidePlay)
                XCTAssertTrue(runner.practiceGuide)
                XCTAssertFalse(runner.stepMode)
                XCTAssertEqual(recorder.pressedPads, [])
                XCTAssertEqual(runner.progress, lastGroup ? 3 : 4, "The silent guide must retain its existing scan position")
            }
        }
    }

    func testCompletedStepPracticeRelaunchesAtTheFirstPad() async throws {
        let recorder = Recorder()
        let runner = AutoPlayRunner(unipack: twoStepPack(), listener: recorder, chain: ChainObserver())
        defer { runner.stop() }
        startStepPractice(runner)
        try await wait { recorder.guidePads == [0] }
        runner.stepPadPressed(x: 0, y: 0)
        try await wait { recorder.guidePads == [0, 1] }
        runner.stepPadPressed(x: 0, y: 1)
        try await wait { recorder.ends == 1 }
        XCTAssertFalse(runner.active)

        runner.launch()
        try await wait { recorder.guidePads.count >= 3 }
        XCTAssertEqual(recorder.guidePads, [0, 1, 0])
        XCTAssertEqual(recorder.starts, 2)
        runner.stepPadPressed(x: 0, y: 0)
        try await wait { recorder.guidePads.count >= 4 }
        XCTAssertEqual(recorder.guidePads, [0, 1, 0, 1])
        runner.stepPadPressed(x: 0, y: 1)
        try await wait { recorder.ends == 2 }
    }

    func testStepPracticeEndsOnlyAfterTheLastGroupIsPressed() async throws {
        let recorder = Recorder()
        var ticks = 0
        let runner = AutoPlayRunner(unipack: twoStepPack(), listener: recorder, chain: ChainObserver(), sleep: {
            ticks += 1
            try await Task.sleep(nanoseconds: $0)
        })
        defer { runner.stop() }
        startStepPractice(runner)
        try await wait { recorder.guidePads == [0] }
        runner.stepPadPressed(x: 0, y: 0)
        try await wait { recorder.guidePads == [0, 1] }
        let shown = ticks
        try await wait { ticks >= shown + 5 || recorder.ends > 0 }
        XCTAssertEqual(recorder.ends, 0, "The run ended before the last group was played")
        XCTAssertTrue(runner.active)
        XCTAssertEqual(recorder.litGuides, [1])

        runner.stepPadPressed(x: 0, y: 1)
        try await wait { recorder.ends == 1 }
        XCTAssertEqual(recorder.litGuides, [])
        XCTAssertFalse(runner.active)
    }

    func testRunLeavingStepPracticeAtTheLastGroupTurnsItsGuidesOff() async throws {
        let recorder = Recorder()
        let runner = AutoPlayRunner(unipack: twoStepPack(), listener: recorder, chain: ChainObserver())
        defer { runner.stop() }
        startStepPractice(runner)
        try await wait { recorder.guidePads == [0] }
        runner.stepPadPressed(x: 0, y: 0)
        try await wait { recorder.guidePads == [0, 1] }
        runner.stepMode = false
        try await wait { recorder.ends == 1 }
        XCTAssertEqual(recorder.litGuides, [], "A finished run left its last guide lit")
    }

    /// Guide play: autoplay keeps the time and the user plays the pads the guide shows. Skipping ahead
    /// moves the guide to the pads at the new place in the song, not the ones the clock had reached.
    func testSkippingAheadInGuidePlayGuidesThePadsAtTheNewPlace() async throws {
        let pack = UniPack()
        pack.autoPlayTable = AutoPlay(elements: (0..<60).flatMap { pad -> [AutoPlay.Element] in
            [.on(x: pad / 8, y: pad % 8, currChain: 0, num: 0), .delay(delay: 100)]
        })
        let clock = TestManualClock()
        let recorder = Recorder()
        // Time stands still 300 ms into the song, so the guide only moves because of the skip.
        let runner = AutoPlayRunner(unipack: pack, listener: recorder, chain: ChainObserver(), clock: { clock.read() }, sleep: { _ in
            if clock.read() < 1300 { clock.advance(10) }
            await Task.yield()
        })
        defer { runner.stop() }
        runner.practiceGuide = true
        runner.playmode = true
        runner.launch()
        try await wait { clock.read() >= 1300 && !recorder.litGuides.isEmpty }
        let before = recorder.litGuides

        let shownBefore = recorder.guidePads.count
        runner.progressOffset(40)
        let next = (runner.progress + 1) / 2
        let nextKey = (next / 8) * 256 + next % 8
        try await wait { recorder.guidePads.count > shownBefore }

        // The pad at the new place is due at once, so it may already be off again; the ones after it stay.
        XCTAssertEqual(recorder.guidePads.dropFirst(shownBefore).first, nextKey, "the guide did not move to pad \(next) after skipping ahead")
        XCTAssertFalse(recorder.litGuides.isEmpty)
        XCTAssertTrue(recorder.litGuides.isDisjoint(with: before), "the guide kept the pads from before the skip")
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
