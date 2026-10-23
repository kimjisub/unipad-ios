#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
@testable import unipad

/// A pack with a single pad (1,1) that the real SoundEngine loads; `chains[c]` is that pad's
/// keySound lines on chain c, in order.
final class OnePadPack: UniPack {
    private let folder: URL
    override var id: String { "one-pad-pack" }

    init(chains: [[Sound]]) {
        folder = chains.first?.first?.file.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        super.init()
        title = "stub"
        buttonX = 1
        buttonY = 1
        chain = chains.count
        soundTable = chains.map { sounds in
            var queue = Deque<Sound>()
            for (num, sound) in sounds.enumerated() {
                queue.append(Sound(file: sound.file, loop: sound.loop, wormhole: sound.wormhole, num: num))
            }
            return [[queue]]
        }
        soundCount = chains.reduce(0) { $0 + $1.count }
    }

    convenience init(soundFile: URL) {
        self.init(chains: [[Sound(file: soundFile, loop: 0)]])
    }

    override func lastModified() -> TimeInterval { 0 }
    override func loadInfo() -> UniPack { self }
    override func loadDetail() -> UniPack { self }
    override func checkFile() {}
    override func delete() {}
    override func getPathString() -> String { folder.path }
    override func getByteSize() -> Int64 { 0 }
}

@MainActor
enum SoundEngineTestSupport {
    /// 100 ms of silence: the engine only has to be able to decode and schedule it.
    static func writeSilentSound() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "SoundEngineTestSupport-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        try file.write(from: buffer)
        return url
    }

    /// A sparse 16-bit PCM WAV of `frames` silent frames whose header claims `sampleRate`, written
    /// byte by byte so the header can say what no encoder would write. `declaredFrames` can
    /// exaggerate its length without adding sample data.
    static func writeWav(sampleRate: UInt32, frames: UInt32, channels: UInt16 = 1, declaredFrames: UInt32? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "SoundEngineTestSupport-\(UUID().uuidString).wav")
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let blockAlign = channels * 2
        let dataSize = UInt32(min(UInt64(declaredFrames ?? frames) * UInt64(blockAlign), UInt64(UInt32.max) - 36))
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(channels) // PCM, channel count
        append(sampleRate); append(UInt32(clamping: UInt64(sampleRate) * UInt64(blockAlign))) // byte rate
        append(blockAlign); append(UInt16(16)) // block align, bits per sample
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        try data.write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(data.count) + UInt64(frames) * UInt64(blockAlign))
        return url
    }

    /// The bundled MP3 tone with the Info header of a song `claimingPackets` MP3 frames long, as
    /// MP3s cut from a song keep it. Both its frame and byte counts are scaled: a byte count that
    /// matches the file makes the decoder count the frames itself.
    static func writeMP3(claimingPackets: UInt32) throws -> URL {
        let fixture = try #require(Bundle(for: OnePadPack.self).url(forResource: "mp3-tone-named-wav", withExtension: "wav"))
        var data = try Data(contentsOf: fixture)
        let info = try #require(data.range(of: Data("Info".utf8))).upperBound
        func field(_ index: Int) -> UInt32 {
            data[info + 4 * index..<info + 4 * index + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func setField(_ index: Int, _ value: UInt32) {
            withUnsafeBytes(of: value.bigEndian) { data.replaceSubrange(info + 4 * index..<info + 4 * index + 4, with: $0) }
        }
        // Flags, then the frame count and the byte count when flags 1 and 2 are set.
        try #require(field(0) & 3 == 3, "the Info header carries no frame or byte count")
        let packets = field(1)
        setField(2, field(2) / packets * claimingPackets)
        setField(1, claimingPackets)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "SoundEngineTestSupport-\(UUID().uuidString).mp3")
        try data.write(to: url)
        return url
    }

    /// Starts a real engine on `pack` and waits until it has finished loading the sounds.
    static func loadedEngine(
        _ pack: UniPack, chain: ChainObserver? = nil,
        packBudget: SoundFileLimits.PackBudget = .init()
    ) async throws -> (SoundEngine, TestSoundLoadListener) {
        let listener = TestSoundLoadListener()
        let trace = SoundLoadingTrace()
        let engine = SoundEngine(unipack: pack, chain: chain ?? ChainObserver(), loadingListener: listener,
                                 packBudget: packBudget, observeLoading: trace.record)

        do {
            try await waitForLoad(listener, trace: trace)
        } catch {
            engine.destroy()
            throw error
        }
        print("SOUND-LOAD \(trace.summary)")
        return (engine, listener)
    }

    static func waitForLoad(
        _ listener: TestSoundLoadListener, trace: SoundLoadingTrace,
        timeout: Duration = .seconds(20)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !listener.finished, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard listener.finished else {
            throw SoundLoadTimeout(phase: trace.pendingPhase, trace: trace.summary)
        }
    }
}

