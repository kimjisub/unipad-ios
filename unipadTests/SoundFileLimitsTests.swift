import AVFoundation
import Testing
@testable import unipad

struct SoundFileLimitsTests {
    @Test(arguments: [AVAudioChannelCount(2), 8])
    func aHighRateSourceCannotAllocateGigabytes(channels: AVAudioChannelCount) {
        #expect(throws: SoundFileLimits.Violation.bufferTooLarge) {
            try SoundFileLimits.sourceFrameCount(384_000 * 600, sampleRate: 384_000, channels: channels)
        }
    }

    @Test(arguments: [AVAudioChannelCount(2), 8])
    func resamplingCannotAllocateGigabytes(channels: AVAudioChannelCount) {
        #expect(throws: SoundFileLimits.Violation.bufferTooLarge) {
            try SoundFileLimits.resampledFrameCount(8_000 * 600, from: 8_000, to: 384_000, channels: channels)
        }
    }

    @Test(arguments: [44_100.0, 48_000])
    func tenMinuteStereoSoundsStillFit(sampleRate: Double) throws {
        let frames = AVAudioFramePosition(sampleRate * 600)
        #expect(try SoundFileLimits.sourceFrameCount(frames, sampleRate: sampleRate, channels: 2) == AVAudioFrameCount(frames))
        #expect(try SoundFileLimits.resampledFrameCount(AVAudioFrameCount(frames), from: sampleRate, to: 48_000, channels: 2) == 28_800_001)
    }

    @Test(arguments: [AVAudioChannelCount(1), 2, 8])
    func theByteBoundaryIncludesAllChannelsAndTheConverterSpareFrame(channels: AVAudioChannelCount) throws {
        let frames = AVAudioFrameCount(SoundFileLimits.maximumBufferBytes / (UInt64(channels) * 4))
        #expect(try SoundFileLimits.sourceFrameCount(AVAudioFramePosition(frames), sampleRate: 384_000, channels: channels) == frames)
        #expect(throws: SoundFileLimits.Violation.bufferTooLarge) {
            try SoundFileLimits.sourceFrameCount(AVAudioFramePosition(frames) + 1, sampleRate: 384_000, channels: channels)
        }
        #expect(try SoundFileLimits.resampledFrameCount(frames - 1, from: 384_000, to: 384_000, channels: channels) == frames)
        #expect(throws: SoundFileLimits.Violation.bufferTooLarge) {
            try SoundFileLimits.resampledFrameCount(frames, from: 384_000, to: 384_000, channels: channels)
        }
    }

    @Test func extremeChannelCountsCannotOverflowTheByteCalculation() {
        #expect(throws: SoundFileLimits.Violation.bufferTooLarge) {
            try SoundFileLimits.sourceFrameCount(230_400_000, sampleRate: 384_000, channels: .max)
        }
        #expect(throws: SoundFileLimits.Violation.bufferTooLarge) {
            try SoundFileLimits.resampledFrameCount(4_800_000, from: 8_000, to: 384_000, channels: .max)
        }
        #expect(throws: SoundFileLimits.Violation.invalidChannelCount) {
            try SoundFileLimits.sourceFrameCount(0, sampleRate: 48_000, channels: 0)
        }
        #expect(throws: SoundFileLimits.Violation.invalidChannelCount) {
            try SoundFileLimits.resampledFrameCount(0, from: 48_000, to: 48_000, channels: 0)
        }
    }

    @Test func resamplingUsesTheOutputChannelsAndRateForItsByteBudget() throws {
        // The output fits after downsampling, regardless of the input's frame count.
        #expect(try SoundFileLimits.resampledFrameCount(230_400_000, from: 384_000, to: 48_000, channels: 2) == 28_800_001)
        // The input fits as mono; expanding it to eight output channels does not.
        #expect(throws: SoundFileLimits.Violation.bufferTooLarge) {
            try SoundFileLimits.resampledFrameCount(28_800_000, from: 48_000, to: 48_000, channels: 8)
        }
    }

    @Test(arguments: [0.0, 12, 20, 50, 7_999, 384_001, 4_000_000_000])
    func anImplausibleSampleRateIsRefused(sampleRate: Double) {
        #expect(throws: SoundFileLimits.Violation.implausibleSampleRate(sampleRate)) {
            try SoundFileLimits.resampledFrameCount(132_300, from: sampleRate, to: 48_000, channels: 1)
        }
    }

    @Test(arguments: [8_000.0, 44_100, 48_000])
    func sourceLengthAcceptsTheBoundaryAndRejectsTheNextFrame(sampleRate: Double) throws {
        let frames = AVAudioFramePosition(SoundFileLimits.longestSound * sampleRate)
        #expect(try SoundFileLimits.sourceFrameCount(0, sampleRate: sampleRate, channels: 1) == 0)
        #expect(try SoundFileLimits.sourceFrameCount(frames, sampleRate: sampleRate, channels: 1) == AVAudioFrameCount(frames))
        #expect(throws: SoundFileLimits.Violation.tooLong) {
            try SoundFileLimits.sourceFrameCount(frames + 1, sampleRate: sampleRate, channels: 1)
        }
    }

    @Test(arguments: [AVAudioFramePosition(-1), .min, AVAudioFramePosition(UInt32.max), AVAudioFramePosition(UInt32.max) + 1, .max])
    func anInvalidOrOversizedSourceCountIsRefused(frames: AVAudioFramePosition) {
        #expect(throws: SoundFileLimits.Violation.tooLong) {
            try SoundFileLimits.sourceFrameCount(frames, sampleRate: 48_000, channels: 1)
        }
    }

    @Test(arguments: [0.0, 20, 7_999, 384_001, .infinity, -.infinity])
    func sourceLengthRefusesAnImplausibleSampleRate(sampleRate: Double) {
        #expect(throws: SoundFileLimits.Violation.implausibleSampleRate(sampleRate)) {
            try SoundFileLimits.sourceFrameCount(800, sampleRate: sampleRate, channels: 1)
        }
    }

    @Test func sourceLengthRefusesANotANumberSampleRate() {
        do {
            _ = try SoundFileLimits.sourceFrameCount(800, sampleRate: .nan, channels: 1)
            Issue.record("a NaN sample rate was accepted")
        } catch SoundFileLimits.Violation.implausibleSampleRate(let rate) {
            #expect(rate.isNaN)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func resamplingKeepsTheDuration() throws {
        #expect(try SoundFileLimits.resampledFrameCount(44_100, from: 44_100, to: 48_000, channels: 1) == 48_001)
        #expect(try SoundFileLimits.resampledFrameCount(48_000, from: 48_000, to: 44_100, channels: 1) == 44_101)
        #expect(try SoundFileLimits.resampledFrameCount(0, from: 8_000, to: 48_000, channels: 1) == 1)
    }

    @Test func theLongestSoundStillFits() throws {
        let frames = AVAudioFrameCount(SoundFileLimits.longestSound * 8_000)
        #expect(try SoundFileLimits.resampledFrameCount(frames, from: 8_000, to: 48_000, channels: 1)
            == AVAudioFrameCount(SoundFileLimits.longestSound * 48_000) + 1)
    }

    /// The largest frame count a file can hold resampled six times up overflowed the 32-bit
    /// capacity and trapped before any memory was taken.
    @Test(arguments: [AVAudioFrameCount(SoundFileLimits.longestSound * 8_000) + 1, .max])
    func aSoundLongerThanTheLimitIsRefused(frames: AVAudioFrameCount) {
        #expect(throws: SoundFileLimits.Violation.tooLong) {
            try SoundFileLimits.resampledFrameCount(frames, from: 8_000, to: 48_000, channels: 1)
        }
    }
}
