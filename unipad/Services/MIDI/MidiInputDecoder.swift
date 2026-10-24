import Foundation

/// Decodes the MIDI 1.0 Universal MIDI Packets supplied by CoreMIDI.
nonisolated final class MidiInputDecoder: @unchecked Sendable {
    struct Event: Equatable, Sendable {
        let cmd: Int
        let sig: Int
        let note: Int
        let velocity: Int
    }

    private let lock = NSLock()
    private var sysex: [Int: [UInt8]] = [:]

    func reset() { lock.withLock { sysex.removeAll() } }

    func decode(_ words: [UInt32], portIndex: Int) -> [Event] {
        lock.withLock { decodeLocked(words, portIndex: portIndex) }
    }

    private func decodeLocked(_ words: [UInt32], portIndex: Int) -> [Event] {
        var events: [Event] = []
        var index = 0
        // UMP packet lengths by message type, including reserved types. A MIDI 2.0
        // payload word must never be mistaken for another MIDI 1.0 message.
        let lengths = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]
        while index < words.count {
            let word = words[index]
            let type = Int(word >> 28)
            let length = lengths[type]
            guard index + length <= words.count else { break }
            defer { index += length }
            let group = Int((word >> 24) & 0xF)
            if type == 3 {
                let status = Int((word >> 20) & 0xF)
                let count = Int((word >> 16) & 0xF)
                guard status <= 3, count <= 6 else { sysex[group] = nil; continue }
                let tail = words[index + 1]
                let bytes = [UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word),
                             UInt8(truncatingIfNeeded: tail >> 24), UInt8(truncatingIfNeeded: tail >> 16),
                             UInt8(truncatingIfNeeded: tail >> 8), UInt8(truncatingIfNeeded: tail)].prefix(count)
                if status <= 1 { sysex[group] = [] }
                guard let previous = sysex[group] else { continue }
                let message = previous + bytes
                // Only retain a prefix of the original Pro's Live-mode notification.
                // Arbitrary or unterminated SysEx cannot grow the input buffer.
                let live: [UInt8] = [0, 0x20, 0x29, 2, 0x10, 0x2E, 0]
                guard message.count <= live.count, live.starts(with: message) else { sysex[group] = nil; continue }
                sysex[group] = message
                if status == 0 || status == 3 {
                    if message == live { events.append(Event(cmd: 7, sig: 46, note: 0, velocity: -9)) }
                    sysex[group] = nil
                }
                continue
            }
            guard type == 2 else { continue }
            let midiStatus = Int((word >> 16) & 0xFF)
            let statusType = midiStatus & 0xF0
            guard (0x80...0xE0).contains(statusType) else { continue }
            let cable = group != 0 ? group : portIndex
            events.append(Event(cmd: (cable << 4) | (statusType >> 4),
                                sig: Int(Int8(truncatingIfNeeded: midiStatus)),
                                note: Int((word >> 8) & 0xFF), velocity: Int(word & 0xFF)))
        }
        return events
    }
}
