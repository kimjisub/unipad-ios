import AVFoundation
import XCTest
@testable import unipad

/// Real silent audio and the production screen model; no waits before stopping a repeated voice.
@MainActor
final class PlaybackStopTests: XCTestCase {
    private func pack(loop: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlaybackStop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sounds"), withIntermediateDirectories: true)
        try "title=Playback Stop\nproducerName=Test\nbuttonX=8\nbuttonY=8\nchain=1\n".write(to: root.appendingPathComponent("info"), atomically: true, encoding: .utf8)
        try "1 1 1 a.wav \(loop)\n".write(to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        try "on 1 1\noff 1 1\ndelay 100\non 1 2\noff 1 2\ndelay 100\non 1 3\noff 1 3\n".write(to: root.appendingPathComponent("autoPlay"), atomically: true, encoding: .utf8)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let file = try AVAudioFile(forWriting: root.appendingPathComponent("sounds/a.wav"), settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        try file.write(from: buffer)
        return root
    }

    /// Hosted CI simulators were seen stopping the whole test process for 18–41 s at arbitrary lines,
    /// so no wait here may hinge on a short wall-clock window. A reported failure ends a wait at once;
    /// this bound only ends a run in which nothing is ever reported.
    private static let silenceLimit: TimeInterval = 120

    private struct WaitFailed: LocalizedError {
        let errorDescription: String?
    }

    private func wait(
        for what: String,
        until done: () -> Bool,
        failure: () -> String? = { nil }
    ) async throws {
        let deadline = Date().addingTimeInterval(Self.silenceLimit)
        while !done() {
            if let reason = failure() { throw WaitFailed(errorDescription: "\(what) failed: \(reason)") }
            guard Date() < deadline else {
                throw WaitFailed(errorDescription: "\(what) reported nothing within \(Int(Self.silenceLimit)) s")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Sound loading ends in `startReady`; a pack that cannot be read or sounds that cannot be
    /// decoded end in a load error or a quit request instead, and fail the wait with that reason.
    private func waitForSound(_ vm: PlayViewModel) async throws {
        try await wait(for: "sound loading", until: { vm.startReady }, failure: {
            if let error = vm.unipackLoadError { return error }
            return vm.quitRequested ? vm.toastMessage ?? "the screen asked to quit" : nil
        })
    }

    private func loaded(_ root: URL) async throws -> PlayViewModel {
        let vm = PlayViewModel()
        try await vm.loadUnipack(path: root.path)
        try await waitForSound(vm)
        _ = try XCTUnwrap(vm.soundEngine)
        return vm
    }

    private enum ReleaseContext {
        @TaskLocal static var marker = 0
    }

    func testSoundLoadingAdapterCanBeReleasedWithPendingCallbacksInsideATaskLocalScope() async {
        var screen: PlayViewModel? = PlayViewModel()
        weak var releasedScreen: PlayViewModel?
        for _ in 0..<100 {
            let owner = screen!
            releasedScreen = owner
            await withCheckedContinuation { continuation in
                // Exercise synchronous listener destruction without a current Swift task, as in
                // SoundEngine's executor-scheduled teardown. Keep the fixture owner in this task.
                DispatchQueue.main.async {
                    withUnsafeCurrentTask { XCTAssertNil($0) }
                    weak var releasedAdapter: SoundLoadingAdapter?
                    ReleaseContext.$marker.withValue(1) {
                        let adapter = SoundLoadingAdapter(viewModel: owner)
                        releasedAdapter = adapter
                        adapter.onStart(soundCount: 1)
                        adapter.onProgressTick()
                        adapter.onEnd()
                        adapter.onException(NSError(domain: "PlaybackStopTests", code: 1))
                    }
                    XCTAssertNil(releasedAdapter, "queued callbacks must not retain the listener")
                    continuation.resume()
                }
            }
        }
        XCTAssertEqual(screen?.soundLoadingMax, 0, "callbacks after listener release must do nothing")
        XCTAssertEqual(screen?.soundLoadingProgress, 0)
        XCTAssertEqual(screen?.startReady, false)
        screen = nil
        XCTAssertNil(releasedScreen, "the listener must not retain the screen")
    }

    func testAudioSessionGateCanBeReleasedInsideATaskLocalScope() {
        // Match executor-scheduled SoundEngine teardown: task-local storage, no current Swift task.
        withUnsafeCurrentTask { XCTAssertNil($0) }
        for _ in 0..<100 {
            weak var released: AudioSessionGate?
            ReleaseContext.$marker.withValue(1) {
                let gate = AudioSessionGate(hooks: AudioSessionGate.Hooks(
                    isEngineRunning: { false },
                    activateSession: {},
                    startEngine: {}
                ))
                released = gate
                XCTAssertEqual(gate.state, .ready)
            }
            XCTAssertNil(released, "the audio session gate must be released immediately")
        }
    }

    func testChainStateCanBeReleasedInsideATaskLocalScope() {
        // Releasing the LED/autoplay chain state under task-local storage used to enter Swift's
        // older-runtime isolated-deinit path and free an invalid pointer on iOS 26.3.1.
        for _ in 0..<100 {
            weak var released: ChainObserver?
            ReleaseContext.$marker.withValue(1) {
                let chain = ChainObserver()
                released = chain
                XCTAssertEqual(chain.value, 0)
            }
            XCTAssertNil(released)
        }
    }

    nonisolated private final class SelectionPack: UniPackFolder {
        private let observationsLock = NSLock()
        private var sounds: [Int] = []
        private var lights: [Int] = []
        var soundSelections: [Int] { observationsLock.withLock { sounds } }
        var lightSelections: [Int] { observationsLock.withLock { lights } }

        override func soundPush(c: Int, x: Int, y: Int) {
            let sound = super.soundGet(c: c, x: x, y: y)
            if let sound { observationsLock.withLock { sounds.append(c * 10 + sound.num) } }
            super.soundPush(c: c, x: x, y: y)
        }

        override func ledPush(c: Int, x: Int, y: Int) {
            let light = super.ledGet(c: c, x: x, y: y)
            if let light { observationsLock.withLock { lights.append(c * 10 + light.num) } }
            super.ledPush(c: c, x: x, y: y)
        }
    }

    func testAutoplayPreservesTwoConsecutiveSelections() async throws {
        try await checkSelectionOrder("on 1 1\non 1 1\ndelay 100\n", expected: [0, 1])
    }

    func testAutoplayPreservesSoundLightAndChainSelectionOrder() async throws {
        try await checkSelectionOrder("on 1 1\non 1 1\nchain 2\non 1 1\non 1 1\nchain 1\non 1 1\ndelay 100\n", expected: [0, 1, 10, 11, 0])
    }

    private func checkSelectionOrder(_ script: String, expected: [Int]) async throws {
        let root = try pack(loop: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        try "title=Selection Order\nbuttonX=8\nbuttonY=8\nchain=2\n".write(to: root.appendingPathComponent("info"), atomically: true, encoding: .utf8)
        try "1 1 1 a.wav\n1 1 1 a.wav\n2 1 1 a.wav\n2 1 1 a.wav\n".write(to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        let leds = root.appendingPathComponent("keyLed")
        try FileManager.default.createDirectory(at: leds, withIntermediateDirectories: true)
        for name in ["1 1 1 1 a", "1 1 1 1 b", "2 1 1 1 a", "2 1 1 1 b"] {
            try "on 1 1 a 5\ndelay 100\noff 1 1\n".write(to: leds.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try script.write(to: root.appendingPathComponent("autoPlay"), atomically: true, encoding: .utf8)
        let pack = SelectionPack(rootFolder: root)
        let vm = PlayViewModel()
        vm.makePack = { _ in pack }
        try await vm.loadUnipack(path: root.path)
        defer { vm.cleanup() }
        try await waitForSound(vm)
        vm.switchPlayMode(.autoPlay)
        try await wait(for: "autoplay", until: { pack.soundSelections.count >= expected.count })
        XCTAssertEqual(pack.soundSelections, expected)
        XCTAssertEqual(pack.lightSelections, expected)
        XCTAssertEqual(vm.soundEngine?.playsStarted, expected.count)
        XCTAssertEqual(vm.chain.value, 0)
    }

    private func holdScreen() { Thread.sleep(forTimeInterval: 0.8) }

    func testRepeatSupplyDoesNotWaitForTheScreen() async throws {
        let root = try pack(loop: 50)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        vm.padTouch(x: 0, y: 0, isDown: true)
        // Deliberately hold screen processing longer than all 50 ten-millisecond samples.
        // Supply must keep running while this actor cannot execute completion work.
        holdScreen()
        XCTAssertEqual(engine.repeatedBuffersScheduled, 50)
    }

    nonisolated private final class RenderCapture {
        private let lock = NSLock()
        private var samples: [Float] = []
        func append(_ buffer: AVAudioPCMBuffer) {
            guard let data = buffer.floatChannelData?[0] else { return }
            lock.withLock { samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))) }
        }
        var captured: [Float] { lock.withLock { samples } }
    }

    func testFiniteRepeatsRenderWithoutGapsWhileTheScreenIsBusy() throws {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let scheduler = FiniteRepeatScheduler()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        for channel in 0..<2 {
            for frame in 0..<480 { buffer.floatChannelData?[channel][frame] = 0.125 }
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        // Observe the rendered player output before the muted mixer; no test tone reaches speakers.
        engine.mainMixerNode.outputVolume = 0
        let capture = RenderCapture()
        node.installTap(onBus: 0, bufferSize: 480, format: format) { buffer, _ in capture.append(buffer) }
        try engine.start()
        defer {
            scheduler.stop(node)
            node.removeTap(onBus: 0)
            engine.stop()
        }
        XCTAssertNil(scheduler.start(buffer, node: node, totalPlays: 50) { failure in
            XCTAssertNil(failure)
        })
        holdScreen()
        let samples = capture.captured
        let first = try XCTUnwrap(samples.firstIndex { abs($0) > 0.01 })
        let last = try XCTUnwrap(samples.lastIndex { abs($0) > 0.01 })
        let rendered = samples[first...last]
        let silentFrames = rendered.filter { abs($0) <= 0.01 }.count
        print("RENDER finite frames=\(rendered.count) internalSilentFrames=\(silentFrames) expected=24000")
        XCTAssertEqual(rendered.count, 24_000)
        XCTAssertEqual(silentFrames, 0, "repeat supply left silence between samples")
        XCTAssertEqual(scheduler.buffersScheduled, 50)
    }

    func testHugeRepeatCountCanBeStoppedWithoutSchedulingEveryRepeat() async throws {
        let root = try pack(loop: Int.max)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = try await loaded(root)
        let engine = try XCTUnwrap(vm.soundEngine)
        let began = Date()
        vm.padTouch(x: 0, y: 0, isDown: true)
        vm.cleanup()
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
        XCTAssertLessThanOrEqual(engine.repeatedBuffersScheduled, 128)
        XCTAssertEqual(engine.activeVoiceCount, 0)
    }

    func testRepeatedVoiceCanBeStoppedImmediately() async throws {
        let root = try pack(loop: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        for round in 0..<30 {
            let vm = try await loaded(root)
            let engine = try XCTUnwrap(vm.soundEngine)
            vm.padTouch(x: 0, y: 0, isDown: true)
            XCTAssertEqual(engine.playsStarted, 1)
            if round > 0 { try await Task.sleep(for: .milliseconds(round % 10)) }
            let began = Date()
            vm.cleanup()
            XCTAssertLessThan(Date().timeIntervalSince(began), 1)
            print("STOP repeated exit round=\(round) returned")
        }
    }

    func testRepeatedVoiceCanBeRetriggeredImmediately() async throws {
        let root = try pack(loop: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        for round in 0..<100 {
            let began = Date()
            vm.padTouch(x: 0, y: 0, isDown: true)
            vm.padTouch(x: 0, y: 0, isDown: true)
            XCTAssertLessThan(Date().timeIntervalSince(began), 1)
            try await Task.sleep(for: .milliseconds(round % 10))
        }
        XCTAssertEqual(engine.playsStarted, 200)
    }

    func testFiniteRepeatsFinishAndReleaseTheirVoice() async throws {
        for loop in [3, 50] {
            let root = try pack(loop: loop)
            defer { try? FileManager.default.removeItem(at: root) }
            let vm = try await loaded(root)
            let engine = try XCTUnwrap(vm.soundEngine)
            defer { vm.cleanup() }
            vm.padTouch(x: 0, y: 0, isDown: true)
            try await wait(for: "finite repeats", until: { engine.activeVoiceCount == 0 })
            XCTAssertEqual(engine.repeatedBuffersScheduled, loop, "keySound stores total plays, not additional repeats")
            XCTAssertEqual(engine.activeVoiceCount, 0)
        }
    }

    func testStoppedRepeatCannotReviveAfterTheNodeIsReused() async throws {
        let root = try pack(loop: 50)
        defer { try? FileManager.default.removeItem(at: root) }
        // Alternate a repeated and an infinite sound on the same pad, sharing a decoded file.
        try "1 1 1 a.wav 50\n1 1 1 a.wav 0\n".write(to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        let vm = try await loaded(root)
        let engine = try XCTUnwrap(vm.soundEngine)
        defer { vm.cleanup() }
        vm.padTouch(x: 0, y: 0, isDown: true)
        vm.padTouch(x: 0, y: 0, isDown: true)
        let suppliedBeforeStop = engine.repeatedBuffersScheduled
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(engine.repeatedBuffersScheduled, suppliedBeforeStop, "obsolete callback scheduled another repeat")
        XCTAssertEqual(engine.activeVoiceCount, 1, "obsolete callback released the replacement voice")
        vm.cleanup()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(engine.activeVoiceCount, 0)
        XCTAssertEqual(engine.repeatedBuffersScheduled, suppliedBeforeStop)
        XCTAssertTrue(engine.isPlaybackSuppressed)
    }

    func testStepPracticeCanLeaveOrSwitchModesRepeatedly() async throws {
        let root = try pack(loop: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        for round in 0..<120 {
            let vm = try await loaded(root)
            let runner = try XCTUnwrap(vm.autoPlayRunner)
            vm.switchPlayMode(.stepPractice)
            try await Task.sleep(for: .milliseconds(30 + round % 10 * 7))
            try await wait(for: "step scan", until: { runner.progress > 0 })
            let began = Date()
            if round.isMultiple(of: 2) {
                vm.cleanup()
            } else {
                vm.padTouch(x: 0, y: 0, isDown: true)
                vm.switchPlayMode(.autoPlay)
                vm.switchPlayMode(.guidePlay)
                vm.switchPlayMode(.none)
                vm.cleanup()
            }
            XCTAssertLessThan(Date().timeIntervalSince(began), 1)
            XCTAssertFalse(runner.active)
            print("STOP step round=\(round) returned")
        }
    }
}
