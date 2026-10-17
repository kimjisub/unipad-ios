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
