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

    // MARK: - Shared Input and LED Rules

    /// The message kind in a received `cmd`: 8 note off, 9 note on, 10 aftertouch, 11 control change,
    /// 13 channel pressure. MidiManager puts the port the message came in on above it; the connection
    /// already chose the port, so the same message means the same button on any port.
    static func messageKind(_ cmd: Int) -> Int {
        cmd & 0x0F
    }

    /// Whether a note message presses (true) or releases (false) its button. A note on with a velocity
    /// presses; a note off with any release velocity, or a note on with velocity 0, releases. nil for
    /// every other message, aftertouch included.
    static func noteTouch(cmd: Int, velocity: Int) -> Bool? {
        switch messageKind(cmd) {
        case 9: velocity > 0
        case 8: false
        default: nil
        }
    }

    static func isControlChange(_ cmd: Int) -> Bool {
        messageKind(cmd) == 11
    }

    /// Pack coordinates come from its info file and can exceed a controller's 8x8 pads; those pads
    /// light nothing rather than another button.
    static func isOnGrid(x: Int, y: Int) -> Bool {
        (0...7).contains(x) && (0...7).contains(y)
    }

    /// Reports a note message on the drum-rack layout as a pad press or release.
    func reportDrumRackPad(cmd: Int, note: Int, velocity: Int) {
        guard let down = Self.noteTouch(cmd: cmd, velocity: velocity), let pad = DrumRackLayout.pad(note: note) else { return }
        onPadTouch(x: pad.x, y: pad.y, upDown: down, velocity: velocity)
    }
}

/// Notes 36...99 as two 4-column blocks running bottom-up, the left block first: a drum rack's layout,
/// which Matrix, Midi Fighter, master keyboards and the Launchpad custom firmwares share.
enum DrumRackLayout {
    static func pad(note: Int) -> (x: Int, y: Int)? {
        guard (36...99).contains(note) else { return nil }
        let index = note - 36
        return (x: 7 - (index % 32) / 4, y: index % 4 + (index < 32 ? 0 : 4))
    }

    static func note(x: Int, y: Int) -> Int? {
        guard BaseMidiDriver.isOnGrid(x: x, y: y) else { return nil }
        return 36 + (y < 4 ? 0 : 32) + (7 - x) * 4 + y % 4
    }
}
