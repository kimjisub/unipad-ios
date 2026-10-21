#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
@testable import unipad

@MainActor
struct SoundSourceLengthTests {
    @Test func aWavHeaderCannotInventFramesBeyondTheFile() throws {
        let url = try SoundEngineTestSupport.writeWav(sampleRate: 8_000, frames: 800, declaredFrames: .max)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 800)
        #expect(try SoundEngine.loadAudioBuffer(from: url).frameLength == 800)
    }

    @Test func aRealSoundOverTenMinutesIsRejectedBeforeDecoding() throws {
        let frames: UInt32 = 8_000 * 601
        let url = try SoundEngineTestSupport.writeWav(sampleRate: 8_000, frames: frames)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == AVAudioFramePosition(frames))
        #expect(throws: SoundFileLimits.Violation.tooLong) {
            try SoundEngine.loadAudioBuffer(from: url)
        }
    }

    @Test func aTenMinuteSoundStillDecodes() throws {
        let url = try SoundEngineTestSupport.writeWav(sampleRate: 8_000, frames: 8_000 * 600)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try SoundEngine.loadAudioBuffer(from: url).frameLength == 8_000 * 600)
    }

    @Test func anImplausibleRateIsRejectedBeforeDecoding() throws {
        let url = try SoundEngineTestSupport.writeWav(sampleRate: 20, frames: 800)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: SoundFileLimits.Violation.implausibleSampleRate(20)) {
            try SoundEngine.loadAudioBuffer(from: url)
        }
    }

    @Test(arguments: [UInt16(2), 8])
    func anOversizedDecodedBufferIsRejectedBeforeReadingSamples(channels: UInt16) throws {
        let frames = UInt32(SoundFileLimits.maximumBufferBytes / (UInt64(channels) * 4)) + 1
        let url = try SoundEngineTestSupport.writeWav(sampleRate: 384_000, frames: frames, channels: channels)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == AVAudioFramePosition(frames))
        #expect(file.processingFormat.channelCount == AVAudioChannelCount(channels))
        #expect(throws: SoundFileLimits.Violation.bufferTooLarge) {
            try SoundEngine.loadAudioBuffer(from: url)
        }
    }

    /// MP3s cut from a song can keep the song's length in their header: the buffer was sized by the
    /// claim and kept at that size behind the few frames the file holds.
    @Test func anMP3ClaimingMinutesKeepsOnlyTheFramesItHolds() throws {
        let url = try SoundEngineTestSupport.writeMP3(claimingPackets: 20_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 20_000_000, "the header's length was not believed; nothing to fit")
        let buffer = try SoundEngine.loadAudioBuffer(from: url)
        #expect(buffer.frameLength > 0)
        #expect(buffer.frameLength < 20_000)
        #expect(buffer.frameCapacity == buffer.frameLength)
    }

    /// An Ogg file's last page states its length; one stating nine minutes over half a second of
    /// tone kept a buffer of nine minutes.
    @Test func anOggClaimingMinutesKeepsOnlyTheFramesItHolds() throws {
        let tone = try #require(Bundle(for: OnePadPack.self).url(forResource: "vorbis-tone", withExtension: "ogg"))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "SoundSourceLengthTests-\(UUID().uuidString).ogg")
        try oggWithFinalGranule(44_100 * 540, at: tone).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = try SoundEngine.loadAudioBuffer(from: url)
        // The forged granule no longer trims the encoder's padding from the last block.
        #expect((22_050..<23_000).contains(buffer.frameLength))
        #expect(buffer.frameCapacity == buffer.frameLength)
    }

    /// An Ogg file can declare one frame and hold ten minutes. Each larger buffer it needs is checked
    /// against the pack's limit before it is allocated, so it is refused while still small instead
    /// of after decoding all ten minutes.
    @Test func anOggHoldingMoreThanItDeclaresIsRefusedAsItsBufferGrows() throws {
        let fixture = try #require(Bundle(for: OnePadPack.self).url(forResource: "vorbis-at-limit", withExtension: "ogg"))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "SoundSourceLengthTests-\(UUID().uuidString).ogg")
        try oggWithFinalGranule(1, at: fixture).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        // What a pack that has spent all but 8 MiB of its limit has left.
        let budget = SoundFileLimits.PackBudget(limit: 8 * 1_024 * 1_024)
        var admitted: [AVAudioFrameCount] = []
        #expect(throws: SoundFileLimits.Violation.packTooLarge) {
            try SoundEngine.loadAudioBuffer(from: url) { format, frames in
                try budget.check(frames, channels: format.channelCount)
                admitted.append(frames)
            }
        }
        #expect(admitted.count > 1, "the buffer grew without being checked")
        #expect(admitted.allSatisfy { UInt64($0) * 2 * 4 <= budget.limit })
    }

    /// The pack's limit is applied to what the header claims, before the decoded buffer exists.
    @Test(arguments: [("vorbis-at-limit", "ogg"), ("mp3-tone-named-wav", "wav")])
    func theClaimIsCheckedBeforeDecoding(_ name: String, _ ext: String) throws {
        let url = try #require(Bundle(for: OnePadPack.self).url(forResource: name, withExtension: ext))
        var claimed: AVAudioFrameCount?
        #expect(throws: SoundFileLimits.Violation.packTooLarge) {
            try SoundEngine.loadAudioBuffer(from: url) { _, frames in
                claimed = frames
                throw SoundFileLimits.Violation.packTooLarge
            }
        }
        #expect((claimed ?? 0) > 0)
    }

    @Test func anOrdinarySoundStillDecodes() throws {
        let url = try SoundEngineTestSupport.writeWav(sampleRate: 48_000, frames: 4_800)
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = try SoundEngine.loadAudioBuffer(from: url)
        #expect(buffer.frameLength == 4_800)
        #expect(buffer.format.sampleRate == 48_000)
    }
}
#endif
