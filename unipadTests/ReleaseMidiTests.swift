import XCTest
@testable import unipad

/// Simulator CoreMIDI rejects virtual endpoints with kMIDINotPermitted (-10844).
/// Replace the device boundary; keep the manager's registry, listeners and real MK2 driver.
@MainActor
final class ReleaseMidiTests: XCTestCase {
    nonisolated private final class Probe: MidiController, @unchecked Sendable {
        private let lock = NSLock()
        private var touches: [[Int]] = []
        var pads: [[Int]] { lock.withLock { touches } }
        func onAttach() {}
        func onDetach() {}
        func onPadTouch(x: Int, y: Int, upDown: Bool, velocity: Int) {
            lock.withLock { touches.append([x, y, upDown ? 1 : 0, velocity]) }
        }
        func onChainTouch(c: Int, upDown: Bool) {}
        func onFunctionKeyTouch(f: Int, upDown: Bool) {}
        func onUnknownEvent(cmd: Int, sig: Int, note: Int, velocity: Int) {}
    }

    private final class Device: MidiTransport {
        var deviceNames: [String] = []
        var connectedIndex: Int?
        var output: [[UInt8]] = []
        var receive: (@MainActor (Int, Int, Int, Int) -> Void)?
        func start(receive: @escaping @MainActor (Int, Int, Int, Int) -> Void) { self.receive = receive }
        func connect(index: Int) -> Bool { connectedIndex = index; return true }
        func disconnect() { connectedIndex = nil }
        func stop() { receive = nil }
        func send(_ bytes: [UInt8]) { output.append(bytes) }
    }

    func testDeviceDiscoveryTwoHeldPadsAndLightOutput() async throws {
        let device = Device()
        let manager = MidiManager(transport: device)
        let probe = Probe()
        manager.controller = probe
        manager.start()
        defer { manager.stop() }
        XCTAssertFalse(manager.isConnected, "no device has appeared yet")
        device.deviceNames = ["unrecognized", "Launchpad MK2 Release Test"]
        manager.scanForDevices()
        XCTAssertTrue(manager.isConnected)
        XCTAssertEqual(device.connectedIndex, 1)
        XCTAssertEqual(manager.connectedDeviceName, "Launchpad MK2")
        XCTAssertTrue(manager.driver is LaunchpadMK2Driver)
        device.receive?(9, -112, 81, 127)
        device.receive?(9, -112, 82, 100)
        let deadline = Date().addingTimeInterval(3)
        while probe.pads.count < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(probe.pads, [[0, 0, 1, 127], [0, 1, 1, 100]], "both pads must remain down together")
        manager.driver.sendPadLed(x: 0, y: 1, velocity: 5)
        let outputDeadline = Date().addingTimeInterval(3)
        while !device.output.contains([0x90, 82, 5]) && Date() < outputDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(device.output.contains([0x90, 82, 5]))
        manager.disconnect()
        XCTAssertFalse(manager.isConnected)
        XCTAssertNil(device.connectedIndex)
        manager.stop()
        XCTAssertNil(device.receive)
    }
}
