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

    /// Starts a real engine on `pack` and waits until it has finished loading the sounds.
    static func loadedEngine(_ pack: UniPack, chain: ChainObserver? = nil) async throws -> (SoundEngine, TestSoundLoadListener) {
        let listener = TestSoundLoadListener()
        let engine = SoundEngine(unipack: pack, chain: chain ?? ChainObserver(), loadingListener: listener)

        // The loader runs on a utility queue and reports back on the main queue. Bounded wait.
        let deadline = Date().addingTimeInterval(20)
        while !listener.finished, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(listener.finished, "the pack did not finish loading within 20 s")
        return (engine, listener)
    }
}
#endif
