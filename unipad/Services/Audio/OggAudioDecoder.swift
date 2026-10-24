import AVFoundation

/// The Ogg fallback for systems whose native file reader cannot open these sounds. Only a file
/// Vorbis cannot open is tried as Opus; resource limits and later Vorbis errors keep their meaning.
nonisolated enum OggAudioDecoder {
    static func decode(
        _ url: URL,
        admitting admit: (AVAudioFormat, AVAudioFrameCount) throws -> Void = { _, _ in }
    ) throws -> AVAudioPCMBuffer {
        do {
            return try OggVorbisDecoder.decode(url, admitting: admit)
        } catch OggVorbisDecoder.DecodeError.unreadable {
            return try OggOpusDecoder.decode(url, admitting: admit)
        }
    }

    static func length(of url: URL) throws -> (frames: AVAudioFramePosition, format: AVAudioFormat) {
        do {
            return try OggVorbisDecoder.length(of: url)
        } catch OggVorbisDecoder.DecodeError.unreadable {
            return try OggOpusDecoder.length(of: url)
        }
    }
}
