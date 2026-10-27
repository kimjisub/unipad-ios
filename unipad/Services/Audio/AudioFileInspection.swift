import Foundation

/// Uses file contents, never the extension or an advertised duration, before native decoding.
nonisolated enum AudioFileInspection {
    static func inspect(url: URL) -> AudioAdmission.Inspection {
        do { return inspect(try Data(contentsOf: url, options: .alwaysMapped)) }
        catch { return .rejected(.readFailure) }
    }
    static func inspect(_ input: Data) -> AudioAdmission.Inspection {
        let d = AudioRead(input)
        do {
            let facts: AudioAdmission.Facts
            if d.matches(0, "RIFF") { facts = try wave(d) }
            else if d.matches(0, "FORM") || d.matches(0, "caff") { return .rejected(.invalidFormat) }
            else if d.matches(0, "OggS") { facts = try OggAudioInspection.inspect(d) }
            else if d.matches(0, "fLaC") { facts = try FlacAudioInspection.inspect(d) }
            else if ["ftyp", "moov", "mdat"].contains(where: { d.matches(4, $0) }) { facts = try Mp4AudioInspection.inspect(d) }
            else {
                do { facts = try mpeg(d) }
                catch AudioRead.Failure.invalid { facts = try Mp4AudioInspection.inspect(d) }
            }
            return .accepted(facts)
        } catch AudioRead.Failure.capacity { return .rejected(.readFailure) }
        catch { return .rejected(.invalidFormat) }
    }
    private static func wave(_ d: AudioRead) throws -> AudioAdmission.Facts {
        try AudioRead.require(d.matches(8, "WAVE"))
        var at = 12, rate = 0, channels = 0, align = 0, encoding = 0, compressed = 0, dataBytes = 0
        var foundData = false, foundFormat = false
        while at < d.size {
            if d.size - at < 8 && foundFormat && foundData { break }
            try d.range(at, 8)
            let length = try d.uint(at + 4, 4, true), payload = at + 8
            let available = min(length, d.size - payload), isData = d.matches(at, "data")
            if available < length && !isData && foundFormat && foundData { break }
            if !isData { try d.range(payload, length) }
            if d.matches(at, "fmt ") {
                try AudioRead.require(!foundFormat && length >= 16)
                foundFormat = true
                encoding = try d.uint(payload, 2, true); channels = try d.uint(payload + 2, 2, true)
                rate = try d.uint(payload + 4, 4, true); align = try d.uint(payload + 12, 2, true)
                let bits = try d.uint(payload + 14, 2, true)
                if encoding == 0xfffe {
                    try AudioRead.require(length >= 40 && d.uint(payload + 16, 2, true) >= 22)
                    encoding = try d.uint(payload + 24, 2, true)
                    try AudioRead.require(d.uint(payload + 26, 2, true) == 0 && d.uint(payload + 28, 4, true) == 0x00100000 && d.uint(payload + 32, 4) == 0x800000aa && d.uint(payload + 36, 4) == 0x00389b71)
                }
                try AudioRead.require([1, 3, 85].contains(encoding) && channels > 0 && rate > 0 && align > 0)
                if encoding != 85 {
                    try AudioRead.require(bits >= 8 && bits <= 64 && bits % 8 == 0 && (encoding != 3 || bits == 32 || bits == 64))
                    try AudioRead.require(align == channels * (bits / 8))
                }
            } else if isData {
                foundData = true
                try AudioRead.require(align > 0)
                if encoding == 85 {
                    let facts = try mpeg(d, start: payload, end: payload + available, allowADTS: false)
                    try AudioRead.require(facts.sampleRate == rate && facts.channels == channels)
                    compressed = try AudioRead.add(compressed, facts.frames)
                } else { dataBytes = try AudioRead.add(dataBytes, available - available % align) }
            }
            let padded = try AudioRead.add(length, length % 2)
            if padded > d.size - payload { break }
            at = payload + padded
        }
        try AudioRead.require(foundFormat && foundData && align > 0 && dataBytes % align == 0)
        return .init(sampleRate: rate, channels: channels, frames: encoding == 85 ? compressed : dataBytes / align)
    }
    private static func mpegEnd(_ d: AudioRead, _ start: Int, _ end: Int) throws -> Int {
        var tail = end
        while true {
            if tail - start >= 128 && d.matches(tail - 128, "TAG") { tail -= 128; continue }
            if tail - start < 32 || !d.matches(tail - 32, "APETAGEX") { return tail }
            let before = tail
            do {
                let footer = tail - 32, version = try d.uint(footer + 8, 4, true)
                let length = try d.uint(footer + 12, 4, true), count = try d.uint(footer + 16, 4, true), flags = try d.uint(footer + 20, 4, true)
                try AudioRead.require((version == 1000 || version == 2000) && length >= 32 && length <= tail - start && flags & 0x20000000 == 0 && d.uint(footer + 24, 8) == 0)
                let body = tail - length
                var first = body
                if flags & 0x80000000 != 0 {
                    try AudioRead.require(body - start >= 32)
                    first -= 32
                    try AudioRead.require(d.matches(first, "APETAGEX") && d.uint(first + 8, 4, true) == version && d.uint(first + 12, 4, true) == length && d.uint(first + 16, 4, true) == count && d.uint(first + 20, 4, true) & 0x20000000 != 0)
                }
                try AudioRead.require(count <= (footer - body) / 10)
                var at = body
                for _ in 0..<count {
                    try d.range(at, 8, footer)
                    let size = try d.uint(at, 4, true), itemFlags = try d.uint(at + 4, 4, true)
                    try AudioRead.require(itemFlags <= 5)
                    at += 8
                    var keyLength = 0
                    while true {
                        try d.range(at, 1, footer)
                        let value = try d.byte(at); at += 1
                        if value == 0 { break }
                        keyLength += 1
                        try AudioRead.require(value >= 32 && value <= 126 && value != 61 && keyLength <= 255)
                    }
                    try AudioRead.require(keyLength > 0)
                    try d.range(at, size, footer); at += size
                }
                try AudioRead.require(at == footer)
                tail = first
            } catch AudioRead.Failure.invalid { tail = before }
            if tail == before { return tail }
        }
    }
    private struct MpegFrame {
        let rate: Int, channels: Int, samples: Int, bytes: Int, version: Int, layer: Int
        func same(_ other: MpegFrame) -> Bool { rate == other.rate && channels == other.channels && version == other.version && layer == other.layer }
    }
    private static func mpegFrame(_ d: AudioRead, _ at: Int, _ end: Int) throws -> MpegFrame? {
        if at < 0 || at > end || end - at < 4 { return nil }
        let h = try d.uint(at, 4)
        if h >> 21 != 0x7ff { return nil }
        let version = (h >> 19) & 3, layer = (h >> 17) & 3, index = (h >> 12) & 15, rateIndex = (h >> 10) & 3
        if version == 1 || layer == 0 || index < 1 || index > 14 || rateIndex >= 3 { return nil }
        let rate = [44100, 48000, 32000][rateIndex] / (version == 3 ? 1 : version == 2 ? 2 : 4)
        let channels = (h >> 6) & 3 == 3 ? 1 : 2
        let rates: [Int]
        if version == 3 && layer == 3 { rates = [32,64,96,128,160,192,224,256,288,320,352,384,416,448] }
        else if version == 3 && layer == 2 { rates = [32,48,56,64,80,96,112,128,160,192,224,256,320,384] }
        else if version == 3 { rates = [32,40,48,56,64,80,96,112,128,160,192,224,256,320] }
        else if layer == 3 { rates = [32,48,56,64,80,96,112,128,144,160,176,192,224,256] }
        else { rates = [8,16,24,32,40,48,56,64,80,96,112,128,144,160] }
        let bitrate = rates[index - 1], padding = (h >> 9) & 1
        let samples = layer == 3 ? 384 : layer == 1 && version != 3 ? 576 : 1152
        let bytes = layer == 3 ? (12000 * bitrate / rate + padding) * 4 : (samples == 576 ? 72000 : 144000) * bitrate / rate + padding
        return MpegFrame(rate: rate, channels: channels, samples: samples, bytes: bytes, version: version, layer: layer)
    }
    private static func mpeg(_ d: AudioRead, start: Int = 0, end payloadEnd: Int? = nil, allowADTS: Bool = true) throws -> AudioAdmission.Facts {
        let end = try mpegEnd(d, start, payloadEnd ?? d.size)
        var at = start
        while at < end {
            if try d.byte(at) == 0 { at += 1; continue }
            if end - at < 3 || !d.matches(at, "ID3") { break }
            try d.range(at, 10, end)
            try AudioRead.require(d.byte(at + 3) >= 2 && d.byte(at + 3) <= 4)
            var length = 0
            for i in 6...9 { let b = try d.byte(at + i); try AudioRead.require(b < 128); length = length * 128 + b }
            let footer = try d.byte(at + 3) == 4 && d.byte(at + 5) & 16 != 0 ? 10 : 0
            let size = try AudioRead.add(length, 10 + footer)
            try d.range(at, size, end); at += size
        }
        if try end - at >= 2 && d.byte(at) == 255 && d.byte(at + 1) & 0xf6 == 0xf0 {
            try AudioRead.require(allowADTS)
            return try adts(d, at, end)
        }
        var probes = min(1048576, max(4096, try AudioRead.multiply(end - start, 4)))
        func frameAt(_ position: Int) throws -> MpegFrame? {
            guard probes > 0 else { throw AudioRead.Failure.capacity }
            probes -= 1
            return try mpegFrame(d, position, end)
        }
        guard let first = try frameAt(at), first.bytes <= end - at else { throw AudioRead.Failure.invalid }
        var anchorAt = at, anchor: MpegFrame?
        while anchorAt < end {
            if let candidate = try frameAt(anchorAt), candidate.bytes <= end - anchorAt {
                let nextAt = anchorAt + candidate.bytes, next = try frameAt(nextAt)
                if nextAt == end || next.map({ candidate.same($0) }) == true { anchor = candidate; break }
            }
            anchorAt += 1
        }
        if anchor == nil { anchor = first; anchorAt = at }
        let layout = anchor!
        var frames = 0, stream = layout
        while at < end {
            let frame = try frameAt(at)
            if at < anchorAt {
                if let f = frame, frames > 0 && !layout.same(f) && f.bytes <= end - at && f.bytes > anchorAt - at { throw AudioRead.Failure.invalid }
                if let f = frame, layout.same(f) && f.bytes <= anchorAt - at { frames = try AudioRead.add(frames, f.samples); at += f.bytes }
                else { at += 1 }
                continue
            }
            guard let f = frame, f.bytes <= end - at else { at += 1; continue }
            let nextAt = at + f.bytes, next = try frameAt(nextAt)
            let continuous = nextAt == end || next.map { f.same($0) } == true
            if !continuous && at + 4 < nextAt {
                for inside in (at + 4)..<nextAt {
                    if let candidate = try frameAt(inside), stream.same(candidate) && candidate.bytes <= end - inside {
                        let followingAt = inside + candidate.bytes, following = try frameAt(followingAt)
                        try AudioRead.require(followingAt != end && following.map { !candidate.same($0) } != false)
                    }
                }
            }
            if !stream.same(f) { try AudioRead.require(!continuous); at += 1; continue }
            frames = try AudioRead.add(frames, f.samples); stream = f; at = nextAt
        }
        try AudioRead.require(frames > 0)
        return .init(sampleRate: stream.rate, channels: stream.channels, frames: frames)
    }
    private static func adts(_ d: AudioRead, _ start: Int, _ end: Int) throws -> AudioAdmission.Facts {
        var at = start, frames = 0, rate = 0, channels = 0
        while at < end {
            try d.range(at, 7, end)
            try AudioRead.require(d.byte(at) == 255 && d.byte(at + 1) & 0xf6 == 0xf0)
            let index = try (d.byte(at + 2) >> 2) & 15
            try AudioRead.require(index < AudioRead.aacRates.count)
            let r = AudioRead.aacRates[index], config = try ((d.byte(at + 2) & 1) << 2) | (d.byte(at + 3) >> 6)
            let c = config == 7 ? 8 : config
            try AudioRead.require(c > 0 && (rate == 0 || (rate == r && channels == c)))
            let length = try ((d.byte(at + 3) & 3) << 11) | (d.byte(at + 4) << 3) | (d.byte(at + 5) >> 5)
            try AudioRead.require(length >= (d.byte(at + 1) & 1 == 1 ? 7 : 9))
            try d.range(at, length, end)
            frames = try AudioRead.add(frames, 1024 * ((d.byte(at + 6) & 3) + 1))
            rate = r; channels = c; at += length
        }
        try AudioRead.require(frames > 0)
        return .init(sampleRate: rate, channels: channels, frames: frames)
    }
}
