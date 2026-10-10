#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
@testable import unipad

/// Drives a real SoundEngine on the simulator with a one-pad pack, to check that an interrupted
/// engine swallows the pad instead of starting a node on an engine that is not rendering. A real
/// interruption (an incoming call) cannot be raised on a simulator, so the notification is posted
/// through the same handler the system would call.
@MainActor
struct SoundEngineInterruptionTests {
    final class StubPack: UniPack {
        private let file: URL
        override var id: String { "stub-pack" }

        init(soundFile: URL) {
            self.file = soundFile
            super.init()
            title = "stub"
            buttonX = 1
            buttonY = 1
            chain = 1
            var queue = Deque<Sound>()
            queue.append(Sound(file: soundFile, loop: 0))
            soundTable = [[[queue]]]
            soundCount = 1
        }

        override func lastModified() -> TimeInterval { 0 }
        override func loadInfo() -> UniPack { self }
        override func loadDetail() -> UniPack { self }
        override func checkFile() {}
        override func delete() {}
        override func getPathString() -> String { file.deletingLastPathComponent().path }
        override func getByteSize() -> Int64 { 0 }
    }

    /// 100 ms of silence: the engine only has to be able to decode and schedule it.
    private func writeSilentSound() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "SoundEngineInterruptionTests-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        try file.write(from: buffer)
        return url
    }

    private func makeLoadedEngine() async throws -> (SoundEngine, TestSoundLoadListener, StubPack) {
        let url = try writeSilentSound()
        let pack = StubPack(soundFile: url)
        let listener = TestSoundLoadListener()
        let engine = SoundEngine(unipack: pack, chain: ChainObserver(), loadingListener: listener)

        // The loader runs on a utility queue and reports back on the main queue. Bounded wait.
        let deadline = Date().addingTimeInterval(20)
        while !listener.finished, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(listener.finished, "the pack did not finish loading within 20 s")
        #expect(listener.failure == nil)
        return (engine, listener, pack)
    }

    /// Recovery runs on the audio session worker and reports back on the main queue. Bounded wait.
    private func waitWhile(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// What the session activation hook saw, written from whichever thread ran it.
    final class ActivationCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(onMainThread: Bool, waitedOut: Bool)] = []

        func record(onMainThread: Bool, waitedOut: Bool) {
            lock.withLock { calls.append((onMainThread, waitedOut)) }
        }

        var count: Int { lock.withLock { calls.count } }
        var anyOnMainThread: Bool { lock.withLock { calls.contains { $0.onMainThread } } }
        var anyWaitedOut: Bool { lock.withLock { calls.contains { $0.waitedOut } } }
    }

    private func interruption(
        _ type: AVAudioSession.InterruptionType,
        shouldResume: Bool = false
    ) -> Notification {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if shouldResume {
            info[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue
        }
        return Notification(name: AVAudioSession.interruptionNotification, object: nil, userInfo: info)
    }

    @Test func anInterruptedEngineSwallowsThePadInsteadOfStartingANode() async throws {
        let (engine, _, _) = try await makeLoadedEngine()
        defer { engine.destroy() }

        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 1)

        engine.handleInterruption(interruption(.began))
        #expect(engine.isPlaybackSuppressed)

        engine.soundOn(x: 0, y: 0)
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 1, "a pad reached play() while the session was interrupted")

        engine.handleInterruption(interruption(.ended, shouldResume: true))
        try await waitWhile { engine.isPlaybackSuppressed }
        #expect(!engine.isPlaybackSuppressed)

        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 2)
    }

    /// Taking the session back can block on the audio server, and pads run on the main thread. The
    /// pad pressed while the engine needs a recovery is silent and returns at once; the activation
    /// here holds until that pad has returned, so a pad that waited for it would wait out the
    /// timeout. The pads after the recovery play.
    @Test func aPadThatNeedsARecoveryDoesNotWaitForTheSession() async throws {
        let (engine, _, _) = try await makeLoadedEngine()
        defer { engine.destroy() }
        let padReturned = DispatchSemaphore(value: 0)
        let calls = ActivationCalls()
        engine.activateSessionForRecovery = {
            let waitedOut = padReturned.wait(timeout: .now() + 2) == .timedOut
            calls.record(onMainThread: Thread.isMainThread, waitedOut: waitedOut)
        }
        engine.handleInterruption(interruption(.began))
        // Without `.shouldResume` the next pad is what asks for the recovery.
        engine.handleInterruption(interruption(.ended))

        engine.soundOn(x: 0, y: 0)
        padReturned.signal()
        try await waitWhile { engine.isPlaybackSuppressed }

        #expect(calls.count == 1)
        #expect(!calls.anyOnMainThread, "the session was activated on the main thread")
        #expect(!calls.anyWaitedOut, "the pad waited for the session to be activated")
        #expect(!engine.isPlaybackSuppressed)
        let playsBefore = engine.playsStarted
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == playsBefore + 1, "the pad after the recovery did not play")
    }

    @Test func aMediaServicesResetSuppressesPlaybackUntilTheEngineRunsAgain() async throws {
        let (engine, _, _) = try await makeLoadedEngine()
        defer { engine.destroy() }

        engine.handleMediaServicesReset()
        try await waitWhile { engine.isPlaybackSuppressed }

        // The simulator gives the session straight back, so the engine recovers and plays; on a
        // device that fails, the pad is silent. Either way play() is only reached once the engine
        // reports that it runs.
        let playsBefore = engine.playsStarted
        engine.soundOn(x: 0, y: 0)
        if engine.isPlaybackSuppressed {
            #expect(engine.playsStarted == playsBefore)
        } else {
            #expect(engine.playsStarted == playsBefore + 1)
        }
    }

    @Test func aDestroyedEngineNeverPlaysAgain() async throws {
        let (engine, _, _) = try await makeLoadedEngine()
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 1)

        engine.destroy()
        engine.handleInterruption(interruption(.ended, shouldResume: true))
        engine.soundOn(x: 0, y: 0)

        #expect(engine.isPlaybackSuppressed)
        #expect(engine.playsStarted == 1)
    }
}
#endif
