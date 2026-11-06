import Foundation

/// A memory-only Ogg envelope. Audio bytes stay unchanged; opusfile handles pre-skip, gain
/// and multichannel downmixing exactly as for an Ogg Opus sound.
nonisolated final class Mp4OpusOggStream {
    private var data = Data()
    private var configuration: Data?
    private var sequence = 0
    private var granule = 0
    private var lastPage: Int?
    private static let checksums: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value) << 24
        for _ in 0..<8 { crc = (crc &<< 1) ^ (crc & 0x8000_0000 == 0 ? 0 : 0x04C1_1DB7) }
        return crc
    }

    func start(_ config: Data) throws {
        if let configuration {
            try AudioRead.require(config == configuration)
            return
        }
        let d = AudioRead(config)
        try d.range(0, 11)
        try AudioRead.require(d.byte(0) == 0)
        configuration = config
        var head = Data("OpusHead".utf8)
        head.append(1)
        head.append(UInt8(try d.byte(1)))
        Self.word(try d.uint(2, 2), 2, to: &head)
        Self.word(try d.uint(4, 4), 4, to: &head)
        Self.word(try d.uint(8, 2), 2, to: &head)
        let family = try d.byte(10)
        head.append(UInt8(family))
        if family != 0 { head.append(config[11...]) }
        packet(head, granule: 0, flags: 2)
        var tags = Data("OpusTags".utf8)
        Self.word(0, 4, to: &tags) // Empty vendor and comment list.
        Self.word(0, 4, to: &tags)
        packet(tags, granule: 0, flags: 0)
    }

    func append(_ bytes: Data, frames: Int) throws {
        try AudioRead.require(configuration != nil && frames > 0)
        // Keep physical packet durations even when MP4 timestamps understate them.
        // In particular, a shortened sample table must not truncate otherwise valid audio.
        granule = try AudioRead.add(granule, frames)
        packet(bytes, granule: granule, flags: 0)
    }

    func finish() throws -> Data {
        try AudioRead.require(granule > 0)
        guard let lastPage else { throw AudioRead.Failure.invalid }
        data[lastPage + 5] |= 4
        checksum(from: lastPage)
        return data
    }

    private static func word(_ value: Int, _ width: Int, to bytes: inout Data) {
        for i in 0..<width { bytes.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
    }

    private func packet(_ bytes: Data, granule: Int, flags: UInt8) {
        // A packet divisible by 255 ends with a zero lace. Large multistream packets may
        // span pages; only the page completing the packet receives a granule position.
        let segments = bytes.count / 255 + 1
        var segment = 0, offset = bytes.startIndex
        while segment < segments {
            let count = min(255, segments - segment)
            let final = segment + count == segments
            let start = data.count
            data.append(contentsOf: "OggS".utf8)
            data.append(0)
            data.append(segment == 0 ? flags : 1)
            Self.word(final ? granule : -1, 8, to: &data)
            Self.word(1, 4, to: &data) // One logical stream in this envelope.
            Self.word(sequence, 4, to: &data)
            Self.word(0, 4, to: &data)
            data.append(UInt8(count))
            var size = 0
            for index in segment..<(segment + count) {
                let lace = index == segments - 1 ? bytes.count % 255 : 255
                data.append(UInt8(lace)); size += lace
            }
            data.append(bytes[offset..<(offset + size)])
            checksum(from: start)
            lastPage = start
            sequence += 1; segment += count; offset += size
        }
    }

    private func checksum(from start: Int) {
        for i in 22..<26 { data[start + i] = 0 }
        var crc: UInt32 = 0
        for byte in data[start...] {
            crc = (crc &<< 8) ^ Self.checksums[Int((crc >> 24) ^ UInt32(byte))]
        }
        for i in 0..<4 { data[start + 22 + i] = UInt8(truncatingIfNeeded: crc >> (i * 8)) }
    }
}
