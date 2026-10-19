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

    private func expectPlays(_ file: URL, requiresSignal: Bool = true) async throws {
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(OnePadPack(soundFile: file))
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
        let output = RenderedAudio()
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
        await removeMixerTap(from: audio)
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
        lock.unlock()
    }
}
#endif
