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

    @Test func anOrdinarySoundStillDecodes() throws {
        let url = try SoundEngineTestSupport.writeWav(sampleRate: 48_000, frames: 4_800)
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = try SoundEngine.loadAudioBuffer(from: url)
        #expect(buffer.frameLength == 4_800)
        #expect(buffer.format.sampleRate == 48_000)
    }
}
#endif
