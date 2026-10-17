#if canImport(UIKit)
import Foundation
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

    @Test(arguments: [UInt32(44_100), 48_000])
    func aPlainWavPlays(sampleRate: UInt32) async throws {
        try await expectPlays(try SoundEngineTestSupport.writeWav(sampleRate: sampleRate, frames: sampleRate / 10))
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

    private func expectPlays(_ file: URL) async throws {
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(OnePadPack(soundFile: file))
        defer { engine.destroy() }
        #expect(listener.failure == nil, "\(file.lastPathComponent) could not be decoded: \(String(describing: listener.failure))")
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 1)
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
