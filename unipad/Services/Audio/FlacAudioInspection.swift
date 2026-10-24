import Foundation

nonisolated enum FlacAudioInspection {
    static func streamInfo(_ d: AudioRead, at: Int) throws -> (rate: Int, channels: Int, bits: Int) {
        try d.range(at, 34)
        let rate = try d.uint(at + 10, 3) >> 4
        let channels = try ((d.byte(at + 12) >> 1) & 7) + 1
        let bits = try (((d.byte(at + 12) & 1) << 4) | (d.byte(at + 13) >> 4)) + 1
        try AudioRead.require(rate > 0)
        return (rate, channels, bits)
    }
    static func inspect(_ d: AudioRead) throws -> AudioAdmission.Facts {
        var at = 4, last = false, rate = 0, channels = 0, bits = 0
        while !last {
            try d.range(at, 4)
            let type = try d.byte(at), length = try d.uint(at + 1, 3), payload = at + 4
            try d.range(payload, length)
            if at == 4 {
                try AudioRead.require(type & 127 == 0 && length == 34)
                let info = try streamInfo(d, at: payload)
                rate = info.rate; channels = info.channels; bits = info.bits
            } else { try AudioRead.require(type & 127 != 0 && type & 127 < 127) }
            last = type & 128 != 0; at = payload + length
        }
        return .init(sampleRate: rate, channels: channels, frames: try frames(d, from: at, limit: d.size, rate: rate, channels: channels, bits: bits, zeroOrigin: true))
    }
    private struct Frame {
        let end: Int, samples: Int, number: Int, variable: Bool, assignment: Int
    }
    /// Walk subframes and verify checksums without allocating decoded samples.
    static func frames(_ d: AudioRead, from: Int, limit: Int, rate: Int, channels: Int, bits: Int, zeroOrigin: Bool = false) throws -> Int {
        func header(_ start: Int) throws -> Frame {
            try d.range(start, 6, limit)
            try AudioRead.require(d.byte(start) == 255 && d.byte(start + 1) & 0xfe == 0xf8)
            let variable = try d.byte(start + 1) & 1 != 0, blockCode = try d.byte(start + 2) >> 4
            let rateCode = try d.byte(start + 2) & 15, assignment = try d.byte(start + 3) >> 4
            let precision = try (d.byte(start + 3) >> 1) & 7
            try AudioRead.require(d.byte(start + 3) & 1 == 0 && assignment <= 10 && (assignment < 8 ? assignment + 1 : 2) == channels && precision != 3)
            try AudioRead.require([bits, 8, 12, 0, 16, 20, 24, 32][precision] == bits)
            var pos = start + 4
            let first = try d.byte(pos); pos += 1
            var number = first
            if first >= 128 {
                var count = 0
                for shift in stride(from: 7, through: 0, by: -1) {
                    if first & (1 << shift) == 0 { break }; count += 1
                }
                try AudioRead.require(count >= 2 && count <= 7)
                number = first & (0x7f >> count)
                for _ in 0..<(count - 1) {
                    let next = try d.byte(pos); pos += 1
                    try AudioRead.require(next & 0xc0 == 0x80)
                    number = try AudioRead.add(AudioRead.multiply(number, 64), next & 63)
                }
            }
            let samples: Int
            switch blockCode {
            case 1: samples = 192
            case 2...5: samples = 576 << (blockCode - 2)
            case 6: samples = try d.byte(pos) + 1; pos += 1
            case 7: samples = try d.uint(pos, 2) + 1; pos += 2
            case 8...15: samples = 256 << (blockCode - 8)
            default: throw AudioRead.Failure.invalid
            }
            let frameRate: Int
            switch rateCode {
            case 0: frameRate = rate
            case 1...11: frameRate = [88200,176400,192000,8000,16000,22050,24000,32000,44100,48000,96000][rateCode - 1]
            case 12: frameRate = try d.byte(pos) * 1000; pos += 1
            case 13: frameRate = try d.uint(pos, 2); pos += 2
            case 14: frameRate = try d.uint(pos, 2) * 10; pos += 2
            default: throw AudioRead.Failure.invalid
            }
            try AudioRead.require(frameRate == rate)
            try d.range(start, pos - start + 1, limit)
            var crc = 0
            for i in start..<pos { crc = try AudioRead.crcStep(crc, d.byte(i), 8, 7) }
            try AudioRead.require(crc == d.byte(pos)); pos += 1
            return Frame(end: pos, samples: samples, number: number, variable: variable, assignment: assignment)
        }
        var at = from
        try AudioRead.require(at < limit)
        var frame = try header(at)
        let origin = zeroOrigin ? 0 : frame.number
        var total = 0, ordinal = 0
        while true {
            try AudioRead.require(frame.number == AudioRead.add(origin, frame.variable ? total : ordinal))
            let frameEnd = frame.end
            let body = AudioBits(try AudioRead.multiply(limit - frameEnd, 8)) { try d.byte(frameEnd + $0) }
            func residual(_ order: Int) throws {
                let method = try body.read(2)
                try AudioRead.require(method <= 1)
                let parameterBits = method == 0 ? 4 : 5, partitions = try 1 << body.read(4)
                try AudioRead.require(frame.samples % partitions == 0)
                for partition in 0..<partitions {
                    let count = frame.samples / partitions - (partition == 0 ? order : 0)
                    try AudioRead.require(count >= 0)
                    let parameter = try body.read(parameterBits)
                    if parameter == (1 << parameterBits) - 1 { try body.skip(AudioRead.multiply(count, body.read(5))) }
                    else {
                        for _ in 0..<count {
                            while try body.read(1) == 0 { /* Physical bit limit bounds unary codes. */ }
                            try body.skip(parameter)
                        }
                    }
                }
            }
            for channel in 0..<channels {
                let extra = frame.assignment == 8 || frame.assignment == 10 ? channel == 1 : frame.assignment == 9 ? channel == 0 : false
                var precision = bits + (extra ? 1 : 0)
                try AudioRead.require(body.read(1) == 0)
                let type = try body.read(6)
                if try body.read(1) != 0 {
                    var wasted = 1
                    while try body.read(1) == 0 { wasted += 1; try AudioRead.require(wasted < precision) }
                    precision -= wasted
                }
                try AudioRead.require(precision > 0)
                if type == 0 { try body.skip(precision) }
                else if type == 1 { try body.skip(AudioRead.multiply(frame.samples, precision)) }
                else if type >= 8 && type <= 12 {
                    let order = type - 8
                    try AudioRead.require(order <= frame.samples)
                    try body.skip(AudioRead.multiply(order, precision)); try residual(order)
                } else if type >= 32 {
                    let order = (type & 31) + 1
                    try AudioRead.require(order <= frame.samples)
                    try body.skip(AudioRead.multiply(order, precision))
                    let coefficientBits = try body.read(4)
                    try AudioRead.require(coefficientBits < 15)
                    try body.skip(5); try body.skip(order * (coefficientBits + 1)); try residual(order)
                } else { throw AudioRead.Failure.invalid }
            }
            try AudioRead.require(body.read((8 - body.position % 8) % 8) == 0)
            let end = try AudioRead.add(frame.end, body.position / 8)
            try d.range(end, 2, limit)
            var crc = 0
            for p in at..<(end + 2) { crc = try AudioRead.crcStep(crc, d.byte(p), 16, 0x8005) }
            try AudioRead.require(crc == 0)
            total = try AudioRead.add(total, frame.samples); ordinal += 1; at = end + 2
            if at == limit { break }
            let next = try header(at)
            try AudioRead.require(next.variable == frame.variable); frame = next
        }
        return total
    }
}
