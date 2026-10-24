import Foundation
import CoreMIDI
import Testing
@testable import unipad

struct MidiTransportTests {
    /// Exercise the stock driver and the manager's actual send adapter, replacing only CoreMIDI.
    @MainActor
    @Test func proInitializationSendsEveryModeBeforeTheReadyCallback() async throws {
        let sent = Capture()
        let output = recordingOutput(sent)
        let adapter = MidiManagerSendAdapter(output: output, port: 1, destination: 1, sysexDestination: 1,
                                             onFailure: { _ in sent.add("error") })
        let driver = LaunchpadProDriver()
        driver.sendSignalListener = adapter
        withExtendedLifetime(adapter) {
            output.initialize(driver) { sent.add("ready") }
        }
        try await sent.waitForCount(7)
        let modes: [[UInt8]] = [
            [0xF0, 0, 0x20, 0x29, 2, 0x10, 0x21, 0, 0xF7],
            [0xF0, 0, 0x20, 0x29, 2, 0x10, 0x22, 0, 0xF7],
            [0xF0, 0, 0x20, 0x29, 2, 0x10, 0x0B, 0x63, 0, 0, 0, 0xF7],
        ]
        #expect(sent.messages == modes + modes)
        let readyTime = try #require(sent.time("ready"))
        let lastModeTime = try #require(sent.time("message"))
        #expect(readyTime - lastModeTime >= 0.5)
    }

