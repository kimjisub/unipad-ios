#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
@testable import unipad

/// What the Ogg Vorbis decoder gives for a good file, a file cut short and damaged bytes.
struct OggVorbisDecoderTests {
    /// 0.5 s of a 440 Hz tone at half scale, stereo, 44.1 kHz, encoded with libvorbis 1.3.7 with a
    /// new page every 8 packets, so the audio spans three pages after the headers.
    private func tone() throws -> URL {
        try #require(Bundle(for: OnePadPack.self).url(forResource: "vorbis-tone", withExtension: "ogg"))
    }

    private func write(_ bytes: Data, _ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OggVorbisDecoderTests-\(name)-\(UUID().uuidString).ogg")
        try bytes.write(to: url)
        return url
    }

    @Test func decodesTheWholeToneInTheFilesLayout() throws {
        let buffer = try OggVorbisDecoder.decode(try tone())

        #expect(buffer.format.sampleRate == 44_100)
        #expect(buffer.format.channelCount == 2)
        #expect(buffer.format.commonFormat == .pcmFormatFloat32)
        #expect(!buffer.format.isInterleaved)
        #expect(buffer.frameLength == 22_050)
        let left = try #require(buffer.floatChannelData?[0])
        let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(left[$1])) }
        #expect(abs(peak - 0.5) < 0.05, "peak \(peak): the tone did not come out as encoded")
    }

    @Test func recognisesOggByItsFirstBytesOnly() throws {
        #expect(OggVorbisDecoder.isOgg(try tone()))
        #expect(!OggVorbisDecoder.isOgg(try write(Data("RIFF....WAVE".utf8), "wav")))
        #expect(!OggVorbisDecoder.isOgg(try write(Data("Og".utf8), "short")))
    }

    /// A file cut in the middle of its last page gives the audio of the pages before it.
    @Test func aFileCutInItsAudioGivesTheAudioBeforeTheCut() throws {
        let bytes = try Data(contentsOf: try tone())
        let lastPage = try #require(bytes.range(of: Data("OggS".utf8), options: .backwards)).lowerBound
        let buffer = try OggVorbisDecoder.decode(try write(bytes.prefix(lastPage + 100), "cut"))

        #expect(buffer.format.channelCount == 2)
        #expect(buffer.frameLength > 0)
        #expect(buffer.frameLength < 22_050)
    }

    /// A 212-byte file whose setup header claims 2^23 entries for one codebook (the headers of
    /// Xiph.Org's test_codebook.c, then one audio packet). libvorbis 1.3.7 sized a stack buffer by
    /// that count and overflowed the loading thread's stack; the fix that allocates it on the heap
    /// turns the file into a decode error.
    @Test func aCodebookClaimingMillionsOfEntriesFailsWithoutCrashing() throws {
        let file = try #require(Bundle(for: OnePadPack.self)
            .url(forResource: "vorbis-oversized-codebook", withExtension: "ogg"))

        #expect(throws: OggVorbisDecoder.DecodeError.self) { try OggVorbisDecoder.decode(file) }
    }

    /// Pack files come from anyone. Damaged bytes anywhere may fail the decode or change the audio,
    /// but must never take the app down. Seeded, so a failure reproduces.
    @Test func damagedBytesNeverCrashTheDecoder() throws {
        let original = try Data(contentsOf: try tone())
        var random = SplitMix64(seed: 0x0FF5_EED0)
        for round in 0..<400 {
            var bytes = original
            for _ in 0..<(1 + Int(random.next() % 8)) {
                let at = Int(random.next() % UInt64(bytes.count))
                bytes[at] = UInt8(truncatingIfNeeded: random.next())
            }
            if round % 4 == 0 {
                bytes = bytes.prefix(Int(random.next() % UInt64(bytes.count)))
            }
            let url = try write(bytes, "damaged-\(round)")
            defer { try? FileManager.default.removeItem(at: url) }
            if let buffer = try? OggVorbisDecoder.decode(url) {
                #expect(buffer.frameLength > 0)
                #expect(buffer.format.channelCount > 0)
            }
        }
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
#endif
