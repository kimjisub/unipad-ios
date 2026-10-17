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

    /// A 16-bit mono PCM WAV of `frames` silent frames whose header claims `sampleRate`, written
    /// byte by byte so the header can say what no encoder would write.
    static func writeWav(sampleRate: UInt32, frames: UInt32) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "SoundEngineTestSupport-\(UUID().uuidString).wav")
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let dataSize = frames * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)) // PCM, mono
        append(sampleRate); append(sampleRate * 2) // byte rate
        append(UInt16(2)); append(UInt16(16)) // block align, bits per sample
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        data.append(Data(count: Int(dataSize)))
        try data.write(to: url)
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
