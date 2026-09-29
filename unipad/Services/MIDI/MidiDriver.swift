import Foundation

// MARK: - Driver Listeners

protocol MidiDriverCycleListener: AnyObject {
    func onConnected()
    func onDisconnected()
}

protocol MidiDriverReceiveSignalListener: AnyObject {
    func onReceived(cmd: Int, sig: Int, note: Int, velocity: Int)
    func onUnknownReceived(cmd: Int, sig: Int, note: Int, velocity: Int)
    func onPadTouch(x: Int, y: Int, upDown: Bool, velocity: Int)
    func onChainTouch(c: Int, upDown: Bool)
    func onFunctionKeyTouch(f: Int, upDown: Bool)
}

protocol MidiDriverSendSignalListener: AnyObject {
    func onSend(cmd: UInt8, sig: UInt8, note: UInt8, velocity: UInt8)
    func onSendRaw(messages: [[UInt8]], cableNumber: Int)
}

// MARK: - MidiDriver Protocol

protocol MidiDriver: AnyObject {
    var cycleListener: MidiDriverCycleListener? { get set }
    var receiveSignalListener: MidiDriverReceiveSignalListener? { get set }
    var sendSignalListener: MidiDriverSendSignalListener? { get set }

    func initialize()
    func getInitSysEx() -> (messages: [[UInt8]], cableNumber: Int)?

    func getSignal(cmd: Int, sig: Int, note: Int, velocity: Int)

    func sendPadLed(x: Int, y: Int, velocity: Int)
    func sendChainLed(c: Int, velocity: Int)
    func sendFunctionKeyLed(f: Int, velocity: Int)
    func sendClearLed()
}

// MARK: - Base Implementation

class BaseMidiDriver: MidiDriver {
    weak var cycleListener: MidiDriverCycleListener?
    weak var receiveSignalListener: MidiDriverReceiveSignalListener?
    weak var sendSignalListener: MidiDriverSendSignalListener?

    func initialize() {}

    func getInitSysEx() -> (messages: [[UInt8]], cableNumber: Int)? { nil }

    func getSignal(cmd: Int, sig: Int, note: Int, velocity: Int) {
        receiveSignalListener?.onReceived(cmd: cmd, sig: sig, note: note, velocity: velocity)
    }

    func sendPadLed(x: Int, y: Int, velocity: Int) {}
    func sendChainLed(c: Int, velocity: Int) {}
    func sendFunctionKeyLed(f: Int, velocity: Int) {}
    func sendClearLed() {}

    // MARK: - Convenience Methods

    func onConnected() {
        cycleListener?.onConnected()
    }

    func onDisconnected() {
        cycleListener?.onDisconnected()
    }

    func onPadTouch(x: Int, y: Int, upDown: Bool, velocity: Int) {
        receiveSignalListener?.onPadTouch(x: x, y: y, upDown: upDown, velocity: velocity)
    }

    func onChainTouch(c: Int, upDown: Bool) {
        receiveSignalListener?.onChainTouch(c: c, upDown: upDown)
    }

    func onFunctionKeyTouch(f: Int, upDown: Bool) {
        receiveSignalListener?.onFunctionKeyTouch(f: f, upDown: upDown)
    }

    func onUnknownReceived(cmd: Int, sig: Int, note: Int, velocity: Int) {
        receiveSignalListener?.onUnknownReceived(cmd: cmd, sig: sig, note: note, velocity: velocity)
    }

    func sendSignal(cmd: UInt8, sig: UInt8, note: UInt8, velocity: UInt8) {
        sendSignalListener?.onSend(cmd: cmd, sig: sig, note: note, velocity: velocity)
    }

    /// LED codes come from pack text (`on 1 1 FF0000 200` is accepted), but a MIDI data byte is 7 bits.
    static func midiDataByte(_ velocity: Int) -> UInt8 {
        UInt8(min(max(velocity, 0), 127))
    }

    /// cmd, sig and note are signed status/note values that wrap into a byte on purpose (`sig: -80` is 0xB0);
    /// only the velocity is limited to 0...127.
    func sendSignal(cmd: Int, sig: Int, note: Int, velocity: Int) {
        sendSignal(cmd: UInt8(truncatingIfNeeded: cmd),
                   sig: UInt8(truncatingIfNeeded: sig),
                   note: UInt8(truncatingIfNeeded: note),
                   velocity: Self.midiDataByte(velocity))
    }

    func sendRawSignal(bytes: [UInt8], cableNumber: Int = 0) {
        sendSignalListener?.onSendRaw(messages: [bytes], cableNumber: cableNumber)
    }

    func sendRawSignals(messages: [[UInt8]], cableNumber: Int = 0) {
        sendSignalListener?.onSendRaw(messages: messages, cableNumber: cableNumber)
    }
}
