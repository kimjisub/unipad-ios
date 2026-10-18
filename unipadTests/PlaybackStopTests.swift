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
                    startEngine: {},
                    runOffMain: { _, _ in }
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

    private func checkAutoplayRelease(
        loop: Int = 0,
        manualPad: (Int, Int)? = nil,
        identifiedManual: Bool = true,
        script: String = "on 1 1\ndelay 60000\noff 1 1\n",
        autoplayPresses: Int = 1,
        stop: (PlayViewModel) -> Void
    ) async throws {
        let root = try pack(loop: loop)
        defer { try? FileManager.default.removeItem(at: root) }
        try "title=Autoplay Release\nbuttonX=8\nbuttonY=8\nchain=2\n".write(
            to: root.appendingPathComponent("info"), atomically: true, encoding: .utf8)
        try "1 1 1 a.wav \(loop)\n1 1 2 a.wav 0\n2 1 1 a.wav \(loop)\n".write(
            to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        try script.write(to: root.appendingPathComponent("autoPlay"), atomically: true, encoding: .utf8)
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        // Keep short finite samples observable even if simulator scheduling is delayed.
        engine.playbackCompletionDelivery = { _, _, _ in }
        vm.switchPlayMode(.autoPlay)
        try await wait(for: "autoplay press", until: { engine.playsStarted == autoplayPresses })
        let autoplayIDs = engine.activePlayIDs
        XCTAssertEqual(autoplayIDs.count, autoplayPresses)
        let manualTrigger: PlayTrigger = .pad(identifiedManual ? .screen : .midi)
        let manualID = identifiedManual ? UUID() : nil
        if let (x, y) = manualPad {
            vm.padTouch(x: x, y: y, isDown: true, trigger: manualTrigger, inputID: manualID)
        }
        let beforeStop = engine.activePlayIDs
        let manualIDs = beforeStop.subtracting(autoplayIDs)
        let chainBeforeStop = vm.chain.value
        stop(vm)
        XCTAssertEqual(vm.chain.value, chainBeforeStop)
        let expected = loop == 0 ? manualIDs : beforeStop
        print("AUTOPLAY RELEASE loop=\(loop) manual=\(manualPad != nil) before=\(autoplayIDs) after=\(engine.activePlayIDs)")
        XCTAssertEqual(engine.activePlayIDs, expected)
        if let (x, y) = manualPad {
            XCTAssertEqual(manualIDs.count, 1)
            vm.padTouch(x: x, y: y, isDown: false, trigger: manualTrigger, inputID: manualID)
            XCTAssertTrue(engine.activePlayIDs.isDisjoint(with: manualIDs))
        }
    }

    func testStoppingAutoplayReleasesItsInfiniteSound() async throws {
        try await checkAutoplayRelease { $0.stopAutoPlay() }
    }

    func testTurningAutoplayOffReleasesItsInfiniteSound() async throws {
        try await checkAutoplayRelease { $0.switchPlayMode(.none) }
    }

    func testTurningAutoplayOffPreservesAnotherHeldPad() async throws {
        try await checkAutoplayRelease(manualPad: (0, 1)) { $0.switchPlayMode(.none) }
    }

    func testTurningAutoplayOffPreservesManualPressOnTheSamePad() async throws {
        try await checkAutoplayRelease(manualPad: (0, 0)) { $0.switchPlayMode(.none) }
    }

    func testTurningAutoplayOffPreservesControllerPressOnTheSamePad() async throws {
        try await checkAutoplayRelease(manualPad: (0, 0), identifiedManual: false) { $0.switchPlayMode(.none) }
    }

    func testPausingAutoplayPreservesManualPressOnTheSamePad() async throws {
        try await checkAutoplayRelease(manualPad: (0, 0)) { $0.autoPlayPause() }
    }

    func testSkippingAutoplayReleasesItsInfiniteSound() async throws {
        try await checkAutoplayRelease { $0.autoPlayNext() }
    }

    func testEnteringGuideModeReleasesAutoplaySound() async throws {
        try await checkAutoplayRelease { $0.switchPlayMode(.guidePlay) }
    }

    func testSkippingAutoplayPreservesAnotherHeldPad() async throws {
        try await checkAutoplayRelease(manualPad: (0, 1)) { $0.autoPlayNext() }
    }

    func testStoppingAutoplayReleasesHeldPadsAcrossChains() async throws {
        try await checkAutoplayRelease(
            script: "on 1 1\nchain 2\non 1 1\ndelay 60000\n", autoplayPresses: 2
        ) { $0.stopAutoPlay() }
    }

    func testStoppingAutoplayPreservesFiniteAndOneShotSounds() async throws {
        for loop in [1, 50] {
            try await checkAutoplayRelease(loop: loop) { $0.stopAutoPlay() }
            try await checkAutoplayRelease(loop: loop) { $0.switchPlayMode(.none) }
        }
    }

    private func checkAutoplayOffAfterChainChange(wormhole: Int? = nil) async throws {
        let root = try pack(loop: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try "title=Autoplay Off\nproducerName=Test\nbuttonX=8\nbuttonY=8\nchain=2\n".write(
            to: root.appendingPathComponent("info"), atomically: true, encoding: .utf8)
        let suffix = wormhole.map { " \($0)" } ?? ""
        try "1 1 1 a.wav 0\(suffix)\n".write(
            to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        let change = wormhole == nil ? "chain 2\n" : ""
        try "on 1 1\n\(change)off 1 1\ndelay 60000\n".write(
            to: root.appendingPathComponent("autoPlay"), atomically: true, encoding: .utf8)
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        let runner = try XCTUnwrap(vm.autoPlayRunner)
        vm.switchPlayMode(.autoPlay)
        try await wait(for: "scripted off", until: { runner.progress >= 4 })
        XCTAssertEqual(engine.playsStarted, 1)
        XCTAssertTrue(runner.active, "check the scripted off before stop or song cleanup")
        XCTAssertTrue(engine.activePlayIDs.isEmpty, "off must release the input from the previous chain")
        XCTAssertNotEqual(vm.padItems[0][0]?.channel, .pressed)
        print("AUTOPLAY OFF wormhole=\(String(describing: wormhole)) active=\(engine.activePlayIDs)")
    }

    func testAutoplayOffReleasesInfiniteSoundAfterExplicitChainChange() async throws {
        try await checkAutoplayOffAfterChainChange()
    }

    func testAutoplayOffReleasesInfiniteSoundAfterWormhole() async throws {
        try await checkAutoplayOffAfterChainChange(wormhole: 2)
    }

    func testAutoplayOffReleasesInfiniteSoundAfterOutOfRangeWormhole() async throws {
        try await checkAutoplayOffAfterChainChange(wormhole: 20)
    }

    func testStoppingAutoplayReleasesInputPressedAfterOutOfRangeWormhole() async throws {
        let root = try pack(loop: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try "1 1 1 a.wav 0 20\n".write(
            to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        try "on 1 1\non 1 1\ndelay 60000\n".write(
            to: root.appendingPathComponent("autoPlay"), atomically: true, encoding: .utf8)
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        vm.switchPlayMode(.autoPlay)
        try await wait(for: "second autoplay press", until: { engine.playsStarted == 2 })
        XCTAssertFalse(engine.activePlayIDs.isEmpty)
        vm.autoPlayNext()
        XCTAssertTrue(engine.activePlayIDs.isEmpty)
    }

    func testAutoplayModeChangesRespectLockedFeedbackLight() async throws {
        let root = try pack(loop: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try "title=Locked Light\nproducerName=Test\nbuttonX=8\nbuttonY=8\nchain=1\nsquareButton=false\n".write(
            to: root.appendingPathComponent("info"), atomically: true, encoding: .utf8)
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        XCTAssertTrue(vm.scbFeedbackLight.locked)
        XCTAssertFalse(vm.scbFeedbackLight.checked)
        vm.switchPlayMode(.autoPlay)
        vm.switchPlayMode(.none)
        XCTAssertFalse(vm.scbFeedbackLight.checked, "turning autoplay off must respect the lock")
        vm.switchPlayMode(.autoPlay)
        vm.autoPlayResume()
        XCTAssertFalse(vm.scbFeedbackLight.checked, "resuming autoplay must respect the lock")
        let runner = try XCTUnwrap(vm.autoPlayRunner)
        try await wait(for: "song end", until: { runner.progress > 0 && !runner.active })
        XCTAssertFalse(vm.scbFeedbackLight.checked, "song end must respect the lock")
    }

    private func holdScreen() { Thread.sleep(forTimeInterval: 0.8) }

    func testRepeatSupplyDoesNotWaitForTheScreen() async throws {
        let root = try pack(loop: 50)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen))
        // Deliberately hold screen processing longer than all 50 ten-millisecond samples.
        // Supply must keep running while this actor cannot execute completion work.
        holdScreen()
        XCTAssertEqual(engine.repeatedBuffersScheduled, 50)
    }

    /// The engine renders offline, one sample length per call, on the main thread itself: the screen
    /// stays busy for the whole render and nothing hinges on how fast the simulator plays audio.
    /// Before each call the next repeat only has to be queued, which the scheduler does on its own queue.
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
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        defer {
            scheduler.stop(node)
            engine.stop()
        }
        XCTAssertNil(scheduler.start(buffer, node: node, totalPlays: 50) { failure in
            XCTAssertNil(failure)
        })
        // Nothing has rendered yet, so this is the lookahead alone: 100 ms of 10 ms samples.
        // The render loop below waits for each repeat and would hide a shorter one.
        XCTAssertEqual(scheduler.buffersScheduled, 10, "repeats queued ahead before playback")
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 480))
        var samples: [Float] = []
        // Five sample lengths past the last repeat, so a late or extra repeat would still be rendered.
        for step in 0..<55 {
            if step < 50 {
                let deadline = Date().addingTimeInterval(Self.silenceLimit)
                while scheduler.buffersScheduled <= step {
                    guard Date() < deadline else {
                        return XCTFail("repeat \(step + 1) was not queued within \(Int(Self.silenceLimit)) s")
                    }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            XCTAssertEqual(try engine.renderOffline(480, to: output), .success)
            let data = try XCTUnwrap(output.floatChannelData?[0])
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
        }
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
        vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen))
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
            vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen))
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
            vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen))
            vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen))
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
            vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen))
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
        vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen))
        vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen))
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
                vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen))
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
