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

    /// Every decoded sound of one pack together. Silence compresses to almost nothing: a 10-minute
    /// sound of a few hundred KB passes the limits above and decodes to about 230 MB, so without
    /// this limit a pack of a few such files would take gigabytes. Measured on 1,512 real packs (the sounds their keySound uses, at 48 kHz
    /// stereo float): median 52 MB, largest 168 MB. Some MP3s cut from a whole song still claim the
    /// song's length, and a sound is checked against what its header claims before it is decoded;
    /// counted that way the largest pack needs 334 MB. 512 MiB admits it with headroom and refuses
    /// the third 10-minute sound.
    static let maximumPackBytes: UInt64 = 512 * 1_024 * 1_024

    enum Violation: Error, Equatable {
        case implausibleSampleRate(Double)
        case tooLong
        case invalidChannelCount
        case bufferTooLarge
        case packTooLarge
    }

    /// The bytes a pack's decoded sounds already hold, so the next one can be refused before it is
    /// allocated.
    struct PackBudget {
        let limit: UInt64
        private(set) var spentBytes: UInt64 = 0

        init(limit: UInt64 = SoundFileLimits.maximumPackBytes) {
            self.limit = limit
        }

        func check(_ frames: AVAudioFrameCount, channels: AVAudioChannelCount) throws {
            guard try SoundFileLimits.fits(frames, channels: channels, within: limit - spentBytes) else {
                throw Violation.packTooLarge
            }
        }

        mutating func spend(_ frames: AVAudioFrameCount, channels: AVAudioChannelCount) throws {
            try check(frames, channels: channels)
            spentBytes += UInt64(frames) * UInt64(channels) * UInt64(MemoryLayout<Float>.size)
        }
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
        guard try fits(frames, channels: channels, within: maximumBufferBytes) else {
            throw Violation.bufferTooLarge
        }
    }

    /// Whether `frames` of `channels` float samples take at most `bytes`.
    private static func fits(_ frames: AVAudioFrameCount, channels: AVAudioChannelCount, within bytes: UInt64) throws -> Bool {
        guard channels > 0 else { throw Violation.invalidChannelCount }
        let bytesPerFrame = UInt64(channels) * UInt64(MemoryLayout<Float>.size)
        // Divide the budget first: multiplying untrusted frame and channel counts can overflow.
        return UInt64(frames) <= bytes / bytesPerFrame
    }
}
