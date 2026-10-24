#if canImport(UIKit)
import Foundation
import AVFoundation
import Testing
@testable import unipad

/// Which sound files the real engine decodes, and what a pad does with one it cannot decode.
@MainActor
struct SoundEngineDecodingTests {
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try #require(Bundle(for: OnePadPack.self).url(forResource: name, withExtension: ext))
    }

    private func undecodableSound() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "SoundEngineDecodingTests-\(UUID().uuidString).wav")
        try Data("not a wav file".utf8).write(to: url)
        return url
    }

    /// A sound that cannot be decoded is silent where it stands, and the pad's next press plays the
    /// next keySound line instead of trying the same sound for ever.
    @Test func anUndecodableSoundStillAdvancesThePadToItsNextSound() async throws {
        let good = try SoundEngineTestSupport.writeSilentSound()
        let pack = OnePadPack(chains: [[Sound(file: try undecodableSound(), loop: 0), Sound(file: good, loop: 0)]])
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(pack)
        defer { engine.destroy() }
        #expect(listener.failure == nil, "one decodable sound is enough to open the pack")

        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 0)
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 1, "the pad stayed on the sound it cannot decode")
        engine.soundOn(x: 0, y: 0)
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 2)
    }

    @Test func anUndecodableSoundStillMovesToItsWormholeChain() async throws {
        let good = try SoundEngineTestSupport.writeSilentSound()
        let pack = OnePadPack(chains: [
            [Sound(file: try undecodableSound(), loop: 0, wormhole: 1)],
            [Sound(file: good, loop: 0)],
        ])
        let chain = ChainObserver()
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(pack, chain: chain)
        defer { engine.destroy() }
        #expect(listener.failure == nil)

        engine.soundOn(x: 0, y: 0)
        try await PlayUsageScenario.waitWhile(timeout: 2) { chain.value == 0 }
        #expect(chain.value == 1, "the wormhole of a sound that cannot be decoded was dropped")
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 1)
    }

    /// A header that claims 20 Hz made a short sound resample into gigabytes at the device rate and
    /// the app run out of memory; that sound is now skipped like any other it cannot decode.
    @Test func aSoundWithAnImplausibleSampleRateIsSkippedAndTheNextOnePlays() async throws {
        let implausible = try SoundEngineTestSupport.writeWav(sampleRate: 20, frames: 4_410)
        let good = try SoundEngineTestSupport.writeWav(sampleRate: 44_100, frames: 4_410)
        let pack = OnePadPack(chains: [[Sound(file: implausible, loop: 0), Sound(file: good, loop: 0)]])
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(pack)
        defer { engine.destroy() }
        #expect(listener.failure == nil, "one decodable sound is enough to open the pack")

        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 0, "the 20 Hz sound was resampled and played")
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 1)
    }

    @Test func aSoundOverTenMinutesIsSkippedAndTheNextOnePlays() async throws {
        let long = try SoundEngineTestSupport.writeWav(sampleRate: 8_000, frames: 8_000 * 601)
        let good = try SoundEngineTestSupport.writeWav(sampleRate: 48_000, frames: 4_800)
        defer {
            try? FileManager.default.removeItem(at: long)
            try? FileManager.default.removeItem(at: good)
        }
        let pack = OnePadPack(chains: [[Sound(file: long, loop: 0), Sound(file: good, loop: 0)]])
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(pack)
        defer { engine.destroy() }
        #expect(listener.failure == nil)
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 0)
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 1)
    }

    @Test func anOversizedBufferIsSkippedAndTheNextSoundPlays() async throws {
        let frames = UInt32(SoundFileLimits.maximumBufferBytes / (2 * 4)) + 1
        let oversized = try SoundEngineTestSupport.writeWav(sampleRate: 384_000, frames: frames, channels: 2)
        let good = try SoundEngineTestSupport.writeWav(sampleRate: 48_000, frames: 4_800)
        defer {
            try? FileManager.default.removeItem(at: oversized)
            try? FileManager.default.removeItem(at: good)
        }
        let pack = OnePadPack(chains: [[Sound(file: oversized, loop: 0), Sound(file: good, loop: 0)]])
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(pack)
        defer { engine.destroy() }
        #expect(listener.failure == nil)
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 0)
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 1)
    }

    /// Real compressed files exercise the loader's shared budget and playback after a refusal.
    /// Keep the fixtures short: the production 512 MiB boundary is checked by SoundFileLimitsTests,
    /// without making this functional check decode hundreds of MB against a wall-clock deadline.
    @Test(arguments: [("aac-tone", "m4a"), ("vorbis-tone", "ogg"), ("opus-tone", "ogg")])
    func soundsPastThePackMemoryLimitAreSkippedAndTheRestPlay(_ name: String, _ ext: String) async throws {
        let silence = try fixture(name, ext)
        let source = try SoundEngine.loadAudioBuffer(from: silence)
        func bytes(at rate: Double) throws -> UInt64 {
            let frames = try SoundFileLimits.resampledFrameCount(source.frameLength,
                from: source.format.sampleRate, to: rate, channels: 2)
            return UInt64(frames) * 2 * 4
        }
        // Both simulator playback rates must admit two copies and the final short WAV, but not three.
        let limit = try 2 * bytes(at: 48_000) + 8_000
        #expect(try 3 * bytes(at: 44_100) > limit)
        let copies = try (0..<3).map { index in
            let copy = FileManager.default.temporaryDirectory
                .appending(path: "SoundEngineDecodingTests-\(UUID().uuidString)-\(index).\(ext)")
            try FileManager.default.copyItem(at: silence, to: copy)
            return copy
        }
        let good = try SoundEngineTestSupport.writeWav(sampleRate: 48_000, frames: 480)
        defer {
            for url in copies + [good] { try? FileManager.default.removeItem(at: url) }
        }
        let pack = OnePadPack(chains: [copies.map { Sound(file: $0, loop: 0) } + [Sound(file: good, loop: 0)]])
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(pack, packBudget: .init(limit: limit))
        defer { engine.destroy() }
        #expect(listener.failure == nil)

        // The third is refused; that pad still advances to the final playable WAV.
        for expected in [1, 2, 2, 3] {
            engine.soundOn(x: 0, y: 0)
            #expect(engine.playsStarted == expected)
        }
    }

    @Test(arguments: [UInt32(44_100), 48_000])
    func aPlainWavPlays(sampleRate: UInt32) async throws {
        try await expectPlays(try SoundEngineTestSupport.writeWav(sampleRate: sampleRate, frames: sampleRate / 10), requiresSignal: false)
    }

    /// M4A (AAC) sounds are used by real packs although the format guide does not list them.
    @Test func anM4ASoundPlays() async throws {
        try await expectPlays(try fixture("aac-tone", "m4a"))
    }

    /// Two official packs ship MP3 data in files named `.wav`; the content decides how it is decoded.
    @Test func mp3DataInAFileNamedWavPlays() async throws {
        try await expectPlays(try fixture("mp3-tone-named-wav", "wav"))
    }

    /// The format guide recommends Ogg Vorbis, which AVAudioFile cannot open.
    @Test func anOggVorbisSoundPlays() async throws {
        try await expectPlays(try fixture("vorbis-tone", "ogg"))
    }

    @Test func anOggOpusSoundPlays() async throws {
        try await expectPlays(try fixture("opus-tone", "ogg"), recordMix: true)
    }

    @Test(arguments: ["vorbis-overlong", "vorbis-over-budget", "opus-overlong"])
    func anOversizedOggIsSilentAndAdvancesToTheNextSound(_ name: String) async throws {
        let good = try SoundEngineTestSupport.writeSilentSound()
        let pack = OnePadPack(chains: [[
            Sound(file: try fixture(name, "ogg"), loop: 0),
            Sound(file: good, loop: 0),
        ]])
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(pack)
        defer { engine.destroy() }
        #expect(listener.failure == nil)
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 0)
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 1)
    }

    /// A damaged Ogg Vorbis file is silent where it stands, like any sound that cannot be decoded,
    /// and the pad's next press plays its next sound.
    @Test(arguments: OggDamage.allCases)
    func aDamagedOggSoundStillAdvancesThePadToItsNextSound(_ damage: OggDamage) async throws {
        let good = try SoundEngineTestSupport.writeSilentSound()
        let damaged = try damage.write(from: try fixture("vorbis-tone", "ogg"))
        let pack = OnePadPack(chains: [[Sound(file: damaged, loop: 0), Sound(file: good, loop: 0)]])
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(pack)
        defer { engine.destroy() }
        #expect(listener.failure == nil)

        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 0)
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 1)
    }

    private func expectPlays(_ file: URL, requiresSignal: Bool = true, recordMix: Bool = false) async throws {
        let pack: OnePadPack
        if recordMix {
            // Keep the pre-fix mixer running so an unsupported sound records silence.
            let silence = try SoundEngineTestSupport.writeSilentSound()
            pack = OnePadPack(chains: [[Sound(file: file, loop: 0), Sound(file: silence, loop: 0)]])
        } else {
            pack = OnePadPack(soundFile: file)
        }
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(pack)
        defer { engine.destroy() }
        #expect(listener.failure == nil, "\(file.lastPathComponent) could not be decoded: \(String(describing: listener.failure))")
        guard requiresSignal else {
            engine.soundOn(x: 0, y: 0)
            #expect(engine.playsStarted == 1)
            return
        }
        // Inspect the existing engine only in tests, without adding a product audio hook. This
        // deliberately fails if that field changes: a missing observation is never a pass.
        let audio = try #require(Mirror(reflecting: engine).children.first { $0.label == "engine" }?.value as? AVAudioEngine)
        let output = RenderedAudio(capturesAudio: recordMix)
        await withCheckedContinuation { continuation in
            AudioSessionWorker.shared.run {
                audio.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                    output.record(buffer)
                }
            } then: { _ in continuation.resume() }
        }
        do {
            engine.soundOn(x: 0, y: 0)
            #expect(engine.playsStarted == 1)
            let deadline = Date().addingTimeInterval(5)
            while !output.hasSignal, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(output.hasSignal, "\(file.lastPathComponent): the real mixer never rendered nonzero PCM samples")
        } catch {
            await removeMixerTap(from: audio)
            throw error
        }
        if recordMix { try await Task.sleep(for: .milliseconds(600)) }
        await removeMixerTap(from: audio)
        if recordMix { try output.attachRecording() }
    }

    private func removeMixerTap(from audio: AVAudioEngine) async {
        await withCheckedContinuation { continuation in
            AudioSessionWorker.shared.run {
                audio.mainMixerNode.removeTap(onBus: 0)
            } then: { _ in continuation.resume() }
        }
    }
}

