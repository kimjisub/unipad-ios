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
    /// A damaged page inside the audio is skipped; a file cut short plays up to the cut. `admit` sees
    /// the length the file declares before the buffer is allocated.
    static func decode(
        _ url: URL,
        admitting admit: (AVAudioFormat, AVAudioFrameCount) throws -> Void = { _, _ in }
    ) throws -> AVAudioPCMBuffer {
        // libvorbis keeps pointers into this structure between calls, so its address must stay
        // stable for the entire decode (a Swift inout address is only valid for one call).
        let file = UnsafeMutablePointer<OggVorbis_File>.allocate(capacity: 1)
        file.initialize(to: OggVorbis_File())
        defer { file.deinitialize(count: 1); file.deallocate() }
        let opened = url.withUnsafeFileSystemRepresentation { path in
            path.map { ov_fopen($0, file) } ?? OV_EFAULT
        }
        guard opened == 0 else { throw DecodeError.unreadable(opened) }
        defer { ov_clear(file) }

        guard let info = ov_info(file, -1)?.pointee, info.channels > 0, info.rate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(info.rate),
                                         channels: AVAudioChannelCount(info.channels)) else {
            throw DecodeError.unsupportedLayout
        }
        guard SoundFileLimits.sampleRates.contains(format.sampleRate) else {
            throw SoundFileLimits.Violation.implausibleSampleRate(format.sampleRate)
        }
        let channelCount = Int(format.channelCount)
        let maximumFrames = Int(SoundFileLimits.longestSound * format.sampleRate)
        let maximumCapacity = min(maximumFrames, Int(SoundFileLimits.maximumBufferBytes
            / UInt64(channelCount) / UInt64(MemoryLayout<Float>.size)))
        let declaredFrames = ov_pcm_total(file, -1)
        guard declaredFrames <= maximumFrames else { throw SoundFileLimits.Violation.tooLong }
        // Ordinary files decode directly into their final buffer. A truncated or forged file can
        // underreport its total: grow only as needed, always within the actual frame limit.
        let initialCapacity = declaredFrames > 0 ? Int(declaredFrames) : Int(readFrames)
        try admit(format, try SoundFileLimits.sourceFrameCount(AVAudioFramePosition(initialCapacity),
            sampleRate: format.sampleRate, channels: format.channelCount))
        guard var buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(initialCapacity)) else {
            throw DecodeError.noAudio
        }
        var frameCount = 0
        var link: Int32 = 0
        while true {
            var pcm: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
            let frames = ov_read_float(file, &pcm, readFrames, &link)
            if frames == Int(OV_HOLE) { continue }
            guard frames > 0, let pcm else { break }
            // A chained file may switch layout at a link; the buffer holds one layout only.
            guard let linkInfo = ov_info(file, link)?.pointee,
                  linkInfo.channels == info.channels, linkInfo.rate == info.rate else { break }
            guard frames <= maximumFrames - frameCount else { throw SoundFileLimits.Violation.tooLong }
            let needed = frameCount + frames
            _ = try SoundFileLimits.sourceFrameCount(AVAudioFramePosition(needed),
                sampleRate: format.sampleRate, channels: format.channelCount)
            if needed > Int(buffer.frameCapacity) {
                let capacity = min(maximumCapacity, max(needed, Int(buffer.frameCapacity) * 2))
                guard let grown = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)),
                      let destination = grown.floatChannelData, let source = buffer.floatChannelData else {
                    throw DecodeError.noAudio
                }
                for channel in 0..<channelCount {
                    destination[channel].update(from: source[channel], count: frameCount)
                }
                buffer = grown
            }
            guard let channels = buffer.floatChannelData else { throw DecodeError.noAudio }
            for channel in 0..<channelCount {
                guard let source = pcm[channel] else { throw DecodeError.noAudio }
                channels[channel].advanced(by: frameCount).update(from: source, count: frames)
            }
            frameCount = needed
        }
        guard frameCount > 0 else { throw DecodeError.noAudio }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }
}
