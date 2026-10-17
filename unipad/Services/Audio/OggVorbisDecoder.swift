import AVFoundation
import CVorbis

/// Decodes Ogg Vorbis sounds, which `AVAudioFile` cannot open although the UniPack format
/// recommends them, with the Xiph.Org reference decoder.
enum OggVorbisDecoder {
    enum DecodeError: Error {
        /// `ov_fopen` refused the file (an `OV_*` code): not Vorbis, or its headers are damaged.
        case unreadable(Int32)
        /// No channel count or rate, or more than two channels without a channel layout.
        case unsupportedLayout
        case noAudio
    }

    private static let readFrames: Int32 = 4_096

    /// Ogg files of any codec start with the capture pattern "OggS".
    static func isOgg(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("OggS".utf8)
    }

    /// The whole sound as deinterleaved Float32, the layout `AVAudioFile.processingFormat` gives.
    /// A damaged page inside the audio is skipped; a file cut short plays up to the cut.
    static func decode(_ url: URL) throws -> AVAudioPCMBuffer {
        var file = OggVorbis_File()
        let opened = url.withUnsafeFileSystemRepresentation { path in
            path.map { ov_fopen($0, &file) } ?? OV_EFAULT
        }
        guard opened == 0 else { throw DecodeError.unreadable(opened) }
        defer { ov_clear(&file) }

        guard let info = ov_info(&file, -1)?.pointee, info.channels > 0, info.rate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(info.rate),
                                         channels: AVAudioChannelCount(info.channels)) else {
            throw DecodeError.unsupportedLayout
        }
        let channelCount = Int(format.channelCount)

        var samples = [[Float]](repeating: [], count: channelCount)
        var link: Int32 = 0
        while true {
            var pcm: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
            let frames = ov_read_float(&file, &pcm, readFrames, &link)
            if frames == Int(OV_HOLE) { continue }
            guard frames > 0, let pcm else { break }
            // A chained file may switch layout at a link; the buffer holds one layout only.
            guard let linkInfo = ov_info(&file, link)?.pointee,
                  linkInfo.channels == info.channels, linkInfo.rate == info.rate else { break }
            for channel in 0..<channelCount {
                samples[channel].append(contentsOf: UnsafeBufferPointer(start: pcm[channel], count: frames))
            }
        }

        guard let frameCount = AVAudioFrameCount(exactly: samples[0].count), frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else {
            throw DecodeError.noAudio
        }
        for channel in 0..<channelCount {
            samples[channel].withUnsafeBufferPointer { source in
                channels[channel].update(from: source.baseAddress!, count: source.count)
            }
        }
        buffer.frameLength = frameCount
        return buffer
    }
}
