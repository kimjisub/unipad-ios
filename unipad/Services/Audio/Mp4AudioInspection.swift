import Foundation

nonisolated enum Mp4AudioInspection {
    private struct Box { let type: String, data: Int, end: Int }
    private static let maxBoxes = 4096, maxRows = 262144, maxSizes = 1048576
    private static func boxes(_ d: AudioRead, _ from: Int, _ end: Int) throws -> [Box] {
        var result = [Box](), at = from
        while at < end {
            try AudioRead.capacity(result.count + 1, maxBoxes); try d.range(at, 8, end)
            let small = try d.uint(at, 4), header = small == 1 ? 16 : 8
            try d.range(at, header, end)
            let size = try small == 0 ? end - at : small == 1 ? d.uint(at + 8, 8) : small
            try AudioRead.require(size >= header); try d.range(at, size, end)
            let type = String(bytes: d.data[(d.data.startIndex + at + 4)..<(d.data.startIndex + at + 8)], encoding: .isoLatin1) ?? ""
            result.append(Box(type: type, data: at + header, end: at + size)); at += size
        }
        return result
    }
    private static func child(_ d: AudioRead, _ parent: Box, _ type: String) throws -> Box {
        let found = try boxes(d, parent.data, parent.end).filter { $0.type == type }
        try AudioRead.require(found.count == 1)
        return found[0]
    }
    private static func tableCount(_ d: AudioRead, _ box: Box, _ stride: Int) throws -> Int {
        try d.range(box.data, 8, box.end)
        let count = try d.uint(box.data + 4, 4)
        try d.range(box.data + 8, AudioRead.multiply(count, stride), box.end)
        try AudioRead.capacity(count, maxRows)
        return count
    }
    private struct Codec: Equatable {
        let type: String
        var rate: Int, channels: Int
        var aacFrames: Int?, alacFrames = 0, precision = 0, opusStreams = 0, pcmAlign = 0
    }
    private static func codec(_ d: AudioRead, _ entry: Box) throws -> Codec {
        try AudioRead.require(["mp4a", "alac", "fLaC", "Opus", "sowt", "twos", "lpcm"].contains(entry.type))
        try d.range(entry.data, 28, entry.end)
        let version = try d.uint(entry.data + 8, 2)
        try AudioRead.require(version <= 1)
        let headerSize = version == 1 ? 44 : 28
        try d.range(entry.data, headerSize, entry.end)
        let children = Box(type: "entry", data: entry.data + headerSize, end: entry.end)
        var channels = try d.uint(entry.data + 16, 2)
        let rate = try d.uint(entry.data + 24, 4) >> 16
        var result = Codec(type: entry.type, rate: rate, channels: channels)
        if entry.type == "mp4a" {
            let items = try boxes(d, children.data, children.end)
            let direct = items.filter { $0.type == "esds" }, wave = items.filter { $0.type == "wave" }
            let esds: Box
            if direct.count == 1 { esds = direct[0] }
            else if wave.count == 1 { esds = try child(d, wave[0], "esds") }
            else { throw AudioRead.Failure.invalid }
            let config = try aacConfig(d, esds)
            if config.channels != 0 { channels = config.channels }
            result.rate = config.rate; result.channels = channels; result.aacFrames = config.packetFrames
        } else if entry.type == "alac" {
            let c = try child(d, children, "alac")
            try d.range(c.data, 28, c.end)
            let frames = try d.uint(c.data + 4, 4)
            try AudioRead.require(frames > 0)
            result.rate = try d.uint(c.data + 24, 4); result.channels = try d.byte(c.data + 13); result.alacFrames = frames
        } else if entry.type == "fLaC" {
            let c = try child(d, children, "dfLa")
            try d.range(c.data, 42, c.end)
            try AudioRead.require(d.uint(c.data, 4) == 0 && d.byte(c.data + 4) & 127 == 0 && d.uint(c.data + 5, 3) == 34)
            let info = try FlacAudioInspection.streamInfo(d, at: c.data + 8)
            result.rate = info.rate; result.channels = info.channels; result.precision = info.bits
        } else if entry.type == "Opus" {
            let c = try child(d, children, "dOps")
            try d.range(c.data, 11, c.end); try AudioRead.require(d.byte(c.data) == 0)
            channels = try d.byte(c.data + 1)
            let family = try d.byte(c.data + 10)
            let streams = try OggAudioInspection.opusStreamCount(channels: channels, family: family,
                                                                size: c.end - c.data, mappingAt: 11) { try d.byte(c.data + $0) }
            result.rate = 48000; result.channels = channels; result.opusStreams = streams
        } else {
            let bits = try d.uint(entry.data + 18, 2)
            try AudioRead.require(bits >= 8 && bits <= 64 && bits % 8 == 0 && channels >= 1 && channels <= 8)
            let align = channels * (bits / 8)
            if version == 1 { try AudioRead.require(d.uint(entry.data + 32, 4) == bits / 8 && d.uint(entry.data + 36, 4) == align) }
            result.pcmAlign = align
        }
        try AudioRead.require(result.rate > 0 && result.channels > 0)
        return result
    }
    /// Validate sample extents and reserve physical output independently of container timestamps.
    static func inspect(_ d: AudioRead) throws -> AudioAdmission.Facts {
        let top = try boxes(d, 0, d.size), media = top.filter { $0.type == "mdat" }, movies = top.filter { $0.type == "moov" }
        try AudioRead.require(!media.isEmpty && movies.count == 1)
        for track in try boxes(d, movies[0].data, movies[0].end).filter({ $0.type == "trak" }) {
            let mdia = try child(d, track, "mdia"), handler = try child(d, mdia, "hdlr")
            try d.range(handler.data, 12, handler.end)
            if !d.matches(handler.data + 8, "soun") { continue }
            let mdhd = try child(d, mdia, "mdhd"), version = try d.byte(mdhd.data)
            try AudioRead.require(version <= 1)
            let clockOffset = version == 0 ? 12 : 20
            try d.range(mdhd.data, clockOffset + 4, mdhd.end)
            let clock = try d.uint(mdhd.data + clockOffset, 4)
            try AudioRead.require(clock > 0)
            let stbl = try child(d, child(d, mdia, "minf"), "stbl"), stsd = try child(d, stbl, "stsd")
            try d.range(stsd.data, 8, stsd.end)
            let entries = try boxes(d, stsd.data + 8, stsd.end)
            try AudioRead.require(entries.count == d.uint(stsd.data + 4, 4) && !entries.isEmpty)
            let codecs = try entries.map { try codec(d, $0) }, c = codecs[0]
            try AudioRead.require(codecs.allSatisfy { $0 == c })
            let rate = c.rate, channels = c.channels, aacFrames = c.aacFrames
            let stts = try child(d, stbl, "stts"), timeCount = try tableCount(d, stts, 8)
            var samples = 0, ticks = 0, verifiedFrames = 0
            for i in 0..<timeCount {
                let at = stts.data + 8 + i * 8, count = try d.uint(at, 4), delta = try d.uint(at + 4, 4)
                try AudioRead.require(count > 0)
                let zeroFirst = i == 0 && count == 1 && delta == 0 && aacFrames != nil
                try AudioRead.require(delta > 0 || zeroFirst)
                samples = try AudioRead.add(samples, count)
                ticks = try AudioRead.add(ticks, AudioRead.multiply(count, delta))
                if let aacFrames {
                    let actual = try AudioRead.multiply(delta, rate), full = try AudioRead.multiply(aacFrames, clock)
                    let partialLast = !zeroFirst && i == timeCount - 1 && count == 1 && actual < full
                    try AudioRead.require(zeroFirst || partialLast || (actual >= full ? actual - full : full - actual) < rate)
                    let frames = partialLast ? actual / clock + (actual % clock == 0 ? 0 : 1) : aacFrames
                    verifiedFrames = try AudioRead.add(verifiedFrames, AudioRead.multiply(count, frames))
                }
            }
            let stsz = try child(d, stbl, "stsz")
            try d.range(stsz.data, 12, stsz.end)
            let constantSize = try d.uint(stsz.data + 4, 4), sizeCount = try d.uint(stsz.data + 8, 4)
            try AudioRead.require(sizeCount == samples && samples > 0)
            if constantSize == 0 {
                try AudioRead.capacity(sizeCount, maxSizes)
                try d.range(stsz.data + 12, AudioRead.multiply(sizeCount, 4), stsz.end)
            }
            let offsets = try boxes(d, stbl.data, stbl.end).filter { $0.type == "stco" || $0.type == "co64" }
            try AudioRead.require(offsets.count == 1)
            let offsetBox = offsets[0], width = offsetBox.type == "co64" ? 8 : 4
            let chunks = try tableCount(d, offsetBox, width), stsc = try child(d, stbl, "stsc"), mappings = try tableCount(d, stsc, 12)
            try AudioRead.require(chunks > 0 && mappings > 0)
            if c.pcmAlign == 0 && aacFrames == nil { try AudioRead.capacity(samples, maxSizes) }
            var physicalFrames = 0, mapping = 0, used = 0
            // Two bounded integer arrays, at most 4 MiB together, rather than per-chunk objects.
            var starts = [Int](repeating: 0, count: chunks), ends = starts
            var nextFirst = try mappings > 1 ? d.uint(stsc.data + 20, 4) : chunks + 1
            try AudioRead.require(d.uint(stsc.data + 8, 4) == 1)
            for chunk in 1...chunks {
                if chunk == nextFirst {
                    mapping += 1
                    nextFirst = try mapping + 1 < mappings ? d.uint(stsc.data + 8 + (mapping + 1) * 12, 4) : chunks + 1
                }
                try AudioRead.require(nextFirst > chunk && nextFirst <= chunks + 1)
                let row = stsc.data + 8 + mapping * 12, count = try d.uint(row + 4, 4), description = try d.uint(row + 8, 4)
                try AudioRead.require(count > 0 && count <= samples - used && description >= 1 && description <= entries.count)
                var bytes = 0
                if constantSize != 0 { bytes = try AudioRead.multiply(count, constantSize) }
                else {
                    for sample in used..<(used + count) {
                        let size = try d.uint(stsz.data + 12 + sample * 4, 4)
                        try AudioRead.require(size > 0); bytes = try AudioRead.add(bytes, size)
                    }
                }
                let offset = try d.uint(offsetBox.data + 8 + (chunk - 1) * width, width)
                var low = 0, high = media.count - 1
                while low <= high {
                    let middle = (low + high) / 2
                    if media[middle].data <= offset { low = middle + 1 } else { high = middle - 1 }
                }
                try AudioRead.require(high >= 0)
                let extent = media[high]
                try AudioRead.require(offset <= extent.end && bytes <= extent.end - offset)
                if c.pcmAlign != 0 {
                    try AudioRead.require(bytes % c.pcmAlign == 0)
                    physicalFrames = try AudioRead.add(physicalFrames, bytes / c.pcmAlign)
                } else if aacFrames == nil {
                    var packetAt = offset
                    for sample in used..<(used + count) {
                        let size = try constantSize != 0 ? constantSize : d.uint(stsz.data + 12 + sample * 4, 4)
                        let frames: Int
                        if c.type == "alac" { frames = try alacFrames(d, packetAt, size, c.alacFrames) }
                        else if c.type == "fLaC" { frames = try FlacAudioInspection.frames(d, from: packetAt, limit: packetAt + size, rate: rate, channels: channels, bits: c.precision) }
                        else if c.type == "Opus" {
                            let start = packetAt
                            frames = try OggAudioInspection.opusFrames(size, streams: c.opusStreams) { index in
                                try AudioRead.require(index >= 0 && index < size)
                                return try d.byte(start + index)
                            }
                        } else { throw AudioRead.Failure.invalid }
                        physicalFrames = try AudioRead.add(physicalFrames, frames); packetAt += size
                    }
                }
                starts[chunk - 1] = offset; ends[chunk - 1] = offset + bytes; used += count
            }
            try AudioRead.require(used == samples && mapping + 1 == mappings)
            starts.sort(); ends.sort()
            for i in 1..<starts.count { try AudioRead.require(starts[i] >= ends[i - 1]) }
            let numerator = try AudioRead.multiply(ticks, rate), timeline = numerator / clock + (numerator % clock == 0 ? 0 : 1)
            return .init(sampleRate: rate, channels: channels, frames: aacFrames != nil ? verifiedFrames : max(physicalFrames, timeline))
        }
        throw AudioRead.Failure.invalid
    }
    private static func alacFrames(_ d: AudioRead, _ at: Int, _ size: Int, _ maximum: Int) throws -> Int {
        let b = AudioBits(try AudioRead.multiply(size, 8)) { try d.byte(at + $0) }
        try AudioRead.require([0, 1, 3].contains(b.read(3)))
        try b.skip(16)
        let explicit = try b.read(1) != 0
        try b.skip(3)
        let frames = try explicit ? b.read(32) : maximum
        try AudioRead.require(frames >= 1 && frames <= maximum)
        return frames
    }
    private struct Descriptor { let tag: Int, data: Int, end: Int }
    private static func aacConfig(_ d: AudioRead, _ box: Box) throws -> (rate: Int, channels: Int, packetFrames: Int) {
        func descriptor(_ at: Int, _ end: Int) throws -> Descriptor {
            try d.range(at, 2, end)
            let tag = try d.byte(at)
            var pos = at + 1, length = 0, done = false
            for _ in 0..<4 {
                if done { break }
                try d.range(pos, 1, end)
                let b = try d.byte(pos); pos += 1; length = length * 128 + (b & 127)
                if b & 128 == 0 { done = true }
            }
            try AudioRead.require(done); try d.range(pos, length, end)
            return Descriptor(tag: tag, data: pos, end: pos + length)
        }
        let es = try descriptor(box.data + 4, box.end)
        try AudioRead.require(es.tag == 3); try d.range(es.data, 3, es.end)
        let flags = try d.byte(es.data + 2)
        var pos = es.data + 3
        if flags & 128 != 0 { pos += 2 }
        if flags & 64 != 0 { try d.range(pos, 1, es.end); pos += try 1 + d.byte(pos) }
        if flags & 32 != 0 { pos += 2 }
        let decoder = try descriptor(pos, es.end)
        try AudioRead.require(decoder.tag == 4); try d.range(decoder.data, 13, decoder.end)
        let config = try descriptor(decoder.data + 13, decoder.end)
        try AudioRead.require(config.tag == 5)
        let b = AudioBits(try AudioRead.multiply(config.end - config.data, 8)) { try d.byte(config.data + $0) }
        func objectType() throws -> Int { let type = try b.read(5); return try type == 31 ? 32 + b.read(6) : type }
        func frequency() throws -> Int {
            let index = try b.read(4)
            if index == 15 { return try b.read(24) }
            try AudioRead.require(index < AudioRead.aacRates.count)
            return AudioRead.aacRates[index]
        }
        var type = try objectType(), rate = try frequency()
        let coreRate = rate, configuration = try b.read(4)
        try AudioRead.require(configuration <= 7)
        var channels = configuration == 7 ? 8 : configuration
        if type == 5 || type == 29 {
            let stereo = type == 29
            rate = try frequency(); type = try objectType()
            if stereo && channels == 1 { channels = 2 }
        }
        let short = try b.read(1) != 0, baseFrames = type == 23 || type == 39 ? (short ? 480 : 512) : short ? 960 : 1024
        if type >= 1 && type <= 4 && configuration != 0 {
            if try b.read(1) != 0 { try b.skip(14) }
            let ext = try b.read(1)
            if ext == 0 && b.position + 16 <= (config.end - config.data) * 8 {
                if try b.read(11) == 0x2b7 && objectType() == 5 && b.read(1) != 0 {
                    rate = try frequency()
                    if try b.position + 12 <= (config.end - config.data) * 8 && b.read(11) == 0x548 && b.read(1) != 0 && channels == 1 { channels = 2 }
                }
            }
        }
        try AudioRead.require(coreRate > 0 && rate % coreRate == 0 && rate / coreRate >= 1 && rate / coreRate <= 2)
        return (rate, channels, baseFrames * (rate / coreRate))
    }
}
