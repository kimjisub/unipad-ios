import Foundation

/// ci/virtual-midi-device.c, driven through its command file: each line appended is one command, which the
/// tool answers by its line number in `acks`. The unit and UI test targets both build this file.
final class VirtualMidiDevice {
    let folder: URL
    private var commandCount: Int

    /// The commands file keeps the lines of earlier tests in the same run, so numbering continues after them.
    init(folder: URL) throws {
        self.folder = folder
        let commands = try String(contentsOf: folder.appendingPathComponent("commands"), encoding: .utf8)
        commandCount = commands.filter { $0 == "\n" }.count
    }

    /// Sends the Universal MIDI Packet words as one event packet from the first device opened.
    func send(_ words: [UInt32]) throws {
        try run("send " + words.map { String($0, radix: 16) }.joined(separator: " "))
    }

    func send(_ status: UInt32, _ data1: UInt32, _ data2: UInt32, port: UInt32 = 0) throws {
        try send([midiWord(status, data1, data2, port: port)])
    }

    /// Runs one command and waits for its answer; throws unless the tool answers "ok".
    func run(_ line: String) throws {
        let commands = try FileHandle(forWritingTo: folder.appendingPathComponent("commands"))
        defer { try? commands.close() }
        try commands.seekToEnd()
        try commands.write(contentsOf: Data((line + "\n").utf8))
        commandCount += 1
        let number = "\(commandCount) "
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let acks = (try? String(contentsOf: folder.appendingPathComponent("acks"), encoding: .utf8)) ?? ""
            if let ack = acks.split(separator: "\n").first(where: { $0.hasPrefix(number) }) {
                guard ack.hasSuffix(" ok") else { throw VirtualMidiDeviceError(description: "\(line) → \(ack)") }
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw VirtualMidiDeviceError(description: "\(line) → no answer")
    }
}

struct VirtualMidiDeviceError: Error, CustomStringConvertible {
    let description: String
}

/// A MIDI 1.0 channel message as one Universal MIDI Packet word, its group naming the port.
func midiWord(_ status: UInt32, _ data1: UInt32, _ data2: UInt32, port: UInt32 = 0) -> UInt32 {
    0x2000_0000 | port << 24 | status << 16 | data1 << 8 | data2
}