    @MainActor
    @Test func proLogoAndPadMessagesUseTheSameTransportOrder() async throws {
        let sent = Capture()
        let output = recordingOutput(sent)
        let adapter = MidiManagerSendAdapter(output: output, port: 1, destination: 1, sysexDestination: 1,
                                             onFailure: { _ in sent.add("error") })
        let driver = LaunchpadProDriver()
        driver.sendSignalListener = adapter
        withExtendedLifetime(adapter) {
            driver.sendFunctionKeyLed(f: 32, velocity: 0)
            driver.sendPadLed(x: 0, y: 0, velocity: 5)
            driver.sendFunctionKeyLed(f: 32, velocity: 9)
        }
        try await sent.waitForCount(4)
        #expect(sent.messages == [
            [0xF0, 0, 0x20, 0x29, 2, 0x10, 0x0B, 0x63, 0, 0, 0, 0xF7],
            [0xF0, 0, 0x20, 0x29, 2, 0x10, 0x0A, 0x63, 0, 0xF7],
            [0x90, 81, 5],
            [0xF0, 0, 0x20, 0x29, 2, 0x10, 0x0A, 0x63, 9, 0xF7],
        ])
    }

    private func recordingOutput(_ sent: Capture) -> MidiOutputQueue {
        MidiOutputQueue(sysexSend: { request in
            sent.record(Array(UnsafeBufferPointer(start: request.pointee.data, count: Int(request.pointee.bytesToSend))))
            request.pointee.completionProc(request)
            return 0
        }, noteSend: { bytes, _, _ in sent.record(bytes) })
    }

    /// A transport callback, rather than a timer after submission, marks a message as sent.
    @Test func lightsWaitForTheLastModeMessageAndItsSettlingDelay() async throws {
        let output = MidiOutputQueue()
        let sent = Capture()
        output.enqueue { done in sent.completeFirst = done; sent.add("mode 1") }
        output.enqueue { done in sent.add("mode 2"); done() }
        output.wait(0.05)
        output.enqueue { done in sent.add("redraw"); done() }
        try await sent.waitForCount(1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(sent.values == ["mode 1"], "redraw must wait for mode transmission to complete")
        sent.finishFirst()
        try await sent.waitForCount(3)
        #expect(sent.values == ["mode 1", "mode 2", "redraw"])
        let redrawTime = try #require(sent.time("redraw"))
        let modeTime = try #require(sent.time("mode 2"))
        #expect(redrawTime - modeTime >= 0.05,
                "redraw must wait for the device to change mode")
    }

    @Test func logoOffCannotBeOvertakenByALaterPadOrLogoOn() async throws {
        let output = MidiOutputQueue()
        let sent = Capture()
        output.enqueue { done in sent.completeFirst = done; sent.add("logo off rgb") }
        output.enqueue { done in sent.add("logo off palette"); done() }
        output.enqueue { done in sent.add("pad"); done() }
        output.enqueue { done in sent.add("logo on"); done() }
        try await sent.waitForCount(1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(sent.values == ["logo off rgb"])
        sent.finishFirst()
        try await sent.waitForCount(4)
        #expect(sent.values == ["logo off rgb", "logo off palette", "pad", "logo on"])
    }

    @Test func aFailedSysExDoesNotStrandTheFollowingLights() async throws {
        let output = MidiOutputQueue(sysexSend: { _ in -10843 })
        let sent = Capture()
        output.sendSysEx([[0xF0, 0x7D, 0xF7]], destination: .max) { _ in sent.add("error") }
        output.enqueue { done in sent.add("next light"); done() }
        try await sent.waitForCount(2)
        #expect(sent.values == ["error", "next light"])
    }

    @Test func missingSysExCompletionReleasesLightsAndLateCompletionKeepsOrder() async throws {
        let sent = Capture()
        let requests = HeldSysExRequests()
        defer { requests.finishAll() }
        let output = MidiOutputQueue(sysexSend: { request in
            requests.add(request)
            sent.add("sysex \(requests.count)")
            return noErr
        }, noteSend: { bytes, _, _ in sent.add("pad \(bytes[2])") })
        let message: [UInt8] = [0xF0, 0x7D, 0xF7]
        let submittedAt = ProcessInfo.processInfo.systemUptime
        output.sendSysEx([message], destination: 1) { _ in sent.add("error") }
        output.send([0x90, 81, 5], port: 1, destination: 1)
        output.sendSysEx([message], destination: 1) { _ in sent.add("error") }
        output.send([0x90, 82, 9], port: 1, destination: 1)

        // The first request never calls back: the next light must still be sent.
        try await sent.waitForCount(3)
        #expect(sent.values == ["sysex 1", "pad 5", "sysex 2"])
        #expect(try #require(sent.time("pad 5")) - submittedAt >= 1)
        #expect(requests.bytes(at: 0) == message, "CoreMIDI still owns this buffer after the timeout")
        requests.finish(at: 0)
        try await Task.sleep(for: .milliseconds(30))
        #expect(sent.values == ["sysex 1", "pad 5", "sysex 2"],
                "the late first completion must not release the second request's light")
        #expect(requests.bytes(at: 1) == message)
        requests.finish(at: 1)
        try await sent.waitForCount(4)
        #expect(sent.values == ["sysex 1", "pad 5", "sysex 2", "pad 9"])
    }

    private final class HeldSysExRequests: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [UnsafeMutablePointer<MIDISysexSendRequest>?] = []
        var count: Int { lock.withLock { requests.count } }
        func add(_ request: UnsafeMutablePointer<MIDISysexSendRequest>) {
            lock.withLock { requests.append(request) }
        }
        func bytes(at index: Int) -> [UInt8] {
            lock.withLock {
                guard let request = requests[index] else { return [] }
                return Array(UnsafeBufferPointer(start: request.pointee.data, count: Int(request.pointee.bytesToSend)))
            }
        }
        func finish(at index: Int) {
            let request = lock.withLock {
                let request = requests[index]
                requests[index] = nil
                return request
            }
            if let request { request.pointee.completionProc(request) }
        }
        func finishAll() { for index in 0..<count { finish(at: index) } }
    }

    @Test func aRemovedDevicesLateCompletionCannotAdvanceTheNewConnection() async throws {
        let output = MidiOutputQueue()
        let sent = Capture()
        output.enqueue { done in sent.completeFirst = done; sent.add("old send") }
        output.enqueue { done in sent.add("stale light"); done() }
        try await sent.waitForCount(1)
        output.reset()
        output.enqueue { done in sent.add("new mode"); done() }
        output.enqueue { done in sent.add("new light"); done() }
        try await sent.waitForCount(3)
        sent.finishFirst()
        try await Task.sleep(for: .milliseconds(30))
        #expect(sent.values == ["old send", "new mode", "new light"])
    }

    /// UMP SysEx7: complete, or start followed by end. Other groups and messages cannot
    /// supply the missing tail of a mode notification.
    @Test func proLiveModeSysExReachesTheExistingRedrawHook() {
        let decoder = MidiInputDecoder()
        let expected = [MidiInputDecoder.Event(cmd: 7, sig: 46, note: 0, velocity: -9)]
        #expect(decoder.decode([0x30160020, 0x2902102E, 0x30310000, 0], portIndex: 0) == expected)
        #expect(decoder.decode([0x30060020, 0x2902102E], portIndex: 0).isEmpty)
        #expect(decoder.decode([0x30160020, 0x2902102E], portIndex: 0).isEmpty)
        #expect(decoder.decode([0x31310000, 0], portIndex: 0).isEmpty)
        #expect(decoder.decode([0x30310000, 0], portIndex: 0) == expected)
        #expect(decoder.decode([0x30310000, 0], portIndex: 0).isEmpty)
        #expect(decoder.decode([0x30070020, 0x2902102E], portIndex: 0).isEmpty) // invalid byte count
        #expect(decoder.decode([0x2090517F], portIndex: 1) == [
            .init(cmd: 25, sig: -112, note: 81, velocity: 127)
        ])
        #expect(decoder.decode([0x4090517F, 0x2090527F], portIndex: 0).isEmpty) // MIDI 2.0, not two MIDI 1.0 words
        _ = decoder.decode([0x30160020, 0x2902102E], portIndex: 0)
        decoder.reset()
        #expect(decoder.decode([0x30310000, 0], portIndex: 0).isEmpty, "a new device cannot finish the old device's message")
    }

    /// Read in-place event packets without losing the original Pro's completed Live notification.
    @Test func eventListReaderPreservesLiveNotificationsAndSkipsPayloadWords() throws {
        let builder = MIDIEventList.Builder(inProtocol: ._1_0, wordSize: 256)
        try #require(builder.append(timestamp: 0, words: [0x30160020, 0x2902102E]) != nil)
        let tail: [UInt32] = [0x30310000, 0, 0x2090517F, 0x4090527F, 0x2090537F]
        try #require(builder.append(timestamp: 1, words: tail + Array(repeating: UInt32(0x20805140), count: 70)) != nil)
        let events = builder.withUnsafePointer { MidiManager.channelMessages(in: $0, port: 1) }
        #expect(events.map(\.cmd) == [7, 25] + Array(repeating: 24, count: 70))
        #expect(events.map(\.note) == [0, 81] + Array(repeating: 81, count: 70))
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        private var packets: [[UInt8]] = []
        private var times: [String: TimeInterval] = [:]
        private var completion: (@Sendable () -> Void)?
        var values: [String] { lock.withLock { stored } }
        var messages: [[UInt8]] { lock.withLock { packets } }
        var completeFirst: (@Sendable () -> Void)? {
            get { lock.withLock { completion } }
            set { lock.withLock { completion = newValue } }
        }
        func add(_ value: String) {
            lock.withLock { stored.append(value); times[value] = ProcessInfo.processInfo.systemUptime }
        }
        func time(_ value: String) -> TimeInterval? { lock.withLock { times[value] } }
        func record(_ bytes: [UInt8]) {
            lock.withLock {
                packets.append(bytes)
                stored.append("message")
                times["message"] = ProcessInfo.processInfo.systemUptime
            }
        }
        func waitForCount(_ count: Int) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while values.count < count, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(values.count >= count, "MIDI queue did not advance: \(values)")
        }
        func finishFirst() { completeFirst?() }
    }
}
