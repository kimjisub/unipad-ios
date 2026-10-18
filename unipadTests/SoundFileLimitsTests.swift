import AVFoundation
import Testing
@testable import unipad

struct SoundFileLimitsTests {
    @Test(arguments: [0.0, 12, 20, 50, 7_999, 384_001, 4_000_000_000])
    func anImplausibleSampleRateIsRefused(sampleRate: Double) {
        #expect(throws: SoundFileLimits.Violation.implausibleSampleRate(sampleRate)) {
            try SoundFileLimits.resampledFrameCount(132_300, from: sampleRate, to: 48_000)
        }
    }

    @Test(arguments: [8_000.0, 44_100, 48_000, 384_000])
    func sourceLengthAcceptsTheBoundaryAndRejectsTheNextFrame(sampleRate: Double) throws {
        let frames = AVAudioFramePosition(SoundFileLimits.longestSound * sampleRate)
        #expect(try SoundFileLimits.sourceFrameCount(0, sampleRate: sampleRate) == 0)
        #expect(try SoundFileLimits.sourceFrameCount(frames, sampleRate: sampleRate) == AVAudioFrameCount(frames))
        #expect(throws: SoundFileLimits.Violation.tooLong) {
            try SoundFileLimits.sourceFrameCount(frames + 1, sampleRate: sampleRate)
        }
    }

    @Test(arguments: [AVAudioFramePosition(-1), .min, AVAudioFramePosition(UInt32.max), AVAudioFramePosition(UInt32.max) + 1, .max])
    func anInvalidOrOversizedSourceCountIsRefused(frames: AVAudioFramePosition) {
        #expect(throws: SoundFileLimits.Violation.tooLong) {
            try SoundFileLimits.sourceFrameCount(frames, sampleRate: 48_000)
        }
    }

    @Test(arguments: [0.0, 20, 7_999, 384_001, .infinity, -.infinity])
    func sourceLengthRefusesAnImplausibleSampleRate(sampleRate: Double) {
        #expect(throws: SoundFileLimits.Violation.implausibleSampleRate(sampleRate)) {
            try SoundFileLimits.sourceFrameCount(800, sampleRate: sampleRate)
        }
    }

    @Test func sourceLengthRefusesANotANumberSampleRate() {
        do {
            _ = try SoundFileLimits.sourceFrameCount(800, sampleRate: .nan)
            Issue.record("a NaN sample rate was accepted")
        } catch SoundFileLimits.Violation.implausibleSampleRate(let rate) {
            #expect(rate.isNaN)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func resamplingKeepsTheDuration() throws {
        #expect(try SoundFileLimits.resampledFrameCount(44_100, from: 44_100, to: 48_000) == 48_001)
        #expect(try SoundFileLimits.resampledFrameCount(48_000, from: 48_000, to: 44_100) == 44_101)
        #expect(try SoundFileLimits.resampledFrameCount(0, from: 8_000, to: 48_000) == 1)
    }

    @Test func theLongestSoundStillFits() throws {
        let frames = AVAudioFrameCount(SoundFileLimits.longestSound * 8_000)
        #expect(try SoundFileLimits.resampledFrameCount(frames, from: 8_000, to: 48_000)
            == AVAudioFrameCount(SoundFileLimits.longestSound * 48_000) + 1)
    }

    /// The largest frame count a file can hold resampled six times up overflowed the 32-bit
    /// capacity and trapped before any memory was taken.
    @Test(arguments: [AVAudioFrameCount(SoundFileLimits.longestSound * 8_000) + 1, .max])
    func aSoundLongerThanTheLimitIsRefused(frames: AVAudioFrameCount) {
        #expect(throws: SoundFileLimits.Violation.tooLong) {
            try SoundFileLimits.resampledFrameCount(frames, from: 8_000, to: 48_000)
        }
    }
}
