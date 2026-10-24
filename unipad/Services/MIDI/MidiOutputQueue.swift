import Foundation
import CoreMIDI

/// A message owns its place until the transport completes it. Notes, SysEx and mode
/// settling share this FIFO, so neither a later light nor a redraw can overtake them.
nonisolated final class MidiOutputQueue: @unchecked Sendable {
    typealias Operation = @Sendable (@escaping @Sendable () -> Void) -> Void
    private let queue = DispatchQueue(label: "com.kimjisub.unipad.midi.send")
    private var pending: [Operation] = []
    private var next = 0
    private var sending = false
    private var generation: UInt64 = 0
    private let sysexSend: @Sendable (UnsafeMutablePointer<MIDISysexSendRequest>) -> OSStatus
    private let noteSend: @Sendable ([UInt8], MIDIPortRef, MIDIEndpointRef) -> Void

    init(sysexSend: @escaping @Sendable (UnsafeMutablePointer<MIDISysexSendRequest>) -> OSStatus = { MIDISendSysex($0) },
         noteSend: @escaping @Sendable ([UInt8], MIDIPortRef, MIDIEndpointRef) -> Void = { bytes, port, destination in
             var list = MIDIPacketList()
             let packet = MIDIPacketListInit(&list)
             MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, bytes)
             MIDISend(port, destination, &list)
         }) {
        self.sysexSend = sysexSend
        self.noteSend = noteSend
    }

    @MainActor
    func initialize(_ driver: MidiDriver, onReady: @escaping @Sendable () -> Void) {
        driver.initialize()
        if let initialization = driver.getInitSysEx(), !initialization.messages.isEmpty {
            // Finish every mode message, then allow the device to change layouts.
            wait(0.5)
        }
        enqueue { done in onReady(); done() }
    }

    /// A removed device may never finish a send. Its completion and queued lights
    /// belong to that connection, and must not hold up the next controller.
    func reset() {
        queue.async {
            self.generation &+= 1
            self.pending.removeAll(keepingCapacity: true)
            self.next = 0
            self.sending = false
        }
    }

    func enqueue(_ operation: @escaping Operation) {
        queue.async {
            self.pending.append(operation)
            self.sendNext()
        }
    }

    private func sendNext() {
        guard !sending, next < pending.count else { return }
        sending = true
        let operation = pending[next]
        let generation = self.generation
        next += 1
        operation {
            self.queue.async {
                guard self.generation == generation else { return }
                self.sending = false
                if self.next == self.pending.count {
                    self.pending.removeAll(keepingCapacity: true)
                    self.next = 0
                }
                self.sendNext()
            }
        }
    }

    func wait(_ seconds: TimeInterval) {
        enqueue { completion in
            self.queue.asyncAfter(deadline: .now() + seconds, execute: completion)
        }
    }

    func send(_ bytes: [UInt8], port: MIDIPortRef, destination: MIDIEndpointRef) {
        guard port != 0, destination != 0 else { return }
        enqueue { done in
            self.noteSend(bytes, port, destination)
            done()
        }
    }

    func sendSysEx(_ messages: [[UInt8]], destination: MIDIEndpointRef,
                   onFailure: @escaping @Sendable (OSStatus) -> Void) {
        guard destination != 0 else { return }
        for (index, message) in messages.enumerated() where !message.isEmpty {
            if index > 0 { wait(0.05) }
            enqueue { done in
                Self.sendSysExMessage(message, destination: destination, sender: self.sysexSend,
                                     onFailure: onFailure, completion: done)
            }
        }
    }

    private static func sendSysExMessage(_ bytes: [UInt8], destination: MIDIEndpointRef,
                                        sender: (UnsafeMutablePointer<MIDISysexSendRequest>) -> OSStatus,
                                        onFailure: @escaping @Sendable (OSStatus) -> Void,
                                        completion: @escaping @Sendable () -> Void) {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
        buffer.initialize(from: bytes, count: bytes.count)
        let context = Unmanaged.passRetained(SysExContext(buffer: buffer, count: bytes.count, completion: completion)).toOpaque()
        let request = UnsafeMutablePointer<MIDISysexSendRequest>.allocate(capacity: 1)
        request.initialize(to: MIDISysexSendRequest(
            destination: destination, data: UnsafePointer(buffer), bytesToSend: UInt32(bytes.count),
            complete: false, reserved: (0, 0, 0), completionProc: { request in
                MidiOutputQueue.finish(request)
            }, completionRefCon: context))
        let status = sender(request)
        if status != noErr {
            // CoreMIDI does not call the completion on failure. Release the request and
            // advance the FIFO here as well, so the next light cannot be stranded.
            onFailure(status)
            finish(request)
        }
    }

    private static func finish(_ request: UnsafeMutablePointer<MIDISysexSendRequest>) {
        let context = Unmanaged<SysExContext>.fromOpaque(request.pointee.completionRefCon!).takeRetainedValue()
        context.buffer.deinitialize(count: context.count)
        context.buffer.deallocate()
        request.deinitialize(count: 1)
        request.deallocate()
        context.completion()
    }
}

nonisolated private final class SysExContext {
    let buffer: UnsafeMutablePointer<UInt8>
    let count: Int
    let completion: @Sendable () -> Void
    init(buffer: UnsafeMutablePointer<UInt8>, count: Int, completion: @escaping @Sendable () -> Void) {
        self.buffer = buffer
        self.count = count
        self.completion = completion
    }
}
