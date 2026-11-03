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
        guard try fits(frames, channels: channels, within: maximumBufferBytes) else {
            throw Violation.bufferTooLarge
        }
    }

    /// Whether `frames` of `channels` float samples take at most `bytes`.
    static func fits(_ frames: AVAudioFrameCount, channels: AVAudioChannelCount, within bytes: UInt64) throws -> Bool {
        guard channels > 0 else { throw Violation.invalidChannelCount }
        let bytesPerFrame = UInt64(channels) * UInt64(MemoryLayout<Float>.size)
        // Divide the budget first: multiplying untrusted frame and channel counts can overflow.
        return UInt64(frames) <= bytes / bytesPerFrame
    }
}

/// What became of the sound files a pack's keySound uses, counted once per file. A sound the rules
/// refuse, one that failed to decode after it was selected and one the device had no memory for are
/// told apart: only the first is the pack's own doing.
nonisolated struct SoundLoadReport: Equatable {
    enum Failure: CaseIterable, Equatable {
        /// Longer or larger than the shared limits allow.
        case tooLarge
        /// Not a format the inspector reads, damaged, or missing.
        case unreadable
        /// Selected, but the decoder could not turn it into samples.
        case undecodable
        /// Selected, but the device had no memory left for its samples.
        case outOfMemory

        init(_ exclusion: AudioAdmission.Exclusion) {
            switch exclusion {
            case .duration, .singleLimit, .packLimit: self = .tooLarge
            case .invalidFormat, .readFailure, .sampleRate, .channels: self = .unreadable
            }
        }
    }

    struct Entry: Equatable {
        let file: URL
        let failure: Failure
    }

    /// Distinct files the pack's keySound uses within its bounds.
    private(set) var usedFiles = 0
    private(set) var loadedFiles = 0
    private(set) var entries: [Entry] = []

    mutating func loaded() {
        usedFiles += 1
        loadedFiles += 1
    }

    mutating func failed(_ file: URL, _ failure: Failure) {
        usedFiles += 1
        entries.append(Entry(file: file, failure: failure))
    }

    func count(_ failure: Failure) -> Int {
        entries.count { $0.failure == failure }
    }

    /// The pack uses sounds and none of them can play. A pack without sounds plays its lights.
    var nothingPlays: Bool { usedFiles > 0 && loadedFiles == 0 }
}
