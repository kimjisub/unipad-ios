import AVFoundation

/// What a pack's sound file may claim before it is decoded or resampled into memory. The sample
/// rate is a few header bytes anyone can edit: a three-second sound whose header says 20 Hz resampled into
/// gigabytes at the device rate, and a longer one overflowed the frame count and trapped.
nonisolated enum SoundFileLimits {
    /// Telephone-quality 8 kHz up to the 384 kHz of studio converters.
    static let sampleRates: ClosedRange<Double> = 8_000...384_000
    /// Longer than any backing track a pack ships; about 230 MB of stereo float samples at 48 kHz.
    static let longestSound: TimeInterval = 10 * 60

    /// Per decoded or converted float buffer. 256 MiB admits 10 minutes of 48 kHz stereo
    /// (230,400,000 bytes, plus the converter's spare frame), but refuses multi-GB allocations.
    static let maximumBufferBytes: UInt64 = 256 * 1_024 * 1_024

    enum Violation: Error, Equatable {
        case implausibleSampleRate(Double)
        case tooLong
        case invalidChannelCount
        case bufferTooLarge
    }

    /// Check the file's 64-bit length before converting it or allocating the decoded buffer.
    static func sourceFrameCount(_ frames: AVAudioFramePosition, sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFrameCount {
        let count = try validatedSourceLength(frames, sampleRate: sampleRate)
        try validateBufferSize(count, channels: channels)
        return count
    }

    private static func validatedSourceLength(_ frames: AVAudioFramePosition, sampleRate: Double) throws -> AVAudioFrameCount {
        guard sampleRates.contains(sampleRate) else {
            throw Violation.implausibleSampleRate(sampleRate)
        }
        guard let count = AVAudioFrameCount(exactly: frames), Double(frames) <= longestSound * sampleRate else {
            throw Violation.tooLong
        }
        return count
    }

    /// The frame capacity `frames` recorded at `sourceRate` need once resampled to `targetRate`.
    static func resampledFrameCount(_ frames: AVAudioFrameCount, from sourceRate: Double, to targetRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFrameCount {
        _ = try validatedSourceLength(AVAudioFramePosition(frames), sampleRate: sourceRate)
        let capacity = (Double(frames) * targetRate / sourceRate).rounded(.up) + 1
        guard capacity <= longestSound * targetRate + 1, let frameCount = AVAudioFrameCount(exactly: capacity) else {
            throw Violation.tooLong
        }
        try validateBufferSize(frameCount, channels: channels)
        return frameCount
    }

    private static func validateBufferSize(_ frames: AVAudioFrameCount, channels: AVAudioChannelCount) throws {
        guard channels > 0 else { throw Violation.invalidChannelCount }
        let bytesPerFrame = UInt64(channels) * UInt64(MemoryLayout<Float>.size)
        // Divide the budget first: multiplying untrusted frame and channel counts can overflow.
        guard UInt64(frames) <= maximumBufferBytes / bytesPerFrame else {
            throw Violation.bufferTooLarge
        }
    }
}
