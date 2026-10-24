import Foundation

nonisolated enum OggAudioInspection {
    private struct Span { let at: Int; var length: Int; let index: Int }
    private struct Packet {
        let d: AudioRead, spans: [Span], size: Int
        func byte(_ index: Int) throws -> Int {
            try AudioRead.require(index >= 0 && index < size)
            var low = 0, high = spans.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if spans[mid].index <= index { low = mid } else { high = mid - 1 }
            }
            let span = spans[low]
            return try d.byte(span.at + index - span.index)
        }
        func matches(_ index: Int, _ text: String) throws -> Bool {
            guard index >= 0 && index <= size && text.utf8.count <= size - index else { return false }
            for (i, b) in text.utf8.enumerated() { if try byte(index + i) != Int(b) { return false } }
            return true
        }
        func uint(_ index: Int, _ count: Int) throws -> Int {
            var value = 0
            for i in (0..<count).reversed() { value = try AudioRead.add(AudioRead.multiply(value, 256), byte(index + i)) }
            return value
        }
        func bits() throws -> AudioBits { AudioBits(try AudioRead.multiply(size, 8), little: true, byte: byte) }
    }
    /// CRCs, lacing, sequence, packet sizes and granule origin are checked before admission.
    static func inspect(_ d: AudioRead) throws -> AudioAdmission.Facts {
        var at = 0, serial = -1, sequence = 0, packetCount = 0, packetSize = 0
        var rate = 0, channels = 0, opus = false, streams = 1, preSkip = 0
        var spans = [Span](), shortBlock = 0, longBlock = 0, modes = [Bool](), previousBlock = 0
        var calculated = 0, lastPacketFrames = 0, granule = 0, origin: Int?, ended = false
        while at < d.size {
            try AudioRead.require(!ended && d.matches(at, "OggS"))
            try d.range(at, 27)
            try AudioRead.require(d.byte(at + 4) == 0)
            let flags = try d.byte(at + 5)
            try AudioRead.require(flags & 0xf8 == 0)
            let stream = try d.uint(at + 14, 4, true), pageSequence = try d.uint(at + 18, 4, true)
            if serial == -1 {
                try AudioRead.require(flags & 2 != 0 && flags & 1 == 0 && pageSequence == 0); serial = stream
            } else { try AudioRead.require(flags & 2 == 0) }
            try AudioRead.require(stream == serial && pageSequence == sequence && (flags & 1 != 0) == (packetSize > 0))
            sequence = (sequence + 1) % 4294967296
            let segments = try d.byte(at + 26)
            try d.range(at + 27, segments)
            var payloadBytes = 0
            for i in 0..<segments { payloadBytes += try d.byte(at + 27 + i) }
            let pageSize = 27 + segments + payloadBytes
            try d.range(at, pageSize)
            var crc = 0
            for i in 0..<pageSize {
                let b = try (22...25).contains(i) ? 0 : d.byte(at + i)
                crc = AudioRead.crcStep(crc, b, 32, 0x04c11db7)
            }
            try AudioRead.require(crc == d.uint(at + 22, 4, true))
            var payload = at + 27 + segments, completed = 0
            for i in 0..<segments {
                let size = try d.byte(at + 27 + i)
                if size > 0 {
                    if let last = spans.last, last.at + last.length == payload { spans[spans.count - 1].length += size }
                    else { spans.append(Span(at: payload, length: size, index: packetSize)) }
                    packetSize = try AudioRead.add(packetSize, size)
                }
                payload += size
                if size < 255 {
                    let packet = Packet(d: d, spans: spans, size: packetSize)
                    if packetCount == 0 {
                        opus = try packet.matches(0, "OpusHead")
                        if opus {
                            try AudioRead.require(packet.size >= 19 && packet.byte(8) >= 1 && packet.byte(8) <= 15)
                            channels = try packet.byte(9); rate = 48000; preSkip = try packet.uint(10, 2)
                            let family = try packet.byte(18)
                            streams = try opusStreamCount(channels: channels, family: family,
                                                          size: packet.size, mappingAt: 19, byte: packet.byte)
                        } else {
                            try AudioRead.require(packet.size == 30 && packet.byte(0) == 1 && packet.matches(1, "vorbis") && packet.uint(7, 4) == 0)
                            channels = try packet.byte(11); rate = try packet.uint(12, 4)
                            let sizes = try packet.byte(28), small = sizes & 15, large = sizes >> 4
                            try AudioRead.require(small >= 6 && small <= 13 && large >= small && large <= 13 && packet.byte(29) & 1 != 0)
                            shortBlock = 1 << small; longBlock = 1 << large
                        }
                        try AudioRead.require(rate > 0 && channels > 0)
                    } else if packetCount == 1 {
                        try AudioRead.require(opus ? packet.matches(0, "OpusTags") : packet.byte(0) == 3 && packet.matches(1, "vorbis"))
                    } else if !opus && packetCount == 2 { modes = try vorbisModes(packet, channels) }
                    else if opus {
                        try AudioRead.require(packet.size > 0)
                        lastPacketFrames = try opusFrames(packet.size, streams: streams, byte: packet.byte)
                        calculated = try AudioRead.add(calculated, lastPacketFrames)
                    } else {
                        let bits = try packet.bits()
                        try AudioRead.require(bits.read(1) == 0 && !modes.isEmpty)
                        let mode = try bits.read(ilog(modes.count - 1))
                        try AudioRead.require(mode < modes.count)
                        let block = modes[mode] ? longBlock : shortBlock
                        if modes[mode] { try bits.skip(2) }
                        lastPacketFrames = block
                        if previousBlock != 0 { calculated = try AudioRead.add(calculated, (previousBlock + block) / 4) }
                        previousBlock = block
                    }
                    packetCount += 1; completed += 1; spans.removeAll(keepingCapacity: true); packetSize = 0
                }
            }
            let unset = try (0..<8).allSatisfy { try d.byte(at + 6 + $0) == 255 }
            if !unset {
                let raw = try d.uint(at + 6, 8, true)
                if calculated > 0 && origin == nil { origin = raw > calculated ? raw - calculated : 0 }
                let start = origin ?? 0
                try AudioRead.require(raw >= start)
                let current = raw - start
                try AudioRead.require(completed > 0 && current >= granule && current <= calculated)
                granule = current
            } else { try AudioRead.require(completed == 0) }
            if flags & 4 != 0 {
                try AudioRead.require(!unset && packetSize == 0 && calculated > 0 && granule >= preSkip && calculated - granule <= lastPacketFrames)
                ended = true
            }
            at += pageSize
        }
        try AudioRead.require(ended)
        return .init(sampleRate: rate, channels: channels, frames: granule - preSkip)
    }
    private static func ilog(_ n: Int) -> Int { n == 0 ? 0 : Int.bitWidth - n.leadingZeroBitCount }
    private static func vorbisModes(_ packet: Packet, _ channels: Int) throws -> [Bool] {
        try AudioRead.require(packet.byte(0) == 5 && packet.matches(1, "vorbis"))
        let b = try packet.bits()
        try b.skip(56)
        let codebooks = try b.read(8) + 1
        for _ in 0..<codebooks {
            try AudioRead.require(b.read(24) == 0x564342)
            let dimensions = try b.read(16), entries = try b.read(24)
            try AudioRead.require(dimensions > 0 && entries > 0)
            if try b.read(1) == 1 {
                var current = 0, length = try b.read(5) + 1
                while current < entries {
                    try AudioRead.require(length <= 32)
                    let count = try b.read(ilog(entries - current))
                    try AudioRead.require(count <= entries - current); current += count; length += 1
                }
            } else {
                let sparse = try b.read(1) == 1
                if sparse { for _ in 0..<entries { if try b.read(1) != 0 { try b.skip(5) } } }
                else { try b.skip(entries * 5) }
            }
            let lookup = try b.read(4)
            try AudioRead.require(lookup <= 2)
            if lookup > 0 {
                try b.skip(64)
                let bits = try b.read(4) + 1
                try b.skip(1)
                let values: Int
                if lookup == 2 { values = try AudioRead.multiply(entries, dimensions) }
                else {
                    func fits(_ base: Int) -> Bool {
                        var product = 1
                        for _ in 0..<dimensions { if base > entries / product { return false }; product *= base }
                        return true
                    }
                    var low = 1, high = entries
                    while low < high {
                        let mid = (low + high + 1) / 2
                        if fits(mid) { low = mid } else { high = mid - 1 }
                    }
                    values = low
                }
                try b.skip(AudioRead.multiply(values, bits))
            }
        }
        let times = try b.read(6) + 1
        for _ in 0..<times { try AudioRead.require(b.read(16) == 0) }
        let floors = try b.read(6) + 1
        for _ in 0..<floors {
            let type = try b.read(16)
            if type == 0 {
                try b.skip(54)
                let books = try b.read(4) + 1
                for _ in 0..<books { try AudioRead.require(b.read(8) < codebooks) }
            } else if type == 1 {
                let partitions = try (0..<b.read(5)).map { _ in try b.read(4) }
                var classes = [Int](repeating: 0, count: (partitions.max() ?? -1) + 1)
                for j in classes.indices {
                    classes[j] = try b.read(3) + 1
                    let sub = try b.read(2)
                    if sub > 0 { try AudioRead.require(b.read(8) < codebooks) }
                    for _ in 0..<(1 << sub) { try AudioRead.require(b.read(8) <= codebooks) }
                }
                try b.skip(2)
                let rangeBits = try b.read(4)
                for partition in partitions { try b.skip(classes[partition] * rangeBits) }
            } else { throw AudioRead.Failure.invalid }
        }
        let residues = try b.read(6) + 1
        for _ in 0..<residues {
            try AudioRead.require(b.read(16) <= 2); try b.skip(72)
            let classifications = try b.read(6) + 1
            try AudioRead.require(b.read(8) < codebooks)
            let cascades: [Int] = try (0..<classifications).map { _ in
                let low = try b.read(3)
                return try low | ((b.read(1) == 1 ? b.read(5) : 0) << 3)
            }
            for cascade in cascades {
                for k in 0..<8 { if cascade & (1 << k) != 0 { try AudioRead.require(b.read(8) < codebooks) } }
            }
        }
        let mappings = try b.read(6) + 1
        for _ in 0..<mappings {
            try AudioRead.require(b.read(16) == 0)
            let submaps = try b.read(1) == 1 ? b.read(4) + 1 : 1
            if try b.read(1) == 1 {
                let count = try b.read(8) + 1
                for _ in 0..<count {
                    let magnitude = try b.read(ilog(channels - 1)), angle = try b.read(ilog(channels - 1))
                    try AudioRead.require(magnitude != angle && magnitude < channels && angle < channels)
                }
            }
            try AudioRead.require(b.read(2) == 0)
            if submaps > 1 { for _ in 0..<channels { try AudioRead.require(b.read(4) < submaps) } }
            for _ in 0..<submaps { try b.skip(8); try AudioRead.require(b.read(8) < floors && b.read(8) < residues) }
        }
        let count = try b.read(6) + 1
        let modes: [Bool] = try (0..<count).map { _ in
            let block = try b.read(1) != 0
            try AudioRead.require(b.read(16) == 0 && b.read(16) == 0 && b.read(8) < mappings)
            return block
        }
        try AudioRead.require(b.read(1) == 1)
        return modes
    }
    /// OpusHead and MP4 dOps share the same channel-mapping table after their own headers.
    static func opusStreamCount(channels: Int, family: Int, size: Int, mappingAt: Int,
                                byte: (Int) throws -> Int) throws -> Int {
        try AudioRead.require(channels > 0)
        if family == 0 {
            try AudioRead.require(channels <= 2)
            return 1
        }
        try AudioRead.require(mappingAt >= 0 && mappingAt <= size && size - mappingAt >= 2 && channels <= size - mappingAt - 2)
        let streams = try byte(mappingAt), coupled = try byte(mappingAt + 1)
        try AudioRead.require(streams > 0 && coupled <= streams && streams + coupled <= 255)
        for c in 0..<channels {
            let mapping = try byte(mappingAt + 2 + c)
            try AudioRead.require(mapping == 255 || mapping < streams + coupled)
        }
        return streams
    }
    /// All streams except the last have a self-delimited final frame length.
    static func opusFrames(_ size: Int, streams: Int, byte: (Int) throws -> Int) throws -> Int {
        var pos = 0, duration = 0
        for stream in 0..<streams {
            let toc = try byte(pos); pos += 1
            let config = toc >> 3, code = toc & 3
            let frameSamples = config >= 16 ? 120 << (config & 3) : config >= 12 ? 480 << (config & 1) : config & 3 == 3 ? 2880 : 480 << (config & 3)
            var count = code == 0 ? 1 : 2, vbr = code == 2, padding = 0
            if code == 3 {
                let control = try byte(pos); pos += 1; count = control & 63; vbr = control & 128 != 0
                try AudioRead.require(count >= 1 && count <= 48)
                if control & 64 != 0 {
                    var next: Int
                    repeat {
                        next = try byte(pos); pos += 1
                        padding = try AudioRead.add(padding, next == 255 ? 254 : next)
                        try AudioRead.require(padding <= size - pos)
                    } while next == 255
                }
            }
            try AudioRead.require(frameSamples * count <= 5760)
            let samples = frameSamples * count
            try AudioRead.require(duration == 0 || duration == samples); duration = samples
            func length() throws -> Int {
                let first = try byte(pos); pos += 1
                if first < 252 { return first }
                let next = try byte(pos); pos += 1; return first + 4 * next
            }
            var known = 0
            if vbr { for _ in 0..<(count - 1) { known = try AudioRead.add(known, length()) } }
            let payload: Int
            if stream < streams - 1 {
                let last = try length()
                payload = try vbr ? AudioRead.add(known, last) : AudioRead.multiply(count, last)
            } else {
                try AudioRead.require(pos <= size && padding <= size - pos)
                let available = size - pos - padding
                try AudioRead.require(vbr ? known <= available && available - known <= 1275 : available % count == 0 && available / count <= 1275)
                payload = available
            }
            try AudioRead.require(pos <= size && padding <= size - pos && payload <= size - pos - padding)
            pos += payload + padding
        }
        try AudioRead.require(pos == size)
        return duration
    }
}
