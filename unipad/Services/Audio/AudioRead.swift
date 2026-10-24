import Foundation

/// Checked, allocation-free reads into the original file. No declaration allocates PCM.
nonisolated struct AudioRead {
    enum Failure: Error { case invalid, capacity }
    let data: Data
    var size: Int { data.count }
    init(_ data: Data) { self.data = data }
    static func require(_ condition: Bool) throws { if !condition { throw Failure.invalid } }
    static func capacity(_ count: Int, _ maximum: Int) throws { if count > maximum { throw Failure.capacity } }
    static func add(_ a: Int, _ b: Int) throws -> Int {
        try require(a >= 0 && b >= 0 && a <= Int.max - b)
        return a + b
    }
    static func multiply(_ a: Int, _ b: Int) throws -> Int {
        try require(a >= 0 && b >= 0 && (b == 0 || a <= Int.max / b))
        return a * b
    }
    func range(_ at: Int, _ length: Int, _ end: Int? = nil) throws {
        let limit = end ?? size
        try Self.require(at >= 0 && length >= 0 && limit <= size && at <= limit && length <= limit - at)
    }
    func byte(_ at: Int) throws -> Int { try range(at, 1); return Int(data[data.startIndex + at]) }
    func uint(_ at: Int, _ count: Int, _ little: Bool = false) throws -> Int {
        try range(at, count)
        var value = 0
        for i in 0..<count {
            value = try Self.add(Self.multiply(value, 256), byte(at + (little ? count - 1 - i : i)))
        }
        return value
    }
    func matches(_ at: Int, _ text: String) -> Bool {
        let bytes = text.utf8
        guard at >= 0, at <= size, bytes.count <= size - at else { return false }
        return bytes.enumerated().allSatisfy { Int(data[data.startIndex + at + $0.offset]) == Int($0.element) }
    }
    static let aacRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
}

nonisolated final class AudioBits {
    private(set) var position = 0
    let size: Int
    private let little: Bool
    private let byte: (Int) throws -> Int
    init(_ size: Int, little: Bool = false, byte: @escaping (Int) throws -> Int) {
        self.size = size; self.little = little; self.byte = byte
    }
    func read(_ count: Int) throws -> Int {
        try AudioRead.require(count >= 0 && count <= 32 && position <= size && count <= size - position)
        var result = 0
        for i in 0..<count {
            let value = try (byte(position / 8) >> (little ? position % 8 : 7 - position % 8)) & 1
            result = little ? result + (value << i) : result * 2 + value
            position += 1
        }
        return result
    }
    func skip(_ count: Int) throws {
        try AudioRead.require(count >= 0 && position <= size && count <= size - position)
        position += count
    }
}
