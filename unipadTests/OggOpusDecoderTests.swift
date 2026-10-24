#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
@testable import unipad

@Suite(.serialized)
struct OggOpusDecoderTests {
    private func fixture(_ name: String = "opus-tone") throws -> URL {
        try #require(Bundle(for: OnePadPack.self).url(forResource: name, withExtension: "ogg"))
    }

    private func write(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "Opus-\(UUID().uuidString).ogg")
        try bytes.write(to: url)
        return url
    }

    @Test(arguments: ["opus-tone", "opus-mono", "opus-surround"])
    func decodesAndTrimsTheWholeTone(_ name: String) throws {
        let url = try fixture(name)
        let buffer = try OggAudioDecoder.decode(url)
        #expect(buffer.format.sampleRate == 48_000, "Opus output does not use the informational input rate")
        #expect(buffer.format.channelCount == 2)
        #expect(!buffer.format.isInterleaved)
        #expect(buffer.frameLength == 24_000, "encoder delay and final padding must be removed")
        #expect(buffer.frameCapacity == buffer.frameLength)
        for channel in 0..<2 {
            let pcm = try #require(buffer.floatChannelData?[channel])
            let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(pcm[$1])) }
            #expect(peak > 0.04)
        }
        let length = try OggAudioDecoder.length(of: url)
        #expect(length.frames == Int64(buffer.frameLength))
        #expect(length.format.sampleRate == 48_000)
    }

    @Test func chainedMonoAndStereoSoundsKeepOnePlaybackLayout() throws {
        let url = try write(Data(contentsOf: fixture()) + Data(contentsOf: fixture("opus-mono")))
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = try OggAudioDecoder.decode(url)
        #expect(buffer.frameLength == 48_000)
        #expect(buffer.format.channelCount == 2)
    }

    @Test func refusesOverlongAudioBeforeAllocatingPCM() throws {
        var allocated = false
        #expect(throws: SoundFileLimits.Violation.tooLong) {
            try OggOpusDecoder.decode(fixture("opus-overlong")) { _, _ in allocated = true }
        }
        #expect(!allocated)
    }

    @Test func checksThePackBudgetBeforeAllocatingPCM() throws {
        let budget = SoundFileLimits.PackBudget(limit: 1_024)
        var claimed: AVAudioFrameCount = 0
        #expect(throws: SoundFileLimits.Violation.packTooLarge) {
            try OggOpusDecoder.decode(fixture()) { format, frames in
                claimed = frames
                try budget.check(frames, channels: format.channelCount)
            }
        }
        #expect(claimed == 24_000)
    }

    @Test func damagedBytesAndTruncationNeverCrash() throws {
        let original = try Data(contentsOf: fixture())
        var state: UInt64 = 0x0F05_2026
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        for round in 0..<200 {
            var bytes = original
            for _ in 0..<(1 + Int(next() % 8)) {
                bytes[Int(next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: next())
            }
            // Repair complete pages after mutation so some damage reaches the codec, rather
            // than every changed packet being rejected only by the Ogg checksum.
            repairChecksums(&bytes)
            if round % 4 == 0 { bytes = bytes.prefix(Int(next() % UInt64(bytes.count))) }
            let url = try write(bytes)
            defer { try? FileManager.default.removeItem(at: url) }
            if let pcm = try? OggOpusDecoder.decode(url) {
                #expect(pcm.frameLength > 0)
                #expect(pcm.format.channelCount == 2)
            }
        }
    }
    private func repairChecksums(_ bytes: inout Data) {
        var offset = 0
        while offset + 27 <= bytes.count {
            guard bytes[offset..<offset + 4] == Data("OggS".utf8) else { return }
            let headerEnd = offset + 27 + Int(bytes[offset + 26])
            guard headerEnd <= bytes.count else { return }
            let end = headerEnd + bytes[offset + 27..<headerEnd].reduce(0) { $0 + Int($1) }
            guard end <= bytes.count else { return }
            bytes.replaceSubrange(offset + 22..<offset + 26, with: [UInt8](repeating: 0, count: 4))
            var crc: UInt32 = 0
            for byte in bytes[offset..<end] {
                crc ^= UInt32(byte) << 24
                for _ in 0..<8 { crc = (crc &<< 1) ^ (crc & 0x8000_0000 == 0 ? 0 : 0x04C1_1DB7) }
            }
            for index in 0..<4 { bytes[offset + 22 + index] = UInt8(truncatingIfNeeded: crc >> (index * 8)) }
            offset = end
        }
    }
}
#endif
