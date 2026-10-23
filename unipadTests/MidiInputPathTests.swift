import CoreMIDI
import Foundation
import Testing
@testable import unipad

/// Where a MidiInputPathTests device lives.
enum MidiTestDeviceKind: String, CaseIterable {
    /// CoreMIDI event lists go through MidiManager's own parser, its driver and PlayViewModel; LED
    /// messages are read where the driver hands them to MidiManager to send.
    case parser
    /// A device ci/midi-input-tests.sh publishes in the simulator's MIDI server: MidiManager finds it by
    /// name and its messages and LEDs travel through CoreMIDI, as a USB device's do.
    case coreMIDI

    static var folder: String? { ProcessInfo.processInfo.environment["UNIPAD_VIRTUAL_MIDI_DIR"] }
    static var available: [Self] { folder == nil ? [.parser] : allCases }
}

@MainActor
protocol MidiTestDevice: AnyObject {
    /// The channel messages that reached the device, as status and data bytes.
    var messages: [[UInt8]] { get }
    func clearMessages()
    /// Sends one event packet of MIDI 1.0 Universal MIDI Packet words, on the port the device was opened with.
    func send(_ words: [UInt32]) async throws
    func close() async
}

nonisolated struct MidiTestDeviceError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Feeds CoreMIDI event lists to `MidiManager.channelMessages` as the input port's read block does,
/// with the port MidiManager would have connected, and records the LED messages its driver sends.
@MainActor
final class ParserMidiDevice: MidiTestDevice, MidiDriverSendSignalListener {
    private let port: Int
    private(set) var messages: [[UInt8]] = []

    init(driver: MidiDriver, port: Int) {
        self.port = port
        MidiManager.shared.overrideDriver(driver)
        driver.sendSignalListener = self
    }

    func clearMessages() { messages.removeAll() }

    func send(_ words: [UInt32]) async throws {
        // The list must hold at least a whole MIDIEventList (69 words), whose one packet declares 64 words.
        let builder = MIDIEventList.Builder(inProtocol: ._1_0, wordSize: words.count + 128)
        guard builder.append(timestamp: 0, words: words) != nil else { throw MidiTestDeviceError("\(words.count) words do not fit") }
        let events = builder.withUnsafePointer { MidiManager.channelMessages(in: $0, port: port) }
        MidiManager.shared.receive(events)
    }

    func close() async { MidiManager.shared.overrideDriver(NotingDriver()) }

    func onSend(cmd: UInt8, sig: UInt8, note: UInt8, velocity: UInt8) { messages.append([sig, note, velocity]) }
    func onSendRaw(messages: [[UInt8]], cableNumber: Int) {}
}

/// Drives ci/virtual-midi-device.c. A virtual endpoint has no entities, so MidiManager connects it as
/// port 0; another port travels in the Universal MIDI Packet group.
@MainActor
final class SimulatorMidiDevice: MidiTestDevice {
    let tool: VirtualMidiDevice
    private var folder: URL { tool.folder }
    private let port: UInt32
    private var skippedArrivals = 0

    private init(folder: URL, port: Int) throws {
        tool = try VirtualMidiDevice(folder: folder)
        self.port = UInt32(port)
    }

    static func open(folder: URL, name: String, port: Int, expects: (MidiDriver) -> Bool) async throws -> SimulatorMidiDevice {
        let manager = MidiManager.shared
        try #require(!manager.isConnected, "another MIDI device is connected: \(manager.connectedDeviceName ?? "?")")
        let device = try SimulatorMidiDevice(folder: folder, port: port)
        try device.tool.run("open \(name)")
        manager.start()
        try await PlayUsageScenario.waitWhile { !(manager.isConnected && expects(manager.driver)) }
        guard manager.isConnected && expects(manager.driver) else {
            await device.close()
            throw MidiTestDeviceError("MidiManager connected \(manager.connectedDeviceName ?? "nothing") for \(name)")
        }
        return device
    }

