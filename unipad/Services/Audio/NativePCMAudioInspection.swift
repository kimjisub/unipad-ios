import Foundation

/// Native PCM containers used by the existing AVAudioFile path. No header frame count
/// replaces physically present audio. Compression-specific readers remain separate.
nonisolated enum NativePCMAudioInspection {
    static func caf(_ d: AudioRead) throws -> AudioAdmission.Facts {
        try d.range(0, 8)
        try AudioRead.require(d.uint(4, 2) == 1 && d.uint(6, 2) == 0)
        var at = 8, rate = 0, channels = 0, align = 0, frames = 0
        var foundDescription = false, foundData = false
        while at < d.size {
            try d.range(at, 12)
            let payload = at + 12
            // CAF explicitly permits a data chunk extending to EOF with a signed -1 size.
            let toEOF = (0..<8).allSatisfy { (try? d.byte(at + 4 + $0)) == 255 }
            let length: Int
            if toEOF {
                try AudioRead.require(d.matches(at, "data"))
                length = d.size - payload
            } else { length = try d.uint(at + 4, 8) }
            try d.range(payload, length)
            if d.matches(at, "desc") {
                try AudioRead.require(at == 8 && !foundDescription && length == 32 && d.matches(payload + 8, "lpcm"))
                let frequency = Double(bitPattern: UInt64(try d.uint(payload, 8)))
                guard let exactRate = Int(exactly: frequency), exactRate > 0 else { throw AudioRead.Failure.invalid }
                rate = exactRate
                let flags = try d.uint(payload + 12, 4), bytesPerPacket = try d.uint(payload + 16, 4)
                let framesPerPacket = try d.uint(payload + 20, 4), bits = try d.uint(payload + 28, 4)
                channels = try d.uint(payload + 24, 4)
                try AudioRead.require(flags & ~3 == 0 && channels > 0 && bits >= 1 && bits <= 64 && framesPerPacket > 0 && bytesPerPacket > 0 && bytesPerPacket % framesPerPacket == 0)
                if flags & 1 != 0 { try AudioRead.require(bits == 32 || bits == 64) }
                align = bytesPerPacket / framesPerPacket
                try AudioRead.require(align == AudioRead.multiply(channels, (bits + 7) / 8))
                foundDescription = true
            } else if d.matches(at, "data") {
                try AudioRead.require(foundDescription && !foundData && length >= 4)
                foundData = true
                frames = (length - 4) / align
            } else { try AudioRead.require(foundDescription) }
            at = payload + length
        }
        try AudioRead.require(foundDescription && foundData)
        return .init(sampleRate: rate, channels: channels, frames: frames)
    }
    /// Convert an integral, positive 80-bit extended rate without floating-point rounding.
    private static func extendedRate(_ d: AudioRead, _ at: Int) throws -> Int {
        let exponent = try d.uint(at, 2), high = try d.uint(at + 2, 4), low = try d.uint(at + 6, 4)
        try AudioRead.require(exponent > 0 && exponent < 0x7fff && high & 0x80000000 != 0)
        let mantissa = (UInt64(high) << 32) | UInt64(low), shift = exponent - 16383 - 63
        if shift >= 0 {
            try AudioRead.require(shift < 63 && mantissa <= UInt64(Int.max) >> shift)
            return Int(mantissa << shift)
        }
        let right = -shift
        try AudioRead.require(right < 64 && mantissa & ((UInt64(1) << right) - 1) == 0)
        let value = mantissa >> right
        try AudioRead.require(value > 0 && value <= UInt64(Int.max))
        return Int(value)
    }
    static func aiff(_ d: AudioRead) throws -> AudioAdmission.Facts {
        try d.range(0, 12)
        let compressed = d.matches(8, "AIFC")
        try AudioRead.require(compressed || d.matches(8, "AIFF"))
        var at = 12, rate = 0, channels = 0, align = 0, frames = 0
        var foundFormat = false, foundData = false
        while at < d.size {
            try d.range(at, 8)
            let length = try d.uint(at + 4, 4), payload = at + 8
            try d.range(payload, length)
            if d.matches(at, "COMM") {
                try AudioRead.require(!foundFormat && length >= (compressed ? 22 : 18))
                channels = try d.uint(payload, 2)
                let bits = try d.uint(payload + 6, 2)
                rate = try extendedRate(d, payload + 8)
                try AudioRead.require(channels > 0 && bits >= 1 && bits <= 64)
                if compressed {
                    let codecAt = payload + 18
                    try AudioRead.require(["NONE", "twos", "sowt", "fl32", "FL32", "fl64", "FL64", "in24", "in32"].contains { d.matches(codecAt, $0) })
                    if d.matches(codecAt, "in24") { try AudioRead.require(bits == 24) }
                    if d.matches(codecAt, "in32") { try AudioRead.require(bits == 32) }
                    if d.matches(codecAt, "sowt") { try AudioRead.require(bits == 16) }
                    if d.matches(codecAt, "fl32") || d.matches(codecAt, "FL32") { try AudioRead.require(bits == 32) }
                    if d.matches(codecAt, "fl64") || d.matches(codecAt, "FL64") { try AudioRead.require(bits == 64) }
                }
                align = try AudioRead.multiply(channels, (bits + 7) / 8); foundFormat = true
            } else if d.matches(at, "SSND") {
                try AudioRead.require(foundFormat && !foundData && length >= 8)
                let offset = try d.uint(payload, 4)
                try AudioRead.require(offset <= length - 8)
                frames = (length - 8 - offset) / align; foundData = true
            }
            let padding = length % 2
            if padding > d.size - payload - length { try AudioRead.require(foundFormat && foundData); break }
            at = payload + length + padding
        }
        try AudioRead.require(foundFormat && foundData)
        return .init(sampleRate: rate, channels: channels, frames: frames)
    }
}
