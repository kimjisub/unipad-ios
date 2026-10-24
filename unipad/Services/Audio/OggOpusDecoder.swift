import AVFoundation
import COpusFile

/// libopusfile applies the Opus pre-skip, final trim and header gain. Its stereo reader also
/// downmixes multichannel streams and keeps one output layout across chained links.
nonisolated enum OggOpusDecoder {
    enum DecodeError: Error {
        case unreadable(Int32)
        case noAudio
    }

    private static let sampleRate = 48_000.0
    private static let readFrames = 5_760

    static func length(of url: URL) throws -> (frames: AVAudioFramePosition, format: AVAudioFormat) {
        try withOpenFile(url) { file, format in
            let frames = op_pcm_total(file, -1)
            guard frames >= 0 else { throw DecodeError.unreadable(Int32(truncatingIfNeeded: frames)) }
            return (frames, format)
        }
    }

    static func decode(
        _ url: URL,
        admitting admit: (AVAudioFormat, AVAudioFrameCount) throws -> Void = { _, _ in }
    ) throws -> AVAudioPCMBuffer {
        try withOpenFile(url) { file, format in
            let declaredFrames = op_pcm_total(file, -1)
            guard declaredFrames >= 0 else { throw DecodeError.unreadable(Int32(truncatingIfNeeded: declaredFrames)) }
            let initialCapacity = try SoundFileLimits.sourceFrameCount(max(declaredFrames, 1),
                sampleRate: sampleRate, channels: 2)
            try admit(format, initialCapacity)
            guard var buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: initialCapacity) else {
                throw DecodeError.noAudio
            }
            let maximumCapacity = min(Int(SoundFileLimits.longestSound * sampleRate),
                Int(SoundFileLimits.maximumBufferBytes / (2 * UInt64(MemoryLayout<Float>.size))))
            var interleaved = [Float](repeating: 0, count: readFrames * 2)
            var frameCount = 0
            while true {
                let frames = op_read_float_stereo(file, &interleaved, Int32(interleaved.count))
                if frames == OP_HOLE { continue }
                if frames < 0 { throw DecodeError.unreadable(frames) }
                if frames == 0 { break }
                let needed = try SoundFileLimits.sourceFrameCount(AVAudioFramePosition(frameCount) + Int64(frames),
                    sampleRate: sampleRate, channels: 2)
                if needed > buffer.frameCapacity {
                    let capacity = AVAudioFrameCount(min(maximumCapacity, max(Int(needed), Int(buffer.frameCapacity) * 2)))
                    try admit(format, capacity)
                    guard let grown = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
                          let destination = grown.floatChannelData, let source = buffer.floatChannelData else {
                        throw DecodeError.noAudio
                    }
                    for channel in 0..<2 {
                        destination[channel].update(from: source[channel], count: frameCount)
                    }
                    buffer = grown
                }
                guard let channels = buffer.floatChannelData else { throw DecodeError.noAudio }
                for frame in 0..<Int(frames) {
                    channels[0][frameCount + frame] = interleaved[frame * 2]
                    channels[1][frameCount + frame] = interleaved[frame * 2 + 1]
                }
                frameCount = Int(needed)
            }
            guard frameCount > 0 else { throw DecodeError.noAudio }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            return buffer
        }
    }

    private static func withOpenFile<T>(
        _ url: URL,
        _ body: (OpaquePointer, AVAudioFormat) throws -> T
    ) throws -> T {
        var error: Int32 = 0
        let file = url.withUnsafeFileSystemRepresentation { path in
            path.flatMap { op_open_file($0, &error) }
        }
        guard let file else { throw DecodeError.unreadable(error) }
        defer { op_free(file) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw DecodeError.noAudio
        }
        return try body(file, format)
    }
}