    var messages: [[UInt8]] {
        let text = (try? String(contentsOf: folder.appending(path: "arrivals"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").dropFirst(skippedArrivals).map { line in
            line.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        }
    }

    func clearMessages() {
        let text = (try? String(contentsOf: folder.appending(path: "arrivals"), encoding: .utf8)) ?? ""
        skippedArrivals = text.split(separator: "\n").count
    }

    func send(_ words: [UInt32]) async throws {
        try tool.send(words.map { $0 >> 28 == 0x2 ? $0 | port << 24 : $0 })
    }

    func close() async {
        try? tool.run("close")
        try? await PlayUsageScenario.waitWhile { MidiManager.shared.isConnected }
    }
}

extension PlayUsageRecordTests {
    /// From the bytes and port a device sends to the pad PlayViewModel presses, its chain, and the LED
    /// sent back to the device.
    @MainActor
    @Suite struct MidiInputPathTests {
        private static let noteOn: UInt32 = 0x90, noteOff: UInt32 = 0x80, polyAftertouch: UInt32 = 0xA0, controlChange: UInt32 = 0xB0

        /// Opens a device called `name` that MidiManager drives with `make()`'s driver on `port`, runs
        /// `body` once connecting has redrawn the LEDs, then removes the device.
        private func withDevice(
            _ kind: MidiTestDeviceKind, _ name: String, port: Int = 0, driver make: () -> MidiDriver,
            _ body: (MidiTestDevice) async throws -> Void
        ) async throws {
            let expected = type(of: make())
            let device: MidiTestDevice
            switch kind {
            case .parser:
                device = ParserMidiDevice(driver: make(), port: port)
            case .coreMIDI:
                let folder = URL(fileURLWithPath: try #require(MidiTestDeviceKind.folder))
                device = try await SimulatorMidiDevice.open(folder: folder, name: name, port: port) { type(of: $0) == expected }
            }
            do {
                try await Task.sleep(for: .milliseconds(300))
                device.clearMessages()
                try await body(device)
            } catch {
                await device.close()
                throw error
            }
            await device.close()
            #expect(!MidiManager.shared.isConnected, "MidiManager kept the removed device")
        }

        private func pressed(_ s: PlayUsageScenario, _ x: Int, _ y: Int) -> Bool {
            s.vm.padItems.indices.contains(x) && s.vm.padItems[x].indices.contains(y) && s.vm.padItems[x][y] != nil
        }

        private func waitFor(_ condition: () -> Bool) async throws {
            try await PlayUsageScenario.waitWhile(timeout: 3) { !condition() }
        }

        /// Launchpad Pro MK3, X and Mini MK3 are connected on their second port.
        @Test(arguments: MidiTestDeviceKind.available)
        func proMK3PortOneNotesPressLightAndReleasePads(kind: MidiTestDeviceKind) async throws {
            try await PlayUsageScenario.run(grid: .init(chain: 2)) { s in
                try await s.loadReady()
                try await withDevice(kind, "LPProMK3 MIDI", port: 1, driver: { LaunchpadProMK3Driver() }) { device in
                    try await device.send([midiWord(Self.noteOn, 81, 100)])
                    try await waitFor { pressed(s, 0, 0) }
                    #expect(pressed(s, 0, 0), "a port 1 note on did not press the top-left pad")
                    try await waitFor { device.messages.contains([0x90, 81, 3]) }
                    #expect(device.messages.contains([0x90, 81, 3]), "the pressed pad's light did not reach the device")

                    device.clearMessages()
                    try await device.send([midiWord(Self.noteOn, 81, 0)])
                    try await waitFor { !pressed(s, 0, 0) }
                    #expect(!pressed(s, 0, 0), "a port 1 note on with velocity 0 did not release the pad")
                    try await waitFor { device.messages.contains([0x90, 81, 0]) }
                    #expect(device.messages.contains([0x90, 81, 0]), "the released pad's light did not go out")

                    try await device.send([midiWord(Self.controlChange, 79, 127)])
                    try await waitFor { s.vm.chain.value == 1 }
                    #expect(s.vm.chain.value == 1, "the second right-hand button did not select chain 2")
                }
            }
        }

        /// An event packet may hold more than the 64 words `MIDIEventPacket` declares.
        @Test(arguments: MidiTestDeviceKind.available)
        func packetLongerThanSixtyFourWordsIsReadToTheEnd(kind: MidiTestDeviceKind) async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                try await withDevice(kind, "LPProMK3 MIDI", driver: { LaunchpadProMK3Driver() }) { device in
                    let utilityNoOps = [UInt32](repeating: 0, count: 64)
                    try await device.send(utilityNoOps + [midiWord(Self.noteOn, 81, 100), midiWord(Self.noteOn, 82, 100)])
                    try await waitFor { pressed(s, 0, 0) && pressed(s, 0, 1) }
                    #expect(pressed(s, 0, 0) && pressed(s, 0, 1), "notes after the 64th word were lost")
                }
            }
        }

        /// The later words of a longer Universal MIDI Packet are not channel messages of their own.
        @Test(arguments: MidiTestDeviceKind.available)
        func multiWordMessagesAreNotReadAsNotes(kind: MidiTestDeviceKind) async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                try await withDevice(kind, "LPProMK3 MIDI", driver: { LaunchpadProMK3Driver() }) { device in
                    // System exclusive 00 20 29 02 0E 00 in two words, as a Launchpad's mode reply.
                    try await device.send([0x3006_0020, 0x2902_0E00])
                    // A MIDI 2.0 note on (type 4): its first word reads like a MIDI 1.0 note on for pad 81.
                    try await device.send([0x4090_5101, 0xFFFF_0000])
                    try await device.send([midiWord(Self.noteOn, 82, 100)])
                    try await waitFor { pressed(s, 0, 1) }
                    #expect(pressed(s, 0, 1))
                    #expect(!pressed(s, 0, 0), "a word inside a longer message pressed a pad")
                }
            }
        }

