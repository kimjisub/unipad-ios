import AVFoundation

/// Native MP4 readers may open Opus tracks yet refuse their packets. Only an inspected Opus
/// sample entry with dOps can use this fallback; other native failures keep their original error.
nonisolated enum Mp4OpusDecoder {
    static func decodeIfSupported(
        _ url: URL, holding reservation: AudioAdmission.Facts?,
        availableMemory: () -> Int?,
        admitting admit: (AVAudioFormat, AVAudioFrameCount) throws -> Void
    ) throws -> AVAudioPCMBuffer? {
        guard let bytes = try? Data(contentsOf: url, options: .alwaysMapped),
              let facts = try? Mp4AudioInspection.opusFacts(AudioRead(bytes)) else { return nil }
        let inspectedMaximum = try SoundFileLimits.sourceFrameCount(
            AVAudioFramePosition(facts.frames), sampleRate: 48_000, channels: 2)
        let maximum = try reservation.map {
            try min(inspectedMaximum, SoundFileLimits.sourceFrameCount(
                AVAudioFramePosition($0.frames), sampleRate: 48_000, channels: 2))
        } ?? inspectedMaximum
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw OggOpusDecoder.DecodeError.noAudio
        }
        try admit(format, maximum)
        // Include the temporary envelope and Data growth, not just the final PCM buffers.
        // There are at most frames / 120 packets; the file size also bounds all lacing bytes.
        let envelope = try AudioRead.add(AudioRead.add(bytes.count, bytes.count / 64),
                                        AudioRead.multiply(facts.frames / 120 + 3, 30))
        let temporary = try AudioRead.add(AudioRead.multiply(envelope, 4),
                                         AudioRead.multiply(Int(maximum), 16))
        if let available = availableMemory(), available - SoundEngine.memoryHeadroom < temporary {
            throw SoundEngine.SoundEngineError.outOfMemory
        }
        guard let stream = try? Mp4AudioInspection.opusOgg(AudioRead(bytes)) else { return nil }
        return try OggOpusDecoder.decode(stream.data, maximumFrames: maximum, admitting: admit)
    }
}
