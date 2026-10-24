import CoreMIDI
import Foundation
import Testing
@testable import unipad

extension PlayUsageRecordTests {
    /// Real discovery notifications and connections, not just driver-name matching.
    /// Kept in the shared serialized scope because discovery installs the singleton's driver.
    @MainActor
    @Suite(.enabled(if: MidiTestDeviceKind.folder != nil, "needs ci/midi-input-tests.sh"))
    struct MidiDeviceSelectionTests {
        private func withDevices(
            _ names: [String],
            _ body: (VirtualMidiDevice, SelectionEvents) async throws -> Void
        ) async throws {
            let manager = MidiManager.shared
            let previousListener = manager.listener
            manager.stop()
            // Keep a separate client alive while MidiManager is stopped. An acknowledgement from
            // the tool precedes this process's endpoint-cache update; start() must see the full list.
            var observer: MIDIClientRef = 0
            let status = MIDIClientCreateWithBlock("UniPad discovery tests" as CFString, &observer) { _ in }
            try #require(status == noErr)
            defer { MIDIClientDispose(observer) }
            let events = SelectionEvents()
            let tool = try VirtualMidiDevice(folder: URL(fileURLWithPath: try #require(MidiTestDeviceKind.folder)))
            defer {
                manager.stop()
                manager.listener = previousListener
                try? tool.run("close")
            }
            try tool.run("close")
            try await waitForEndpoints([])
            for name in names { try tool.run("add \(name)") }
            try await waitForEndpoints(names)
            manager.listener = events
            manager.start()
            try await body(tool, events)
        }

        private func endpointNames(sources: Bool) -> [String] {
            let count = sources ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()
            return (0..<count).map { index in
                let endpoint = sources ? MIDIGetSource(index) : MIDIGetDestination(index)
                var name: Unmanaged<CFString>?
                MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name)
                return name?.takeRetainedValue() as String? ?? ""
            }
        }

        private func waitForEndpoints(_ names: [String]) async throws {
            try await PlayUsageScenario.waitWhile(timeout: 5) {
                endpointNames(sources: true) != names || endpointNames(sources: false) != names
            }
            try #require(endpointNames(sources: true) == names, "initial sources are not ready in the requested order")
            try #require(endpointNames(sources: false) == names, "initial destinations are not ready")
        }

        /// A tool acknowledgement only means the endpoints exist. Wait until a scan in the app
        /// has seen BOTH new endpoints, so an unchanged connection cannot pass before discovery runs.
        private func add(_ name: String, using tool: VirtualMidiDevice, events: SelectionEvents) async throws {
            let start = events.logs.count
            let sources = MIDIGetNumberOfSources() + 1
            let destinations = MIDIGetNumberOfDestinations() + 1
            try tool.run("add \(name)")
            let scan = "MIDI scan: \(sources) sources, \(destinations) destinations"
            try await PlayUsageScenario.waitWhile(timeout: 5) { !events.logs.dropFirst(start).contains(scan) }
            try #require(events.logs.dropFirst(start).contains(scan), "the app never scanned the new endpoints")
        }

        @Test func unknownDeviceUpgradesToKeyboard() async throws {
            try await withDevices(["Test Synth"]) { tool, events in
                let manager = MidiManager.shared
                try #require(manager.isConnected && manager.connectedDeviceName == "Test Synth")
                let original = manager.driver
                try await add("Test Keyboard", using: tool, events: events)
                #expect(manager.connectedDeviceName == "Master Keyboard")
                #expect(manager.driver !== original)
            }
        }

        @Test(arguments: [true, false])
        func firstConnectionPrefersLaunchpadRegardlessOfSourceOrder(keyboardFirst: Bool) async throws {
            let names = keyboardFirst ? ["Test Keyboard", "Launchpad MK2"] : ["Launchpad MK2", "Test Keyboard"]
            try await withDevices(names) { _, events in
                let manager = MidiManager.shared
                // Check immediately after start(), before any later notification could repair a wrong first choice.
                #expect(manager.driver is LaunchpadMK2Driver)
                #expect(events.connections == 1)
                let original = manager.driver
                manager.scanForDevices()
                #expect(manager.driver === original)
                #expect(events.connections == 1)
                #expect(events.disconnections == 0)
            }
        }

        @Test func keyboardStaysForAPeerAndUpgradesToLaunchpad() async throws {
            try await withDevices(["Test Keyboard"]) { tool, events in
                let manager = MidiManager.shared
                let original = manager.driver
                try #require(manager.isConnected && original is MasterKeyboardDriver)
                try await add("Test Piano", using: tool, events: events)
                #expect(manager.driver === original, "a peer must not interrupt the current keyboard")
                #expect(events.connections == 1)
                #expect(events.disconnections == 0)

                try await add("Launchpad MK2", using: tool, events: events)
                #expect(manager.driver is LaunchpadMK2Driver)
                #expect(events.connections == 2)
                #expect(events.disconnections == 1)
                let launchpad = manager.driver
                manager.scanForDevices()
                #expect(manager.driver === launchpad)
                try await add("Launchpad S", using: tool, events: events)
                #expect(manager.driver === launchpad, "a dedicated peer must not replace the current device")
            }
        }

        @Test func unknownDeviceStaysForAnUnknownPeer() async throws {
            try await withDevices(["Test Synth"]) { tool, events in
                let manager = MidiManager.shared
                let original = manager.driver
                try await add("Test Synth Two", using: tool, events: events)
                manager.scanForDevices()
                #expect(manager.driver === original)
                #expect(events.connections == 1)
                #expect(events.disconnections == 0)
            }
        }

        @Test func keyboardRescanKeepsTheConnectionAndReceivesRelease() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                try await withDevices(["Test Keyboard"]) { tool, events in
                    let manager = MidiManager.shared
                    let original = manager.driver
                    try tool.send(0x90, 36, 100)
                    try await PlayUsageScenario.waitWhile { s.vm.padItems[7][0] == nil }
                    try #require(s.vm.padItems[7][0] != nil)

                    // Both foreground return and Settings > Rescan call this same method.
                    manager.scanForDevices()
                    #expect(manager.driver === original, "rescan replaced the keyboard's input connection")
                    #expect(events.connections == 1)
                    #expect(events.disconnections == 0)
                    try tool.send(0x80, 36, 64)
                    try await PlayUsageScenario.waitWhile { s.vm.padItems[7][0] != nil }
                    #expect(s.vm.padItems[7][0] == nil, "the release after rescan left a pad held")
                }
            }
        }
    }
}

private final class SelectionEvents: MidiManagerListener {
    var logs: [String] = []
    var connections = 0
    var disconnections = 0
    func onConnected() { connections += 1 }
    func onDisconnected() { disconnections += 1 }
    func onChangeDriver(driver: MidiDriver) {}
    func onLog(_ message: String) { logs.append(message) }
}