nonisolated final class SoundLoadingTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let start = DispatchTime.now().uptimeNanoseconds
    private var events: [(SoundEngine.LoadingEvent, Double)] = []

    func record(_ event: SoundEngine.LoadingEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append((event, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000))
    }

    var lastEvent: SoundEngine.LoadingEvent? {
        lock.lock()
        defer { lock.unlock() }
        return events.last?.0
    }

    var pendingPhase: String {
        switch lastEvent {
        case .none: return "engine creation"
        case .setupQueued: return "session queue"
        case .setupStarted: return "session setup"
        case .setupFinished: return "session callback"
        case .setupDelivered, .loadQueued: return "load queue"
        case .loadStarted, .soundStarted, .soundFinished: return "decoding"
        case .completionQueued: return "completion callback"
        case .completionDelivered: return "finished"
        }
    }

    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return events.map { "\($0.0.rawValue)=\(String(format: "%.3f", $0.1))s" }.joined(separator: ", ")
    }
}
struct SoundLoadTimeout: Error, CustomStringConvertible {
    let phase: String
    let trace: String

    var description: String { "pack loading deadline expired during \(phase); \(trace)" }
}

@MainActor
struct SoundEngineLoadingWaitTests {
    /// Hold each real worker stage until after a deliberately expired deadline. An unfinished
    /// engine must never escape the helper and cause misleading playback failures afterwards.
    @Test(arguments: [SoundEngine.LoadingEvent.setupStarted, .soundStarted, .completionQueued])
    func anUnfinishedLoadThrowsWithItsPendingStage(_ heldEvent: SoundEngine.LoadingEvent) async throws {
        let sound = try SoundEngineTestSupport.writeSilentSound()
        defer { try? FileManager.default.removeItem(at: sound) }
        let trace = SoundLoadingTrace()
        let listener = TestSoundLoadListener()
        let gate = DispatchSemaphore(value: 0)
        let engine = SoundEngine(unipack: OnePadPack(soundFile: sound), chain: ChainObserver(),
            loadingListener: listener, observeLoading: { event in
                trace.record(event)
                if event == heldEvent { gate.wait() }
            })
        defer { gate.signal(); engine.destroy() }
        try await PlayUsageScenario.waitWhile(timeout: 20) { trace.lastEvent != heldEvent }
        #expect(trace.lastEvent == heldEvent, "the worker never reached the controlled hold: \(trace.summary)")
        do {
            try await SoundEngineTestSupport.waitForLoad(listener, trace: trace, timeout: .zero)
            Issue.record("an unfinished engine was returned to the playback assertions")
        } catch let error as SoundLoadTimeout {
            let expected = heldEvent == .setupStarted ? "session setup"
                : heldEvent == .soundStarted ? "decoding" : "completion callback"
            #expect(error.phase == expected)
            #expect(error.trace.contains(heldEvent.rawValue))
        }
        gate.signal()
        try await SoundEngineTestSupport.waitForLoad(listener, trace: trace)
        #expect(listener.failure == nil)
        #expect(trace.lastEvent == .completionDelivered)
    }

    @Test func aFinishedLoadDoesNotFailAnExpiredDeadline() async throws {
        let listener = TestSoundLoadListener()
        listener.onEnd()
        try await SoundEngineTestSupport.waitForLoad(listener, trace: SoundLoadingTrace(), timeout: .zero)
    }

    @Test func queueWaitsAreDistinctFromWorkerAndCallbackTime() {
        let trace = SoundLoadingTrace()
        for (event, expected) in [(SoundEngine.LoadingEvent.setupQueued, "session queue"),
                                 (.setupFinished, "session callback"), (.loadQueued, "load queue")] {
            trace.record(event)
            #expect(trace.pendingPhase == expected)
        }
    }
}
#endif
