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
        try writeLevel(0, frames: 480, to: root.appendingPathComponent("sounds/a.wav"))
        return root
    }

    /// A 48 kHz stereo sound file holding one constant level.
    private func writeLevel(_ level: Float, frames: AVAudioFrameCount, to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) { buffer.floatChannelData?[channel][frame] = level }
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
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

    /// A Launchpad note that arrives twice, the second time on another chain, is lifted once: that
    /// lift stops both endless sounds, so none is left that no release can stop.
    func testControllerReleaseStopsEndlessSoundsItStartedOnEveryChain() async throws {
        let root = try pack(loop: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try "title=Controller Release\nproducerName=Test\nbuttonX=8\nbuttonY=8\nchain=2\n".write(
            to: root.appendingPathComponent("info"), atomically: true, encoding: .utf8)
        try "1 1 1 a.wav 0\n2 1 1 a.wav 0\n".write(
            to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        let leds = root.appendingPathComponent("keyLed")
        try FileManager.default.createDirectory(at: leds, withIntermediateDirectories: true)
        for chain in 1...2 {
            try "on 1 1 a 5\ndelay 60000\n".write(to: leds.appendingPathComponent("\(chain) 1 1 0"), atomically: true, encoding: .utf8)
        }
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        let runner = try XCTUnwrap(vm.ledRunner)

        vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.midi))
        runner.loop()
        vm.selectChain(1)
        vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.midi))
        runner.loop()
        XCTAssertTrue(runner.isEventExist(x: 0, y: 0, chain: 0))
        XCTAssertTrue(runner.isEventExist(x: 0, y: 0, chain: 1))
        XCTAssertEqual(engine.activePlayIDs.count, 2, "sounds of different chains overlap")
        vm.padTouch(x: 0, y: 0, isDown: false, trigger: .pad(.midi))

        runner.loop()
        XCTAssertTrue(engine.activePlayIDs.isEmpty, "an endless sound outlived the note's release")
        XCTAssertFalse(runner.isEventExist(x: 0, y: 0))
    }

    /// Changing the press light option while a finger holds a pad keeps that pad sounding, and the
    /// finger's lift still stops it.
    func testChangingThePressLightKeepsAHeldPadSounding() async throws {
        let root = try pack(loop: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        let finger = UUID()

        vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen), inputID: finger)
        let held = engine.activePlayIDs
        XCTAssertEqual(held.count, 1)
        vm.scbFeedbackLight.setChecked(!vm.scbFeedbackLight.checked)
        XCTAssertEqual(engine.activePlayIDs, held, "the option change stopped the held pad")
        vm.padTouch(x: 0, y: 0, isDown: false, trigger: .pad(.screen), inputID: finger)

        XCTAssertTrue(engine.activePlayIDs.isEmpty, "the lift after the option change was ignored")
    }

    func testOpeningOptionsReleasesControllerHoldBeforeAnotherFingerPlays() async throws {
        try await checkControllerReleaseBoundary { $0.toggleOptionWindow(true) }
    }

    func testPausingReleasesControllerHoldBeforeAnotherFingerPlays() async throws {
        try await checkControllerReleaseBoundary { $0.onPause() }
    }

    func testDisconnectingReleasesControllerHoldBeforeAnotherFingerPlays() async throws {
        try await checkControllerReleaseBoundary { vm in
            vm.setupMidiController()
            MidiManager.shared.controller?.onDetach()
            // The controller callback is dispatched to the main actor.
            let deadline = Date().addingTimeInterval(3)
            while vm.padItems[0][0] != nil && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func testOpeningOptionsPreservesAFingerSharingTheControllerPad() async throws {
        try await checkControllerReleaseBoundary(keepingFinger: true) { $0.toggleOptionWindow(true) }
    }

    func testPausingPreservesAFingerSharingTheControllerPad() async throws {
        try await checkControllerReleaseBoundary(keepingFinger: true) { $0.onPause() }
    }

    private func checkControllerReleaseBoundary(
        keepingFinger: Bool = false,
        boundary: (PlayViewModel) async throws -> Void
    ) async throws {
        let root = try pack(loop: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let leds = root.appendingPathComponent("keyLed")
        try FileManager.default.createDirectory(at: leds, withIntermediateDirectories: true)
        try "on 1 1 a 5\ndelay 100\n".write(to: leds.appendingPathComponent("1 1 1 0"), atomically: true, encoding: .utf8)
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        let runner = try XCTUnwrap(vm.ledRunner)
        let finger = UUID()
        vm.scbFeedbackLight.setChecked(true)
        vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.midi))
        if keepingFinger {
            vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen), inputID: finger)
        }
        runner.loop()
        let held = engine.activePlayIDs
        try await boundary(vm)
        runner.loop()
        if keepingFinger {
            XCTAssertEqual(engine.activePlayIDs, held, "a real finger still holds the pad")
            XCTAssertEqual(vm.padItems[0][0]?.channel, .pressed)
            XCTAssertTrue(runner.isEventExist(x: 0, y: 0))
        } else {
            XCTAssertTrue(engine.activePlayIDs.isEmpty, "a disconnected controller must not keep sounding")
            XCTAssertNil(vm.padItems[0][0])
            XCTAssertFalse(runner.isEventExist(x: 0, y: 0))
            vm.toggleOptionWindow(false)
            vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen), inputID: finger)
        }
        vm.padTouch(x: 0, y: 0, isDown: false, trigger: .pad(.screen), inputID: finger)
        runner.loop()
        XCTAssertTrue(engine.activePlayIDs.isEmpty, "a lost controller release stranded a later finger's sound")
        XCTAssertNil(vm.padItems[0][0], "a lost controller release stranded the press light")
        XCTAssertFalse(runner.isEventExist(x: 0, y: 0), "a lost controller release stranded an endless light")
    }

    func testLastFingerLiftStopsItsReplacementSoundButKeepsThePressLight() async throws {
        let root = try pack(loop: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        let first = UUID(), last = UUID()
        vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen), inputID: first)
        vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen), inputID: last)
        let sounding = engine.activePlayIDs
        vm.padTouch(x: 0, y: 0, isDown: false, trigger: .pad(.screen), inputID: last)
        XCTAssertEqual(sounding.count, 1)
        XCTAssertTrue(engine.activePlayIDs.isEmpty, "the lifted finger owns the replacement sound")
        XCTAssertEqual(vm.padItems[0][0]?.channel, .pressed)
        vm.padTouch(x: 0, y: 0, isDown: false, trigger: .pad(.screen), inputID: first)
        XCTAssertTrue(engine.activePlayIDs.isEmpty)
        XCTAssertNil(vm.padItems[0][0])
    }

    func testFingerLiftStopsItsReplacementSoundButKeepsTheControllerPressLight() async throws {
        let root = try pack(loop: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        let finger = UUID()
        vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.midi))
        vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen), inputID: finger)
        let sounding = engine.activePlayIDs
        vm.padTouch(x: 0, y: 0, isDown: false, trigger: .pad(.screen), inputID: finger)
        XCTAssertEqual(sounding.count, 1)
        XCTAssertTrue(engine.activePlayIDs.isEmpty, "the finger owns the replacement sound")
        XCTAssertEqual(vm.padItems[0][0]?.channel, .pressed)
        vm.padTouch(x: 0, y: 0, isDown: false, trigger: .pad(.midi))
        XCTAssertTrue(engine.activePlayIDs.isEmpty)
        XCTAssertNil(vm.padItems[0][0])
    }

    func testFirstFingerReleaseStopsOnlyItsChainSoundAndLight() async throws {
        try await checkSeparateChainOwners(first: .pad(.screen), last: .pad(.screen), releaseFirst: true)
    }

    func testLastFingerReleaseStopsOnlyItsChainSoundAndLight() async throws {
        try await checkSeparateChainOwners(first: .pad(.screen), last: .pad(.screen), releaseFirst: false)
    }

    func testFingerReleasePreservesTheControllerOnAnotherChain() async throws {
        try await checkSeparateChainOwners(first: .pad(.screen), last: .pad(.midi), releaseFirst: true)
    }

    func testControllerReleasePreservesTheFingerOnAnotherChain() async throws {
        try await checkSeparateChainOwners(first: .pad(.screen), last: .pad(.midi), releaseFirst: false)
    }

    func testPlayerReleasePreservesAutoplayOnAnotherChain() async throws {
        try await checkSeparateChainOwners(first: .pad(.screen), last: .autoplay, releaseFirst: true)
    }

    func testAutoplayReleasePreservesThePlayerOnAnotherChain() async throws {
        try await checkSeparateChainOwners(first: .pad(.screen), last: .autoplay, releaseFirst: false)
    }

    func testDisconnectStopsOnlyTheControllerSoundAndLightAcrossChains() async throws {
        try await checkSeparateChainOwners(first: .pad(.midi), last: .pad(.screen), releaseFirst: true, detach: true)
    }

    /// Two chains start distinguishable endless voices and animations on the same input pad. A
    /// release must retire its own chain even while another input keeps the press feedback lit.
    private func checkSeparateChainOwners(
        first: PlayTrigger, last: PlayTrigger, releaseFirst: Bool, detach: Bool = false
    ) async throws {
        let root = try pack(loop: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        try "title=Separate Owners\nproducerName=Test\nbuttonX=8\nbuttonY=8\nchain=2\n".write(
            to: root.appendingPathComponent("info"), atomically: true, encoding: .utf8)
        try "1 1 1 a.wav 0\n2 1 1 a.wav 0\n".write(
            to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        let leds = root.appendingPathComponent("keyLed")
        try FileManager.default.createDirectory(at: leds, withIntermediateDirectories: true)
        for chain in 1...2 {
            try "on 1 \(chain + 1) a 5\ndelay 60000\n".write(
                to: leds.appendingPathComponent("\(chain) 1 1 0"), atomically: true, encoding: .utf8)
        }
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        let runner = try XCTUnwrap(vm.ledRunner)
        vm.scbFeedbackLight.setChecked(true)
        let firstID = UUID(), lastID = UUID()
        vm.padTouch(x: 0, y: 0, isDown: true, trigger: first, inputID: firstID)
        runner.loop()
        let firstSound = engine.activePlayIDs
        vm.selectChain(1)
        vm.padTouch(x: 0, y: 0, isDown: true, trigger: last, inputID: lastID)
        runner.loop()
        let lastSound = engine.activePlayIDs.subtracting(firstSound)
        XCTAssertEqual(firstSound.count, 1)
        XCTAssertEqual(lastSound.count, 1)
        XCTAssertTrue(runner.isEventExist(x: 0, y: 0, chain: 0))
        XCTAssertTrue(runner.isEventExist(x: 0, y: 0, chain: 1))

        // An unknown finger, controller identity or autoplay press never releases either owner.
        for trigger in [PlayTrigger.pad(.screen), .pad(.midi), .autoplay] {
            vm.padTouch(x: 0, y: 0, isDown: false, trigger: trigger, inputID: UUID())
        }
        runner.loop()
        XCTAssertEqual(engine.activePlayIDs, firstSound.union(lastSound))
        XCTAssertEqual(vm.padItems[0][0]?.channel, .pressed)
        XCTAssertTrue(runner.isEventExist(x: 0, y: 0, chain: 0))
        XCTAssertTrue(runner.isEventExist(x: 0, y: 0, chain: 1))

        if detach {
            vm.setupMidiController()
            MidiManager.shared.controller?.onDetach()
            let deadline = Date().addingTimeInterval(3)
            while runner.isEventExist(x: 0, y: 0, chain: 0) && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        } else {
            vm.padTouch(x: 0, y: 0, isDown: false, trigger: releaseFirst ? first : last,
                        inputID: releaseFirst ? firstID : lastID)
        }
        runner.loop()
        XCTAssertEqual(engine.activePlayIDs, releaseFirst ? lastSound : firstSound,
                       "a release must stop only its own chain's sound")
        XCTAssertEqual(runner.isEventExist(x: 0, y: 0, chain: 0), !releaseFirst)
        XCTAssertEqual(runner.isEventExist(x: 0, y: 0, chain: 1), releaseFirst)
        XCTAssertEqual(vm.padItems[0][0]?.channel, .pressed, "another input still presses the pad")

        vm.padTouch(x: 0, y: 0, isDown: false, trigger: releaseFirst ? last : first,
                    inputID: releaseFirst ? lastID : firstID)
        runner.loop()
        XCTAssertTrue(engine.activePlayIDs.isEmpty)
        XCTAssertFalse(runner.isEventExist(x: 0, y: 0))
        XCTAssertNil(vm.padItems[0][0])
    }

    func testPlayerReleaseLeavesTheNewAutoplaySoundAndLight() async throws {
        try await checkOverlappingLight(first: .pad(.screen), last: .autoplay)
    }

    func testAutoplayReleaseLeavesTheNewPlayerSoundAndLight() async throws {
        try await checkOverlappingLight(first: .autoplay, last: .pad(.screen))
    }

    private func checkOverlappingLight(first: PlayTrigger, last: PlayTrigger) async throws {
        let root = try pack(loop: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let leds = root.appendingPathComponent("keyLed")
        try FileManager.default.createDirectory(at: leds, withIntermediateDirectories: true)
        try "on 1 1 a 5\ndelay 100\n".write(to: leds.appendingPathComponent("1 1 1 0"), atomically: true, encoding: .utf8)
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        let runner = try XCTUnwrap(vm.ledRunner)
        let earlier = UUID(), later = UUID()
        vm.padTouch(x: 0, y: 0, isDown: true, trigger: first, inputID: earlier)
        runner.loop()
        vm.padTouch(x: 0, y: 0, isDown: true, trigger: last, inputID: later)
        runner.loop()
        let sounding = engine.activePlayIDs
        vm.padTouch(x: 0, y: 0, isDown: false, trigger: first, inputID: earlier)
        runner.loop()
        XCTAssertEqual(engine.activePlayIDs, sounding, "the other source owns the replacement sound")
        XCTAssertTrue(runner.isEventExist(x: 0, y: 0), "the other source owns the replacement light")
        vm.padTouch(x: 0, y: 0, isDown: false, trigger: last, inputID: later)
        runner.loop()
        XCTAssertTrue(engine.activePlayIDs.isEmpty)
        XCTAssertFalse(runner.isEventExist(x: 0, y: 0))
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
        try "on 1 1\n\(change)off 1 1\ndelay 60000\noff 1 2\n".write(
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
        try "1 1 1 a.wav 0 20\n1 1 2 a.wav 0\n".write(
            to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        try "on 1 1\non 1 2\ndelay 60000\n".write(
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
    /// Before each call the repeat after the one about to render has to be queued too, which the scheduler
    /// does on its own queue: a player node that runs out of buffers at the end of a render plays a buffer
    /// queued after that one render late. Real-time playback keeps 100 ms queued ahead for this; the loop
    /// below renders as soon as repeats arrive, so it waits for that one instead.
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
                let needed = min(50, step + 2)
                let deadline = Date().addingTimeInterval(Self.silenceLimit)
                while scheduler.buffersScheduled < needed {
                    guard Date() < deadline else {
                        return XCTFail("repeat \(needed) was not queued within \(Int(Self.silenceLimit)) s")
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

    /// Records what the scheduler asks of a player node without attaching it to an engine.
    private nonisolated final class RecordingPlayerNode: AVAudioPlayerNode, @unchecked Sendable {
        private let lock = NSLock()
        private var types: [AVAudioPlayerNodeCompletionCallbackType] = []
        var callbackTypes: [AVAudioPlayerNodeCompletionCallbackType] { lock.withLock { types } }

        override func scheduleBuffer(
            _ buffer: AVAudioPCMBuffer,
            at when: AVAudioTime?,
            options: AVAudioPlayerNodeBufferOptions = [],
            completionCallbackType callbackType: AVAudioPlayerNodeCompletionCallbackType,
            completionHandler: AVAudioPlayerNodeCompletionHandler? = nil
        ) {
            lock.withLock { types.append(callbackType) }
        }

        override func play() {}
        override func stop() {}
    }

    /// A played-back callback arms a timer inside the player node, and the node's next stop() waits
    /// for that timer's default-priority thread. A pad that takes the node back stops it from the
    /// screen's thread, so the last repeat must not ask for one.
    func testLastFiniteRepeatDoesNotWaitForPlayedBackAudio() throws {
        let node = RecordingPlayerNode()
        let scheduler = FiniteRepeatScheduler()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        XCTAssertNil(scheduler.start(buffer, node: node, totalPlays: 2) { _ in })
        defer { scheduler.stop(node) }
        XCTAssertEqual(
            node.callbackTypes, [.dataConsumed, .dataRendered],
            "raw types \(node.callbackTypes.map(\.rawValue)); 0 consumed, 1 rendered, 2 played back"
        )
    }

    /// Runs `work` on the audio worker, where the engine's taps and its start and stop belong.
    private func onAudioWorker(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            AudioSessionWorker.shared.run(work) { continuation.resume() }
        }
    }

    private func audioEngine(of engine: SoundEngine) throws -> AVAudioEngine {
        try XCTUnwrap(Mirror(reflecting: engine).children.first { $0.label == "engine" }?.value as? AVAudioEngine)
    }

    /// Records the final mix of the real-time engine while `body` runs, and has removed the tap by the
    /// time this returns, so the screen model's clean-up stops an engine nobody records any more. The
    /// recording is attached as `final-mix.wav`.
    private func recordingMix(
        of engine: SoundEngine,
        _ body: (MixRecording, Double) async throws -> Void
    ) async throws {
        let audio = try audioEngine(of: engine)
        let mix = MixRecording()
        await onAudioWorker {
            audio.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in mix.record(buffer) }
        }
        let rate = audio.mainMixerNode.outputFormat(forBus: 0).sampleRate
        var failure: Error?
        do { try await body(mix, rate) } catch { failure = error }
        await onAudioWorker { audio.mainMixerNode.removeTap(onBus: 0) }
        try attachMix(mix, rate: rate)
        if let failure { throw failure }
    }

    private func attachMix(_ mix: MixRecording, rate: Double) throws {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("mix-\(UUID().uuidString).wav")
        try mix.write(to: wav, sampleRate: rate)
        defer { try? FileManager.default.removeItem(at: wav) }
        let recording = XCTAttachment(contentsOfFile: wav)
        recording.name = "final-mix.wav"
        recording.lifetime = .keepAlways
        add(recording)
    }

    private func report(_ text: String) {
        print(text)
        add(XCTAttachment(string: text))
    }

    /// The first unbroken stretch at `level` from `start` on. Measured unbroken, so a cut or a gap
    /// shortens it.
    private func stretch(at level: Float, in samples: [Float], from start: Int = 0) -> Range<Int>? {
        let isLevel: (Float) -> Bool = { abs($0 - level) < 0.02 }
        guard let first = samples[start...].firstIndex(where: isLevel) else { return nil }
        let end = samples[first...].firstIndex { !isLevel($0) } ?? samples.endIndex
        return first..<end
    }

    /// Every pad press runs on the screen's thread, and stopping a player node there can wait for the
    /// node. A pad that finds an idle node has nothing to stop.
    func testPadTakesAnIdleVoiceWithoutStoppingIt() async throws {
        let root = try pack(loop: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        try "1 1 1 a.wav 1\n1 1 2 a.wav 1\n".write(to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen))
        XCTAssertEqual(engine.playerNodesStopped, 0, "a node that never played was stopped")
        try await wait(for: "the first sound", until: { engine.activeVoiceCount == 0 })
        vm.padTouch(x: 0, y: 1, isDown: true, trigger: .pad(.screen))
        XCTAssertEqual(engine.playsStarted, 2)
        XCTAssertEqual(engine.playerNodesStopped, 0, "the node the first sound freed was stopped")
    }

    /// Drive the production graph without a hardware deadline. A host output underrun must not
    /// replace part of the scheduled sound with silence before this test can inspect it.
    /// Loading, decoding, pad presses, repeat supply, completion and voice reuse stay real.
    private func recordingOfflineMix(
        of engine: SoundEngine,
        _ body: (AVAudioEngine, MixRecording, Double) async throws -> Void
    ) async throws {
        let audio = try audioEngine(of: engine)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let preparation: Result<Void, Error> = await withCheckedContinuation { continuation in
            AudioSessionWorker.shared.run({
                Result {
                    audio.stop()
                    try audio.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
                    try audio.start()
                }
            }, then: { continuation.resume(returning: $0) })
        }
        try preparation.get()
        let mix = MixRecording()
        var failure: Error?
        do { try await body(audio, mix, format.sampleRate) } catch { failure = error }
        await onAudioWorker { audio.stop() }
        try attachMix(mix, rate: format.sampleRate)
        if let failure { throw failure }
    }

    /// Check continuous samples and same-node reuse through the production graph's offline output.
    /// One render call both consumes and records samples, so this recording cannot expose a real-time
    /// tail cut between consumption and output. The no-stop assertion below and the callback-type
    /// check in testLastFiniteRepeatDoesNotWaitForPlayedBackAudio guard that case separately.
    func testLastRepeatPlaysInFullBeforeTheNextPadReusesItsVoice() async throws {
        let root = try pack(loop: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeLevel(0.125, frames: 4_800, to: root.appendingPathComponent("sounds/a.wav"))
        try writeLevel(0.25, frames: 4_800, to: root.appendingPathComponent("sounds/b.wav"))
        try "1 1 1 a.wav 3\n1 1 2 b.wav 1\n".write(to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        try await recordingOfflineMix(of: engine) { audio, mix, rate in
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.manualRenderingFormat, frameCapacity: 480))
            var firstPlay: Int?
            var firstSlot: Int?
            var nextPressed = false
            engine.playbackCompletionDelivery = { playID, failure, complete in
                XCTAssertNil(failure)
                complete()
                guard playID == firstPlay, !nextPressed else { return }
                nextPressed = true
                // Take the first idle node at the very callback that frees it, without a wall-clock wait.
                MainActor.assumeIsolated {
                    vm.padTouch(x: 0, y: 1, isDown: true, trigger: .pad(.screen))
                    XCTAssertEqual(try? self.activeVoiceSlot(of: engine), firstSlot, "the next pad did not reuse the freed node")
                }
            }
            defer { engine.playbackCompletionDelivery = nil }
            vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen))
            firstPlay = engine.activePlayIDs.first
            firstSlot = try activeVoiceSlot(of: engine)
            XCTAssertNotNil(firstPlay)
            XCTAssertEqual(engine.repeatedBuffersScheduled, 2, "the initial lookahead must not depend on this render loop")
            // 800 ms includes both sounds and 200 ms of silence even with render-quantum latency.
            for step in 0..<80 {
                if step == 10 {
                    // As in the busy-screen test, allow the real supplier to append the last repeat
                    // before rendering past the second buffer. Do not fabricate any audio samples.
                    try await wait(for: "the last repeat to be queued", until: { engine.repeatedBuffersScheduled == 3 })
                }
                XCTAssertEqual(try audio.renderOffline(480, to: output), .success)
                XCTAssertEqual(output.frameLength, 480)
                mix.record(output)
                if step == 29 {
                    // All 14,400 repeated frames have rendered. Wait for the scheduler and main-queue
                    // completion to press the next pad before advancing the offline output again.
                    try await wait(for: "the final repeat to free its voice", until: { nextPressed })
                }
            }
            XCTAssertTrue(nextPressed, "the final repeat never freed its voice")
            try await wait(for: "the next sound to free its voice", until: { engine.activeVoiceCount == 0 })
            XCTAssertEqual(engine.activeVoiceCount, 0)
            XCTAssertEqual(engine.playsStarted, 2)
            XCTAssertEqual(engine.playerNodesStopped, 0, "the next pad must take the freed node without stopping it")
            let measured = try checkVoiceReuseMix(mix.samples, rate: rate)
            let pause = Double(measured.next.lowerBound - measured.repeated.upperBound) / rate
            report("MIX rate=\(rate) unbrokenRepeatedFrames=\(measured.repeated.count) expected=\(Int(rate * 0.3)) unbrokenNextFrames=\(measured.next.count) expected=\(Int(rate * 0.1)) pauseBeforeNextMs=\(Int(pause * 1000))")
        }
    }

    private func activeVoiceSlot(of engine: SoundEngine) throws -> Int {
        let slots = try XCTUnwrap(Mirror(reflecting: engine).children.first { $0.label == "nodePlayID" }?.value as? [Int])
        XCTAssertEqual(slots.filter { $0 != 0 }.count, 1)
        return try XCTUnwrap(slots.firstIndex { $0 != 0 })
    }

    /// Keep the real output check and its defect controls on the same decision path.
    @discardableResult
    private func checkVoiceReuseMix(_ samples: [Float], rate: Double) throws -> (repeated: Range<Int>, next: Range<Int>) {
        guard let repeated = stretch(at: 0.125, in: samples),
              let next = stretch(at: 0.25, in: samples, from: repeated.upperBound),
              !samples[..<repeated.lowerBound].contains(where: { abs($0 - 0.25) < 0.02 }) else {
            throw WaitFailed(errorDescription: "missing repeated or next sound")
        }
        guard abs(Double(repeated.count) - rate * 0.3) <= rate * 0.003,
              abs(Double(next.count) - rate * 0.1) <= rate * 0.003 else {
            throw WaitFailed(errorDescription: "the voices did not reach the mix whole and unbroken")
        }
        return (repeated, next)
    }

    func testVoiceReuseMixRejectsInternalSilenceAndCutTails() throws {
        let repeated = [Float](repeating: 0.125, count: 14_400)
        let next = [Float](repeating: 0.25, count: 4_800)
        let silence = [Float](repeating: 0, count: 1_348)
        XCTAssertNoThrow(try checkVoiceReuseMix(repeated + next, rate: 48_000))
        XCTAssertThrowsError(try checkVoiceReuseMix(
            Array(repeated.prefix(3_054)) + silence + Array(repeated.dropFirst(4_402)) + next, rate: 48_000))
        XCTAssertThrowsError(try checkVoiceReuseMix(Array(repeated.dropLast(1_348)) + next, rate: 48_000))
        XCTAssertThrowsError(try checkVoiceReuseMix(repeated + Array(next.dropLast(1_348)), rate: 48_000))
        XCTAssertThrowsError(try checkVoiceReuseMix(
            repeated + Array(next.prefix(1_000)) + silence + Array(next.dropFirst(1_000)), rate: 48_000))
        XCTAssertThrowsError(try checkVoiceReuseMix(next + repeated + next, rate: 48_000))
    }

    /// A one-shot frees its player node once the node has read the last of it, which can be before the
    /// mix has it. The next pad, pressed at that very moment, takes the same node (the first idle one);
    /// the one-shot still has to reach the mix in full, and the next sound right after it.
    func testOneShotPlaysInFullWhenTheNextPadTakesItsVoiceAtOnce() async throws {
        let root = try pack(loop: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeLevel(0.125, frames: 4_800, to: root.appendingPathComponent("sounds/a.wav"))
        try writeLevel(0.25, frames: 4_800, to: root.appendingPathComponent("sounds/b.wav"))
        try "1 1 1 a.wav 1\n1 1 2 b.wav 1\n".write(to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        try await recordingMix(of: engine) { mix, rate in
            var firstPlay: Int?
            var nextPressed = false
            engine.playbackCompletionDelivery = { playID, _, complete in
                complete()
                guard playID == firstPlay, !nextPressed else { return }
                nextPressed = true
                MainActor.assumeIsolated { vm.padTouch(x: 0, y: 1, isDown: true, trigger: .pad(.screen)) }
            }
            defer { engine.playbackCompletionDelivery = nil }
            vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen))
            firstPlay = engine.activePlayIDs.first
            try await wait(for: "the one-shot to free its voice", until: { nextPressed })
            try await wait(for: "the next pad", until: { engine.activeVoiceCount == 0 })
            try await wait(for: "the mix after both sounds", until: { mix.silentFramesAfterLastSound(below: 0.01) >= Int(rate * 0.2) })

            let samples = mix.samples
            let first = try XCTUnwrap(stretch(at: 0.125, in: samples))
            let next = try XCTUnwrap(stretch(at: 0.25, in: samples, from: first.upperBound))
            let pause = Double(next.lowerBound - first.upperBound) / rate
            report("MIX one-shot rate=\(rate) unbrokenFirstFrames=\(first.count) unbrokenNextFrames=\(next.count) expected=\(Int(rate * 0.1)) pauseBeforeNextMs=\(Int(pause * 1000))")
            XCTAssertEqual(Double(first.count), rate * 0.1, accuracy: rate * 0.003, "the next pad cut the one-shot's tail")
            XCTAssertEqual(Double(next.count), rate * 0.1, accuracy: rate * 0.003, "the reused node did not play the next sound in full")
        }
    }

    /// A pad takes an idle player node without stopping it. A node that played to its end before the
    /// engine stopped and started again (a route change) still has to play the next sound in full.
    func testIdleVoicePlaysInFullAfterTheEngineRestarts() async throws {
        let root = try pack(loop: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeLevel(0.125, frames: 4_800, to: root.appendingPathComponent("sounds/a.wav"))
        try writeLevel(0.25, frames: 4_800, to: root.appendingPathComponent("sounds/b.wav"))
        try "1 1 1 a.wav 1\n1 1 2 b.wav 1\n".write(to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        let audio = try audioEngine(of: engine)
        try await recordingMix(of: engine) { mix, rate in
            vm.padTouch(x: 0, y: 0, isDown: true, trigger: .pad(.screen))
            try await wait(for: "the first sound", until: { engine.activeVoiceCount == 0 })
            await onAudioWorker { audio.stop() }
            // The gate finds the engine stopped, ignores this pad and restarts the engine.
            vm.padTouch(x: 0, y: 1, isDown: true, trigger: .pad(.screen))
            XCTAssertEqual(engine.playsStarted, 1)
            try await wait(for: "the engine restart", until: { !engine.isPlaybackSuppressed })
            vm.padTouch(x: 0, y: 1, isDown: true, trigger: .pad(.screen))
            XCTAssertEqual(engine.playsStarted, 2)
            try await wait(for: "the next pad", until: { engine.activeVoiceCount == 0 })
            try await wait(for: "the mix after the next sound", until: {
                mix.samples.contains { abs($0 - 0.25) < 0.02 } && mix.silentFramesAfterLastSound(below: 0.01) >= Int(rate * 0.2)
            })

            let next = try XCTUnwrap(stretch(at: 0.25, in: mix.samples))
            report("MIX restart rate=\(rate) unbrokenNextFrames=\(next.count) expected=\(Int(rate * 0.1))")
            XCTAssertEqual(Double(next.count), rate * 0.1, accuracy: rate * 0.003, "the idle node did not play after the engine restarted")
        }
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

/// The first channel of everything a tap hands over, in order.
private nonisolated final class MixRecording: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Float] = []
    var samples: [Float] { lock.withLock { recorded } }

    func record(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        lock.withLock { recorded.append(contentsOf: frames) }
    }

    /// Zero until something louder than `threshold` has been recorded.
    func silentFramesAfterLastSound(below threshold: Float) -> Int {
        lock.withLock {
            guard let last = recorded.lastIndex(where: { abs($0) >= threshold }) else { return 0 }
            return recorded.count - last - 1
        }
    }

    func write(to url: URL, sampleRate: Double) throws {
        let mono = samples
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, mono.count))) else { return }
        buffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            buffer.floatChannelData?[0].update(from: base, count: samples.count)
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }
}
