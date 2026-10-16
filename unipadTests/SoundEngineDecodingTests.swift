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

    /// M4A (AAC) sounds are used by real packs although the format guide does not list them.
    @Test func anM4ASoundPlays() async throws {
        try await expectPlays(try fixture("aac-tone", "m4a"))
    }

    /// Two official packs ship MP3 data in files named `.wav`; the content decides how it is decoded.
    @Test func mp3DataInAFileNamedWavPlays() async throws {
        try await expectPlays(try fixture("mp3-tone-named-wav", "wav"))
    }

    private func expectPlays(_ file: URL) async throws {
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(OnePadPack(soundFile: file))
        defer { engine.destroy() }
        #expect(listener.failure == nil, "\(file.lastPathComponent) could not be decoded: \(String(describing: listener.failure))")
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 1)
    }
}
#endif
