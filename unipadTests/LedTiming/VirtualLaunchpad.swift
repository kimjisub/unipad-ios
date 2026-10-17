import QuartzCore
@testable import unipad

/// The Launchpad MK2 that ci/virtual-launchpad.sh runs in the simulator's MIDI server. MidiManager
/// finds it by name and connects to it as to a USB one; the tool writes when each message the app
/// sends arrives, the closest this test gets to the moment a command leaves the app (T2).
///
/// The app sends to the first MIDI destination when a device has no entity, as a virtual one does, so
/// `connect` checks that a message really comes through before anything is measured.
@MainActor
final class VirtualLaunchpad {
    private let arrivalsFile: URL

    private init(arrivalsFile: URL) {
        self.arrivalsFile = arrivalsFile
    }

    /// The LEDs a Launchpad MK2 driver sends: the 8x8 pads and round LEDs 0...15.
    nonisolated static func addresses(_ target: LedTarget) -> Bool {
        target.x == -1 ? (0...15).contains(target.y) : (0...7).contains(target.x) && (0...7).contains(target.y)
    }

    /// Waits until MidiManager drives the tool's device with its MK2 driver and a message sent through
    /// that driver arrives.
    static func connect(arrivalsFile: URL) async throws -> VirtualLaunchpad {
        let device = VirtualLaunchpad(arrivalsFile: arrivalsFile)
        let manager = MidiManager.shared
        manager.start()
        let deadline = Date().addingTimeInterval(10)
        while !(manager.isConnected && manager.driver is LaunchpadMK2Driver) {
            guard Date() < deadline else {
                throw VirtualLaunchpadError("MidiManager did not connect to a Launchpad MK2; is ci/virtual-launchpad.sh running?")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sentAt = CACurrentMediaTime()
        // Velocity 0 on the top-left pad sets no colour.
        manager.driver.sendPadLed(x: 0, y: 0, velocity: 0)
        while !device.arrivals(since: sentAt).contains(where: { $0.target == LedTarget(x: 0, y: 0) && $0.code == 0 }) {
            guard Date() < deadline else {
                manager.disconnect()
                throw VirtualLaunchpadError("the app's MIDI output did not reach the virtual Launchpad MK2 (\(arrivalsFile.path))")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return device
    }

    /// Leaves MidiManager disconnected, as without a Launchpad.
    func disconnect() {
        MidiManager.shared.disconnect()
    }

    /// What arrived from `start` (CACurrentMediaTime) on, decoded to the LEDs LedRunner addresses, at
    /// milliseconds after `start`.
    func arrivals(since start: CFTimeInterval) -> [LedCommand] {
        guard let text = try? String(contentsOf: arrivalsFile, encoding: .utf8) else { return [] }
        var commands: [LedCommand] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard let seconds = fields.first.flatMap({ Double($0) }), seconds >= start else { continue }
            var status: UInt8 = 0
            var data: [UInt8] = []
            for field in fields.dropFirst() {
                guard let byte = UInt8(field, radix: 16) else { continue }
                if byte >= 0x80 {
                    status = byte
                    data = []
                    continue
                }
                data.append(byte)
                if data.count == 2 {
                    if let target = Self.target(status: status, note: Int(data[0])) {
                        commands.append(LedCommand(ms: (seconds - start) * 1000, target: target, code: Int(data[1])))
                    }
                    data = []
                }
            }
        }
        return commands
    }

    /// The LED a message from LaunchpadMK2Driver lights: a note on pads and the right-hand round
    /// LEDs, a control change on the top row.
    private nonisolated static func target(status: UInt8, note: Int) -> LedTarget? {
        switch status {
        case 0x90:
            let row = 8 - note / 10
            guard (0...7).contains(row) else { return nil }
            switch note % 10 {
            case 1...8: return LedTarget(x: row, y: note % 10 - 1)
            case 9: return LedTarget(x: -1, y: 8 + row)
            default: return nil
            }
        case 0xB0 where (104...111).contains(note):
            return LedTarget(x: -1, y: note - 104)
        default:
            return nil
        }
    }
}

nonisolated struct VirtualLaunchpadError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