        @Test(arguments: MidiTestDeviceKind.available)
        func keyboardReleasesOnNoteOffAndIgnoresAftertouch(kind: MidiTestDeviceKind) async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                try await withDevice(kind, "UniPad Test Keyboard", driver: { MasterKeyboardDriver() }) { device in
                    try await device.send([midiWord(Self.noteOn, 36, 100)])
                    try await waitFor { pressed(s, 7, 0) }
                    #expect(pressed(s, 7, 0), "the lowest key did not press the bottom-left pad")

                    try await device.send([midiWord(Self.polyAftertouch, 36, 0)])
                    try await Task.sleep(for: .milliseconds(200))
                    #expect(pressed(s, 7, 0), "aftertouch easing off released the pad")

                    try await device.send([midiWord(Self.noteOff, 36, 64)])
                    try await waitFor { !pressed(s, 7, 0) }
                    #expect(!pressed(s, 7, 0), "a note off with a release velocity left the pad pressed")
                }
            }
        }

        /// Every command waits for its own answer, also after earlier tests' commands in the same run.
        @Test(.enabled(if: MidiTestDeviceKind.folder != nil, "needs ci/midi-input-tests.sh"))
        func virtualDeviceReportsAFailedCommand() throws {
            let folder = URL(fileURLWithPath: try #require(MidiTestDeviceKind.folder))
            try VirtualMidiDevice(folder: folder).run("close")
            #expect(throws: VirtualMidiDeviceError.self) { try VirtualMidiDevice(folder: folder).run("send 20904064") }
        }

        @Test(arguments: MidiTestDeviceKind.available)
        func matrixReleasesOnVelocityZeroAndSelectsEveryRingChain(kind: MidiTestDeviceKind) async throws {
            try await PlayUsageScenario.run(grid: .init(chain: 24)) { s in
                try await s.loadReady()
                try await withDevice(kind, "Matrix Test", driver: { MatrixDriver() }) { device in
                    try await device.send([midiWord(Self.noteOn, 36, 100)])
                    try await waitFor { pressed(s, 7, 0) }
                    #expect(pressed(s, 7, 0))
                    try await waitFor { device.messages.contains([0x91, 36, 3]) }
                    #expect(device.messages.contains([0x91, 36, 3]), "the pressed pad's light did not reach the device")

                    try await device.send([midiWord(Self.noteOn, 36, 0)])
                    try await waitFor { !pressed(s, 7, 0) }
                    #expect(!pressed(s, 7, 0), "a note on with velocity 0 left the pad pressed")

                    for (note, chain) in [(101, 1), (123, 8), (116, 15), (115, 16), (108, 23)] {
                        try await device.send([midiWord(Self.noteOn, UInt32(note), 127)])
                        try await waitFor { s.vm.chain.value == chain }
                        #expect(s.vm.chain.value == chain, "ring note \(note) did not select chain \(chain + 1)")
                        try await device.send([midiWord(Self.noteOn, UInt32(note), 0)])
                    }
                }
            }
        }

        /// A pack larger than 8x8 still drives a Launchpad's 8x8 pads; its extra pads light nothing.
        @Test(arguments: MidiTestDeviceKind.available)
        func padsOutsideTheLaunchpadGridSendNoLight(kind: MidiTestDeviceKind) async throws {
            try await PlayUsageScenario.run(grid: .init(buttonX: 10, buttonY: 10)) { s in
                try await s.loadReady()
                try await withDevice(kind, "LPProMK3 MIDI", port: 1, driver: { LaunchpadProMK3Driver() }) { device in
                    s.press(8, 0)
                    s.press(0, 8)
                    s.press(9, 9)
                    s.press(0, 0)
                    try await waitFor { device.messages.contains([0x90, 81, 3]) }
                    #expect(device.messages.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") } == ["90 51 03"],
                            "pads outside the 8x8 grid lit other buttons")
                }
            }
        }
    }
}
