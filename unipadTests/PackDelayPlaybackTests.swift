import Foundation
import Testing
@testable import unipad

/// Exercise file parsing together with every consumer of accumulated pack delays. Virtual time
/// reaches the largest accepted delays without waiting for days or changing ordinary song timing.
@MainActor
@Suite(.serialized)
struct PackDelayPlaybackTests {
    static let tokens = [
        "9223372036854775807", "-9223372036854775808",
        "2147483647", "-2147483648", "0", "25"
    ]

    private final class Recorder: AutoPlayRunner.Listener {
        var ended = false
        var presses: [Int] = []
        var guides: [(pad: Int, target: Int64)] = []
        func onStart() {}
        func onEnd() { ended = true }
        func onPadTouchOn(x: Int, y: Int, inputID: UUID) { presses.append(y) }
        func onPadTouchOff(x: Int, y: Int, inputIDs: [UUID]) {}
        func onChainChange(c: Int) {}
        func onGuidePadOn(x: Int, y: Int, targetWallTimeMs: Int64) {
            guides.append((y, targetWallTimeMs))
        }
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
            try #require(Date() < deadline, "Playback did not reach the expected event")
            await Task.yield()
        }
    }

    private func load(_ token: String) throws -> UniPackFolder {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PackDelayPlaybackTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let led = root.appending(path: "keyLed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: led, withIntermediateDirectories: true)
        try "title=Delay boundaries\nproducerName=UniPad\nbuttonX=2\nbuttonY=2\nchain=1\n"
            .write(to: root.appending(path: "info"), atomically: true, encoding: .utf8)
        try "".write(to: root.appending(path: "keySound"), atomically: true, encoding: .utf8)
        // Leading consecutive waits exercise the step scanner before it has found its first pad.
        try "d \(token)\nd \(token)\no 1 1\nf 1 1\nd 100\no 1 2\nf 1 2\n"
            .write(to: root.appending(path: "autoPlay"), atomically: true, encoding: .utf8)
        try "o 1 1 a 5\nd \(token)\nd \(token)\nf 1 1\n"
            .write(to: led.appending(path: "1 1 1 1"), atomically: true, encoding: .utf8)
        let pack = UniPackFolder(rootFolder: root)
        pack.checkFile()
        pack.loadInfo()
        pack.loadDetail()
        try #require(!pack.criticalError)
        let delays = try #require(pack.autoPlayTable).elements.compactMap { element -> Int? in
            if case .delay(let delay) = element { return delay }
            return nil
        }
        let accepted = Int32(token).map(Int.init)
        // Stop before running unsafe input if parsing regresses, and report a readable failure.
        try #require(delays == (accepted.map { [$0, $0, 100] } ?? [100]))
        let animation = try #require(pack.ledAnimationTable?[0][0][0]?.first)
        let ledDelays = animation.ledEvents.compactMap { event -> Int? in
            if case .delay(let delay) = event { return delay }
            return nil
        }
        try #require(ledDelays == (accepted.map { [$0, $0] } ?? []))
        let errors = pack.errorDetail?.components(separatedBy: "\n") ?? []
        #expect(errors.count == (accepted == nil ? 4 : 0))
        #expect(errors.allSatisfy { $0.hasSuffix("format is incorrect") })
        return pack
    }

    private func totalDelay(_ token: String) -> Int64 {
        Int32(token).map { Int64($0) * 2 } ?? 0
    }

    private func runAutoplay(_ token: String, guide: Bool, toggleGuide: Bool = false) async throws {
        let pack = try load(token)
        let recorder = Recorder()
        var now: Int64 = 10_000
        let start = now
        let total = totalDelay(token)
        var ticks = [max(0, total - 800), max(0, total), max(0, total + 100)].makeIterator()
        weak var guideRunner: AutoPlayRunner?
        let runner = AutoPlayRunner(unipack: pack, listener: recorder, chain: ChainObserver(), clock: { now }, sleep: { _ in
            if toggleGuide { guideRunner?.practiceGuide = true }
            now = ticks.next().map { start + $0 } ?? now + 100
            await Task.yield()
        })
        defer { runner.stop() }
        guideRunner = runner
        runner.practiceGuide = guide
        runner.launch()
        try await wait { recorder.ended }
        #expect(recorder.presses == [0, 1])
        #expect(!runner.active)
        if guide {
            #expect(recorder.guides.map(\.pad) == [0, 1])
            #expect(recorder.guides.map(\.target) == [start + total, start + total + 100])
        }
    }

    @Test(arguments: tokens)
    func guideTimelineFromRepeatedFileDelays(_ token: String) async throws {
        try await runAutoplay(token, guide: true)
    }

    @Test(arguments: tokens)
    func ordinaryAutoplayFromRepeatedFileDelays(_ token: String) async throws {
        try await runAutoplay(token, guide: false)
    }

    @Test(arguments: ["9223372036854775807", "-9223372036854775808"])
    func guideCanBeEnabledDuringPlayback(_ token: String) async throws {
        try await runAutoplay(token, guide: false, toggleGuide: true)
    }

    @Test(arguments: tokens)
    func stepScanFromRepeatedFileDelays(_ token: String) async throws {
        let pack = try load(token)
        let recorder = Recorder()
        let runner = AutoPlayRunner(unipack: pack, listener: recorder, chain: ChainObserver(), sleep: { _ in
            await Task.yield()
        })
        defer { runner.stop() }
        runner.practiceGuide = true
        runner.stepMode = true
        runner.playmode = false
        runner.launch()
        try await wait { recorder.guides.count == 1 }
        #expect(recorder.guides.map(\.pad) == [0])
        runner.stepPadPressed(x: 0, y: 0)
        try await wait { recorder.guides.count == 2 }
        #expect(recorder.guides.map(\.pad) == [0, 1])
        #expect(!recorder.ended)
        runner.stepPadPressed(x: 0, y: 1)
        try await wait { recorder.ended }
        #expect(!runner.active)
    }

    @Test(arguments: tokens)
    func ledPlaybackFromRepeatedFileDelays(_ token: String) async throws {
        let pack = try load(token)
        let recorder = LedRunnerTests.Recorder()
        let clock = TestManualClock()
        let runner = LedRunner(unipack: pack, listener: recorder, chain: ChainObserver(),
                               loopDelay: 3600, clock: { clock.read() })
        defer { runner.stop() }
        runner.launch()
        try await wait { clock.wasRead }
        runner.eventOn(x: 0, y: 0)
        runner.loop() // Adopt the queued animation.
        runner.loop() // Play its first frame and consume any waits that are already due.
        let total = totalDelay(token)
        if total > 0 {
            #expect(recorder.outputs == ["padOn 0 0"])
            clock.advance(total - 1)
            runner.loop()
            #expect(recorder.outputs == ["padOn 0 0"])
            clock.advance(1)
        }
        runner.loop()
        #expect(recorder.outputs == ["padOn 0 0", "padOff 0 0"])
    }
}