private final class RenderedAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var signal = false
    private let capturesAudio: Bool
    private var samples: [Float] = []
    private var sampleRate = 48_000.0
    init(capturesAudio: Bool = false) { self.capturesAudio = capturesAudio }

    func attachRecording() throws {
        lock.lock()
        let samples = samples
        let rate = sampleRate
        lock.unlock()
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let frames = max(1, samples.count / 2)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            pcm.floatChannelData![0][frame] = samples.isEmpty ? 0 : samples[frame * 2]
            pcm.floatChannelData![1][frame] = samples.isEmpty ? 0 : samples[frame * 2 + 1]
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "opus-mixer-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: pcm)
        Attachment.record(try Data(contentsOf: url), named: "opus-mixer.wav")
    }
    var hasSignal: Bool { lock.lock(); defer { lock.unlock() }; return signal }
    func record(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        var audible = false
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) where abs(channels[channel][frame]) > 0.0001 {
                audible = true
                break
            }
        }
        lock.lock()
        signal = signal || audible
        if capturesAudio {
            sampleRate = buffer.format.sampleRate
            let frames = min(Int(buffer.frameLength), max(0, Int(sampleRate) - samples.count / 2))
            for frame in 0..<frames {
                samples.append(channels[0][frame])
                samples.append(channels[min(1, Int(buffer.format.channelCount) - 1)][frame])
            }
        }
        lock.unlock()
    }
}

/// Ways an Ogg Vorbis file can be broken before its audio starts, so nothing in it can be played.
enum OggDamage: CaseIterable, CustomTestStringConvertible {
    case onlyTheCapturePattern
    case identificationHeaderOverwritten
    case cutInsideTheHeaders

    var testDescription: String { "\(self)" }

    func write(from fixture: URL) throws -> URL {
        var bytes = try Data(contentsOf: fixture)
        switch self {
        case .onlyTheCapturePattern:
            bytes = Data("OggS".utf8) + Data(repeating: 0xA5, count: 512)
        case .identificationHeaderOverwritten:
            // The "vorbis" signature and stream parameters follow the first page header (28 bytes).
            bytes.replaceSubrange(28..<58, with: Data(repeating: 0xFF, count: 30))
        case .cutInsideTheHeaders:
            bytes = bytes.prefix(100)
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OggDamage-\(self)-\(UUID().uuidString).ogg")
        try bytes.write(to: url)
        return url
    }
}
#endif
